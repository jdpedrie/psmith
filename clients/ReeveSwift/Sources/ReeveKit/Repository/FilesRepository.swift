import Foundation
import Connect

/// Client-side handle for a uploaded file. Returned by
/// `FilesRepository.upload` and recorded by view models as the
/// "pending attachment" they'll bind onto the next SendMessage.
public struct ReeveFile: Sendable, Hashable, Identifiable {
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
    private let client: Reeve_V1_FilesServiceClientInterface

    /// Bytes-per-chunk on the upload stream. 64KB is a round
    /// number that fits comfortably in one TCP packet's worth of
    /// MTU, keeps a single 50MB upload to ~800 messages on the
    /// wire, and matches Connect-swift's framing sweet spot.
    public static let chunkSize = 64 * 1024

    public init(client: Reeve_V1_FilesServiceClientInterface) {
        self.client = client
    }

    /// Upload `data` as one file. Returns the server-assigned
    /// `ReeveFile` on success. Errors surface as `ReeveError` (via
    /// `ReeveError.display`) so callers don't have to know about
    /// Connect's error envelope.
    public func upload(
        data: Data,
        mimeType: String,
        originalFilename: String?
    ) async throws -> ReeveFile {
        let stream = client.uploadFile(headers: [:])

        // Header first. The server validates the declared size +
        // mime and rejects oversized uploads before any bytes
        // land on disk.
        var header = Reeve_V1_UploadFileHeader()
        header.mimeType = mimeType
        header.sizeBytes = Int64(data.count)
        if let originalFilename, !originalFilename.isEmpty {
            header.originalFilename = originalFilename
        }
        var headerReq = Reeve_V1_UploadFileRequest()
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
            var chunkReq = Reeve_V1_UploadFileRequest()
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
        var response: Reeve_V1_UploadFileResponse?
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
            // practice; ReeveError.from converts that. If we got
            // something else (rare), fall through to a generic
            // missingPayload.
            if let ce = streamError as? ConnectError {
                throw ReeveError.from(ce)
            }
            throw ReeveError.missingPayload("upload: \(ReeveError.display(streamError))")
        }
        guard let response else {
            throw ReeveError.missingPayload("upload file response")
        }

        return ReeveFile(
            id: response.fileID,
            sha256: response.sha256,
            mimeType: response.mimeType,
            sizeBytes: response.sizeBytes,
            originalFilename: response.hasOriginalFilename ? response.originalFilename : nil,
            createdAt: response.hasCreatedAt ? response.createdAt.date : Date()
        )
    }

    /// Mint a short-lived signed URL for the given file_id.
    public func signedURL(fileID: String) async throws -> URL {
        var req = Reeve_V1_GetFileURLRequest()
        req.fileID = fileID
        let resp = await client.getFileURL(request: req, headers: [:])
        guard let msg = resp.message else {
            throw resp.error.map(ReeveError.from) ?? .missingPayload("get file url")
        }
        guard let url = URL(string: msg.url) else {
            throw ReeveError.missingPayload("server returned an invalid file url")
        }
        return url
    }

    /// List the caller's recent files. `limit` defaults to the
    /// server's own default (currently 50).
    public func list(limit: Int32? = nil) async throws -> [ReeveFile] {
        var req = Reeve_V1_ListFilesRequest()
        if let limit { req.limit = limit }
        let resp = await client.listFiles(request: req, headers: [:])
        guard let msg = resp.message else {
            throw resp.error.map(ReeveError.from) ?? .missingPayload("list files")
        }
        return msg.files.map {
            ReeveFile(
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
