import CoreTransferable
import Foundation
import UniformTypeIdentifiers

nonisolated struct CaptureDragExport: Transferable, Sendable {
    let url: URL
    let isVideo: Bool
    var isReady: Bool = true

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .movie) { item in
            return SentTransferredFile(try await RecordingDeliverable.resolve(for: item.url))
        }
        .exportingCondition { $0.isVideo }
        ProxyRepresentation { $0.url }
            .exportingCondition { !$0.isVideo && $0.isReady }
    }
}
