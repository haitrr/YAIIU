import Combine
import Foundation
import Photos

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

/// Feeds the Upload tab. Classifies the whole library off the main thread and
/// reloads history whenever the hash cache, upload queue or library changes.
@MainActor
final class UploadStatusModel: ObservableObject {
    static let recentLimit = 50

    /// nil until the hash status cache has loaded once.
    @Published private(set) var summary: UploadStatusSummary?
    @Published private(set) var recent: [RecentUpload] = []

    private weak var uploadManager: UploadManager?
    private var cancellables = Set<AnyCancellable>()
    private var pollTimer: AnyCancellable?
    private let refresh = PassthroughSubject<Void, Never>()
    private var computeTask: Task<Void, Never>?
    private var libraryIdentifiers: [String] = []
    private var libraryGeneration: Int?
    private var lastQueueSnapshot: [String: UploadStatus]?

    func start(uploadManager: UploadManager) {
        stop()
        self.uploadManager = uploadManager
        let hash = HashManager.shared
        let library = PhotoLibraryManager.shared

        refresh
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.recompute(force: true)
                self?.reloadRecent()
            }
            .store(in: &cancellables)

        // @Published sinks fire before the value is stored; the debounce
        // above reads the settled values.
        let trigger: (Any) -> Void = { [weak self] _ in self?.refresh.send() }
        hash.$syncStatusCache.sink(receiveValue: trigger).store(in: &cancellables)
        hash.$hasLoadedSyncStatusCache.sink(receiveValue: trigger).store(in: &cancellables)
        uploadManager.$uploadQueue.sink(receiveValue: trigger).store(in: &cancellables)
        uploadManager.$uploadedCount.sink(receiveValue: trigger).store(in: &cancellables)
        library.$assetFetchGeneration.sink(receiveValue: trigger).store(in: &cancellables)
        uploadManager.$isUploading
            .removeDuplicates()
            .sink { [weak self] uploading in
                self?.setPolling(uploading)
                self?.refresh.send()
            }
            .store(in: &cancellables)

        recompute(force: true)
        reloadRecent()
    }

    func stop() {
        cancellables.removeAll()
        pollTimer = nil
        computeTask?.cancel()
        computeTask = nil
    }

    /// Queue item statuses change without republishing the queue; poll them
    /// while a run is active and recompute only when something moved.
    private func setPolling(_ isUploading: Bool) {
        pollTimer = isUploading
            ? Timer.publish(every: 1, on: .main, in: .common).autoconnect()
                .sink { [weak self] _ in self?.recompute(force: false) }
            : nil
    }

    private func recompute(force: Bool) {
        guard let uploadManager else { return }
        let hash = HashManager.shared
        guard hash.hasLoadedSyncStatusCache else {
            summary = nil
            return
        }

        var queue: [String: UploadStatus] = [:]
        queue.reserveCapacity(uploadManager.uploadQueue.count)
        for item in uploadManager.uploadQueue {
            queue[item.localIdentifier] = item.status
        }
        let library = PhotoLibraryManager.shared
        let generation = library.assetFetchGeneration
        let cachedIdentifiers = libraryGeneration == generation ? libraryIdentifiers : nil
        if !force, cachedIdentifiers != nil, queue == lastQueueSnapshot { return }
        lastQueueSnapshot = queue

        let statusCache = hash.syncStatusCache
        let fetchResult = library.fetchResult
        computeTask?.cancel()
        computeTask = Task { [weak self] in
            let (identifiers, summary) = await Task.detached(priority: .utility) {
                let identifiers = cachedIdentifiers ?? Self.identifiers(in: fetchResult)
                let summary = UploadStatusSummary.make(
                    libraryIdentifiers: identifiers, statusCache: statusCache, queue: queue
                )
                return (identifiers, summary)
            }.value
            guard let self else { return }
            // Keep the scan even when superseded, so a large library is
            // not re-enumerated by every poll tick that cancels this task.
            if cachedIdentifiers == nil, self.libraryGeneration != generation,
               PhotoLibraryManager.shared.assetFetchGeneration == generation {
                self.libraryIdentifiers = identifiers
                self.libraryGeneration = generation
            }
            guard !Task.isCancelled, self.summary != summary else { return }
            self.summary = summary
        }
    }

    private func reloadRecent() {
        DatabaseManager.shared.recentUploadsAsync(limit: Self.recentLimit) { [weak self] uploads in
            guard let self, self.recent != uploads else { return }
            self.recent = uploads
        }
    }

    nonisolated private static func identifiers(in fetchResult: PHFetchResult<PHAsset>?) -> [String] {
        guard let fetchResult else { return [] }
        var identifiers: [String] = []
        identifiers.reserveCapacity(fetchResult.count)
        fetchResult.enumerateObjects { asset, _, _ in identifiers.append(asset.localIdentifier) }
        return identifiers
    }
}
