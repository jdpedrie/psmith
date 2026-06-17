import Foundation

/// One pending attachment that the user has uploaded but not yet
/// sent. Lives on `ConversationViewModel.pendingAttachments` until
/// SendMessage binds it via `attachment_file_ids`.
///
/// `previewData` keeps the preprocessed bytes around so the
/// composer's chip strip can render an instant local thumbnail —
/// no round-trip through `GetFileURL` + image-loader for content
/// the client already has in memory. Drops out of memory when the
/// user sends or removes the chip.
public struct PendingAttachment: Sendable, Hashable, Identifiable {
    public let fileID: String
    public let mimeType: String
    public let originalFilename: String?
    public let previewData: Data
    public let width: Int
    public let height: Int

    public var id: String { fileID }

    public init(
        fileID: String,
        mimeType: String,
        originalFilename: String?,
        previewData: Data,
        width: Int,
        height: Int
    ) {
        self.fileID = fileID
        self.mimeType = mimeType
        self.originalFilename = originalFilename
        self.previewData = previewData
        self.width = width
        self.height = height
    }
}
