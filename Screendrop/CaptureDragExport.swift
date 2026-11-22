import CoreTransferable
import Foundation
import UniformTypeIdentifiers

nonisolated struct CaptureDragExport: Transferable, Sendable {
    let url: URL
    let isVideo: Bool
    var isReady: Bool = true

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .movie) { item in
            try await SentTransferredFile(handOutFile(for: item.url))
        }
        .exportingCondition { $0.isVideo }
        ProxyRepresentation { $0.url }
            .exportingCondition { !$0.isVideo && $0.isReady }
    }

    /// The recording's deliverable, named as its export is.
    @MainActor static func handOutFile(for url: URL) async throws -> URL {
        try VideoFileActions.handOutCopy(of: await RecordingDeliverable.resolve(for: url))
    }
}
