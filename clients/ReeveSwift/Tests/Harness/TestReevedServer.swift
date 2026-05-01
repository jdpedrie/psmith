import Foundation

/// Boots a real reeved subprocess against an isolated, freshly-migrated
/// Postgres database. One server per test process — tests share the binary
/// + DB but use distinct user accounts to isolate state.
///
/// Lookup order for the server binary:
///   1. `REEVE_TEST_BIN` env var if set,
///   2. `<repoRoot>/bin/reeved-test` (pre-built by the harness on first call),
///   3. otherwise, `go build -o bin/reeved-test ./cmd/reeved` is run lazily.
///
/// The server is created lazily via `TestReevedServer.shared()` so XCTest's
/// parallel test workers all share a single instance per process. The shared
/// instance shuts down + drops the test DB at process exit (atexit hook).
public final class TestReevedServer: @unchecked Sendable {
    public let baseURL: URL
    public let port: Int
    public let dsn: String
    public let dbName: String

    /// Bootstrap admin credentials seeded into the test server. Tests use
    /// these via `TestSession.adminClient(...)` to call admin-only RPCs
    /// like `CreateUser`.
    public let adminUsername: String
    public let adminPassword: String

    private let process: Process
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let stdoutBuffer: LogBuffer
    private let stderrBuffer: LogBuffer

    // MARK: - Shared instance

    private static let lock = NSLock()
    nonisolated(unsafe) private static var sharedInstance: TestReevedServer?

    /// Returns the process-wide shared server, booting it on first call.
    /// Subsequent callers wait for the boot to complete.
    public static func shared() throws -> TestReevedServer {
        lock.lock()
        defer { lock.unlock() }
        if let s = sharedInstance { return s }
        let server = try TestReevedServer.start()
        sharedInstance = server
        // Tear down on process exit. atexit can't capture self by reference,
        // so we read from the static slot.
        atexit {
            TestReevedServer.lock.lock()
            let s = TestReevedServer.sharedInstance
            TestReevedServer.sharedInstance = nil
            TestReevedServer.lock.unlock()
            s?.shutdown()
        }
        return server
    }

    // MARK: - Lifecycle

    public static func start() throws -> TestReevedServer {
        let repoRoot = try findRepoRoot()
        let binary = try ensureBinary(repoRoot: repoRoot)

        // PG connection — mirrors internal/testutil/testdb.go defaults.
        let pgHost = ProcessInfo.processInfo.environment["PGTESTDB_HOST"] ?? "localhost"
        let pgPort = ProcessInfo.processInfo.environment["PGTESTDB_PORT"] ?? "5433"
        let pgUser = ProcessInfo.processInfo.environment["PGTESTDB_USER"] ?? "clark"
        let pgPass = ProcessInfo.processInfo.environment["PGTESTDB_PASSWORD"] ?? "clark"
        let pgRoot = ProcessInfo.processInfo.environment["PGTESTDB_DB"] ?? "clark"

        let dbName = "reeve_swift_test_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
        let rootDSN = "postgres://\(pgUser):\(pgPass)@\(pgHost):\(pgPort)/\(pgRoot)?sslmode=disable"
        let testDSN = "postgres://\(pgUser):\(pgPass)@\(pgHost):\(pgPort)/\(dbName)?sslmode=disable"

        try createDatabase(dbName: dbName, rootDSN: rootDSN)
        try runGooseMigrations(dsn: testDSN, repoRoot: repoRoot)

        // Pick a free port up-front so we don't have to scrape stdout for it.
        let port = try pickFreePort()
        let listenAddr = "127.0.0.1:\(port)"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = []
        proc.currentDirectoryURL = URL(fileURLWithPath: repoRoot)

        var env = ProcessInfo.processInfo.environment
        env["REEVE_DSN"] = testDSN
        env["REEVE_ADDR"] = listenAddr
        env["REEVE_BOOTSTRAP_ADMIN_USERNAME"] = "admin"
        env["REEVE_BOOTSTRAP_ADMIN_PASSWORD"] = "admin-password-not-secret"
        // Disable the catalog refresh loop — tests don't need it and it
        // makes outbound network calls.
        env["REEVE_CATALOG_REFRESH_INTERVAL"] = "0"
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let outBuf = LogBuffer()
        let errBuf = LogBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { outBuf.append(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { errBuf.append(data) }
        }

        try proc.run()

        let baseURL = URL(string: "http://\(listenAddr)")!
        let server = TestReevedServer(
            baseURL: baseURL,
            port: port,
            dsn: testDSN,
            dbName: dbName,
            adminUsername: env["REEVE_BOOTSTRAP_ADMIN_USERNAME"]!,
            adminPassword: env["REEVE_BOOTSTRAP_ADMIN_PASSWORD"]!,
            process: proc,
            stdoutPipe: outPipe,
            stderrPipe: errPipe,
            stdoutBuffer: outBuf,
            stderrBuffer: errBuf
        )

        try server.waitUntilReady(timeoutSeconds: 30)
        return server
    }

    private init(
        baseURL: URL,
        port: Int,
        dsn: String,
        dbName: String,
        adminUsername: String,
        adminPassword: String,
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        stdoutBuffer: LogBuffer,
        stderrBuffer: LogBuffer
    ) {
        self.baseURL = baseURL
        self.port = port
        self.dsn = dsn
        self.dbName = dbName
        self.adminUsername = adminUsername
        self.adminPassword = adminPassword
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.stdoutBuffer = stdoutBuffer
        self.stderrBuffer = stderrBuffer
    }

    /// Polls the server's TCP port until it accepts connections, or the
    /// timeout elapses. Surfaces captured stderr if the process dies early.
    private func waitUntilReady(timeoutSeconds: Double) throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !process.isRunning {
                let err = stderrBuffer.snapshotString() + stdoutBuffer.snapshotString()
                throw HarnessError.serverFailedToStart("reeved exited before becoming ready:\n\(err)")
            }
            if tcpProbe(host: "127.0.0.1", port: port) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw HarnessError.serverFailedToStart(
            "reeved did not bind \(port) within \(timeoutSeconds)s. stderr:\n\(stderrBuffer.snapshotString())"
        )
    }

    public func shutdown() {
        if process.isRunning {
            process.terminate()
            // Wait up to 5s for graceful exit.
            let deadline = Date().addingTimeInterval(5.0)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        // Drop the test database. Best-effort: log and move on if it fails.
        do {
            try TestReevedServer.dropDatabase(
                dbName: dbName,
                rootDSN: rootDSNForTeardown()
            )
        } catch {
            FileHandle.standardError.write(Data("[harness] dropping \(dbName) failed: \(error)\n".utf8))
        }
    }

    private func rootDSNForTeardown() -> String {
        let env = ProcessInfo.processInfo.environment
        let pgHost = env["PGTESTDB_HOST"] ?? "localhost"
        let pgPort = env["PGTESTDB_PORT"] ?? "5433"
        let pgUser = env["PGTESTDB_USER"] ?? "clark"
        let pgPass = env["PGTESTDB_PASSWORD"] ?? "clark"
        let pgRoot = env["PGTESTDB_DB"] ?? "clark"
        return "postgres://\(pgUser):\(pgPass)@\(pgHost):\(pgPort)/\(pgRoot)?sslmode=disable"
    }
}

// MARK: - Helpers

enum HarnessError: Error, CustomStringConvertible {
    case repoRootNotFound
    case binaryBuildFailed(String)
    case databaseSetupFailed(String)
    case serverFailedToStart(String)
    case noFreePort

    var description: String {
        switch self {
        case .repoRootNotFound: return "Could not locate repo root (no go.mod found above test bundle)"
        case .binaryBuildFailed(let s): return "go build of reeved failed: \(s)"
        case .databaseSetupFailed(let s): return "database setup failed: \(s)"
        case .serverFailedToStart(let s): return s
        case .noFreePort: return "could not pick a free TCP port"
        }
    }
}

private func findRepoRoot() throws -> String {
    // Walk up from this source file's directory looking for go.mod.
    var dir = (#filePath as NSString).deletingLastPathComponent
    let fm = FileManager.default
    for _ in 0..<10 {
        if fm.fileExists(atPath: (dir as NSString).appendingPathComponent("go.mod")) {
            return dir
        }
        let parent = (dir as NSString).deletingLastPathComponent
        if parent == dir { break }
        dir = parent
    }
    throw HarnessError.repoRootNotFound
}

private func ensureBinary(repoRoot: String) throws -> String {
    if let override = ProcessInfo.processInfo.environment["REEVE_TEST_BIN"], !override.isEmpty {
        return override
    }
    let binPath = (repoRoot as NSString).appendingPathComponent("bin/reeved-test")
    let fm = FileManager.default
    if fm.fileExists(atPath: binPath) {
        return binPath
    }
    // Build it: `go build -o bin/reeved-test ./cmd/reeved`.
    try fm.createDirectory(
        atPath: (repoRoot as NSString).appendingPathComponent("bin"),
        withIntermediateDirectories: true
    )
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = ["go", "build", "-o", "bin/reeved-test", "./cmd/reeved"]
    proc.currentDirectoryURL = URL(fileURLWithPath: repoRoot)
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    try proc.run()
    proc.waitUntilExit()
    if proc.terminationStatus != 0 {
        let data = try? pipe.fileHandleForReading.readToEnd()
        let s = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        throw HarnessError.binaryBuildFailed(s)
    }
    return binPath
}

/// Runs `psql -U <user> -d <db> -c <sql>` inside the `clark-postgres`
/// Docker container. Avoids needing libpq installed on the test host.
private func runPSQLInContainer(user: String, password: String, db: String, sql: String) throws -> (Int32, String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = [
        "docker", "exec", "-i",
        "-e", "PGPASSWORD=\(password)",
        "clark-postgres",
        "psql",
        "-U", user,
        "-d", db,
        "-v", "ON_ERROR_STOP=1",
        "-c", sql,
    ]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    try proc.run()
    proc.waitUntilExit()
    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
    let out = String(data: data, encoding: .utf8) ?? ""
    return (proc.terminationStatus, out)
}

private func createDatabase(dbName: String, rootDSN: String) throws {
    let env = ProcessInfo.processInfo.environment
    let user = env["PGTESTDB_USER"] ?? "clark"
    let pass = env["PGTESTDB_PASSWORD"] ?? "clark"
    let root = env["PGTESTDB_DB"] ?? "clark"
    let (rc, out) = try runPSQLInContainer(
        user: user, password: pass, db: root,
        sql: "CREATE DATABASE \"\(dbName)\";"
    )
    if rc != 0 {
        throw HarnessError.databaseSetupFailed("CREATE DATABASE \(dbName): \(out)")
    }
}

extension TestReevedServer {
    fileprivate static func dropDatabase(dbName: String, rootDSN: String) throws {
        let env = ProcessInfo.processInfo.environment
        let user = env["PGTESTDB_USER"] ?? "clark"
        let pass = env["PGTESTDB_PASSWORD"] ?? "clark"
        let root = env["PGTESTDB_DB"] ?? "clark"
        // FORCE disconnects any leftover sessions; otherwise DROP fails if
        // reeved hasn't fully released its pool.
        let (rc, out) = try runPSQLInContainer(
            user: user, password: pass, db: root,
            sql: "DROP DATABASE IF EXISTS \"\(dbName)\" WITH (FORCE);"
        )
        if rc != 0 {
            throw HarnessError.databaseSetupFailed("DROP DATABASE \(dbName): \(out)")
        }
    }
}

private func runGooseMigrations(dsn: String, repoRoot: String) throws {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = [
        "goose",
        "-dir", "db/migrations",
        "postgres", dsn, "up"
    ]
    proc.currentDirectoryURL = URL(fileURLWithPath: repoRoot)
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    try proc.run()
    proc.waitUntilExit()
    if proc.terminationStatus != 0 {
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        let s = String(data: data, encoding: .utf8) ?? ""
        throw HarnessError.databaseSetupFailed("goose up: \(s)")
    }
}

private func pickFreePort() throws -> Int {
    // Bind a Darwin TCP socket to port 0, ask the kernel what port we got,
    // close, return. Vulnerable to a TOCTOU race in theory; in practice
    // good enough for a single-process test harness.
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    if sock < 0 { throw HarnessError.noFreePort }
    defer { close(sock) }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindRC = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
            Darwin.bind(sock, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if bindRC != 0 { throw HarnessError.noFreePort }

    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameRC = withUnsafeMutablePointer(to: &bound) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
            getsockname(sock, rebound, &len)
        }
    }
    if nameRC != 0 { throw HarnessError.noFreePort }
    return Int(UInt16(bigEndian: bound.sin_port))
}

private func tcpProbe(host: String, port: Int) -> Bool {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    if sock < 0 { return false }
    defer { close(sock) }
    // Short non-blocking-ish dial via SO_SNDTIMEO.
    var tv = timeval(tv_sec: 0, tv_usec: 200_000)
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(port).bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr(host))

    let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
            Darwin.connect(sock, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return rc == 0
}

/// Thread-safe accumulator for piped subprocess output.
final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    func snapshotString() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
