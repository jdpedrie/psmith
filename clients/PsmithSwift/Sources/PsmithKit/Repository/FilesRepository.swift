import Foundation
import Connect

/// Client-side handle for a uploaded file. Returned by
/// `FilesRepository.upload` and recorded by view models as the
/// "pending attachment" they'll bind onto the next SendMessage.
public struct PsmithFile: Sendable, Hashable, Identifiable {
    public let id: String
    public let sha256: String
    public let mimeType: String
    public let sizeBytes: Int64
    public let originalFilename: String?
    public let createdAt: Date

    public init(
        id: String,
        sha256: String,
        mimeType: String,
        sizeBytes: Int64,
        originalFilename: String?,
        createdAt: Date
    ) {
        self.id = id
        self.sha256 = sha256
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.originalFilename = originalFilename
        self.createdAt = createdAt
    }
}

/// Repository over the generated FilesService client. Wraps the
/// client-streaming upload + the unary signed-URL + list endpoints
/// in friendly async APIs.
public final class FilesRepository: Sendable {
    private let client: Psmith_V1_FilesServiceClientInterface
    /// psmithd host used to resolve relative signed URLs. When the
    /// server doesn't have PSMITH_PUBLIC_BASE_URL set, GetFileURL
    /// returns a path-only URL like `/files/{id}?token=…` and we
    /// have to graft the host on at the client. Stored at init so
    /// every signedURL call uses the same base the rest of the
    /// repositories talk to.
    private let host: URL

    /// Bytes-per-chunk on the upload stream. 64KB is a round
    /// number that fits comfortably in one TCP packet's worth of
    /// MTU, keeps a single 50MB upload to ~800 messages on the
    /// wire, and matches Connect-swift's framing sweet spot.
    public static let chunkSize = 64 * 1024

    public init(client: Psmith_V1_FilesServiceClientInterface, host: URL) {
        self.client = client
        self.host = host
    }

    /// Upload `data` as one file. Returns the server-assigned
    /// `PsmithFile` on success. Errors surface as `PsmithError` (via
    /// `PsmithError.display`) so callers don't have to know about
    /// Connect's error envelope.
    public func upload(
        data: Data,
        mimeType: String,
        originalFilename: String?
    ) async throws -> PsmithFile {
        let stream = client.uploadFile(headers: [:])

        // Header first. The server validates the declared size +
        // mime and rejects oversized uploads before any bytes
        // land on disk.
        var header = Psmith_V1_UploadFileHeader()
        header.mimeType = mimeType
        header.sizeBytes = Int64(data.count)
        if let originalFilename, !originalFilename.isEmpty {
            header.originalFilename = originalFilename
        }
        var headerReq = Psmith_V1_UploadFileRequest()
        headerReq.header = header
        do {
            try stream.send(headerReq)
        } catch {
            stream.cancel()
            throw error
        }

        // Bytes in fixed-size chunks. Slice the Data via subscript
        // rather than withUnsafeBytes — Connect-swift expects
        // `chunk` to be a regular Foundation `Data` value.
        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.chunkSize, data.count)
            var chunkReq = Psmith_V1_UploadFileRequest()
            chunkReq.chunk = data.subdata(in: offset..<end)
            do {
                try stream.send(chunkReq)
            } catch {
                stream.cancel()
                throw error
            }
            offset = end
        }
        stream.closeAndReceive()

        // Drain the response. Connect's `results()` returns one
        // headers result, one message result, one trailers result
        // for a successful unary-on-client-stream call.
        var response: Psmith_V1_UploadFileResponse?
        var streamError: Error?
        for await event in stream.results() {
            switch event {
            case .headers:
                continue
            case .message(let msg):
                response = msg
            case .complete(_, let err, _):
                if let err {
                    streamError = err
                }
            }
        }
        if let streamError {
            // The error coming off `results()` is a Connect.Error in
            // practice; PsmithError.from converts that. If we got
            // something else (rare), fall through to a generic
            // missingPayload.
            if let ce = streamError as? ConnectError {
                throw PsmithError.from(ce)
            }
            throw PsmithError.missingPayload("upload: \(PsmithError.display(streamError))")
        }
        guard let response else {
            throw PsmithError.missingPayload("upload file response")
        }

        return PsmithFile(
            id: response.fileID,
            sha256: response.sha256,
            mimeType: response.mimeType,
            sizeBytes: response.sizeBytes,
            originalFilename: response.hasOriginalFilename ? response.originalFilename : nil,
            createdAt: response.hasCreatedAt ? response.createdAt.date : Date()
        )
    }

    /// Mint a short-lived signed URL for the given file_id. The
    /// returned URL is always absolute — when the server returns a
    /// relative path (the default when PSMITH_PUBLIC_BASE_URL isn't
    /// set), we resolve it against the configured psmithd host so
    /// the caller can hand it straight to AsyncImage.
    public func signedURL(fileID: String) async throws -> URL {
        var req = Psmith_V1_GetFileURLRequest()
        req.fileID = fileID
        let resp = await client.getFileURL(request: req, headers: [:])
        guard let msg = resp.message else {
            throw resp.error.map(PsmithError.from) ?? .missingPayload("get file url")
        }
        // Parse the raw string. If the server gave us an absolute
        // URL (production / PSMITH_PUBLIC_BASE_URL set), use it as-
        // is; if it gave us a relative path, resolve against host.
        if let abs = URL(string: msg.url), abs.scheme != nil, abs.host != nil {
            return abs
        }
        if let rel = URL(string: msg.url, relativeTo: host)?.absoluteURL {
            return rel
        }
        throw PsmithError.missingPayload("server returned an invalid file url")
    }

    /// List the caller's recent files. `limit` defaults to the
    /// server's own default (currently 50).
    public func list(limit: Int32? = nil) async throws -> [PsmithFile] {
        var req = Psmith_V1_ListFilesRequest()
        if let limit { req.limit = limit }
        let resp = await client.listFiles(request: req, headers: [:])
        guard let msg = resp.message else {
            throw resp.error.map(PsmithError.from) ?? .missingPayload("list files")
        }
        return msg.files.map {
            PsmithFile(
                id: $0.id,
                sha256: $0.sha256,
                mimeType: $0.mimeType,
                sizeBytes: $0.sizeBytes,
                originalFilename: $0.hasOriginalFilename ? $0.originalFilename : nil,
                createdAt: $0.hasCreatedAt ? $0.createdAt.date : Date()
            )
        }
    }
}
