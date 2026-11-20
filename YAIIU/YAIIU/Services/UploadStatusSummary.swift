import Foundation

/// Where a photo stands on its way to the server, as shown on the Upload tab.
/// Declaration order is display order.
enum UploadStage: CaseIterable, Hashable {
    case uploading
    case failed
    case queued
    case uploaded
    case waitingForHash
    case checkingServer
    case notUploaded
    case hashError

    /// Stages backed by the live upload queue rather than the hash cache.
    var isQueueStage: Bool {
        switch self {
        case .uploading, .failed, .queued: return true
        default: return false
        }
    }
}

struct UploadStatusSummary: Equatable {
    var identifiers: [UploadStage: [String]] = [:]

    func count(_ stage: UploadStage) -> Int {
        identifiers[stage]?.count ?? 0
    }

    var total: Int {
        identifiers.values.reduce(0) { $0 + $1.count }
    }

    /// One stage per photo. The live queue wins over the hash cache, and
    /// queued photos no longer in the library still count in their stage.
    static func make(
        libraryIdentifiers: [String],
        statusCache: [String: PhotoSyncStatus],
        queue: [String: UploadStatus]
    ) -> UploadStatusSummary {
        var summary = UploadStatusSummary()
        var seen = Set<String>()
        seen.reserveCapacity(libraryIdentifiers.count)

        func add(_ id: String, _ stage: UploadStage) {
            summary.identifiers[stage, default: []].append(id)
        }

        for id in libraryIdentifiers where seen.insert(id).inserted {
            if let status = queue[id] {
                add(id, stage(for: status))
            } else {
                add(id, stage(for: statusCache[id]))
            }
        }
        for (id, status) in queue.sorted(by: { $0.key < $1.key }) where !seen.contains(id) {
            add(id, stage(for: status))
        }
        return summary
    }

    static func stage(for status: UploadStatus) -> UploadStage {
        switch status {
        case .preparing, .uploading, .processing: return .uploading
        case .failed: return .failed
        case .pending: return .queued
        case .completed: return .uploaded
        }
    }

    static func stage(for status: PhotoSyncStatus?) -> UploadStage {
        switch status {
        case .none, .processing: return .waitingForHash
        case .pending, .checking: return .checkingServer
        case .uploaded: return .uploaded
        case .notUploaded: return .notUploaded
        case .error: return .hashError
        }
    }
}
