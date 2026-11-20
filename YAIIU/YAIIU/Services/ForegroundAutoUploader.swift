import Combine
import Foundation
import Photos

/// Uploads everything not yet uploaded while the app is open, including
/// photos taken while it stays open. It feeds the same queue as manual
/// uploads, so progress shows on the Upload screen.
///
/// Each photo is queued as soon as it is known to be missing from the server,
/// and joins an upload that is already running:
/// - on open, photos an earlier verification found missing, without waiting
///   for this launch's server sync or hashing;
/// - while hashing runs, each batch the moment it is verified;
/// - once status settles, a full-library sweep catches anything else.
/// A photo that was never verified is not queued: it may be on the server.
@MainActor
final class ForegroundAutoUploader: ObservableObject {
    /// Photos already queued during this activation; a failed one is not
    /// retried until the app comes to the front again.
    private var attemptedThisActivation = Set<String>()
    private var needsRecheck = false
    private var latestRequest: (isStatusReady: Bool, fetchResult: PHFetchResult<PHAsset>?, statusCache: [String: PhotoSyncStatus])?
    private var isAutoSessionActive = false
    private var isPausedForNetwork = false
    /// The user paused uploading; nothing new is queued until they resume or
    /// the app is opened again.
    private var isPausedByUser = false
    private var isPreparing = false
    private var isLoadingVerifiedMissing = false
    private var needsVerifiedMissingReload = false
    private weak var uploadManager: UploadManager?
    private weak var settingsManager: SettingsManager?
    private var cancellables = Set<AnyCancellable>()

    func bind(
        uploadManager: UploadManager,
        settingsManager: SettingsManager,
        hashManager: HashManager = .shared
    ) {
        guard self.uploadManager !== uploadManager || self.settingsManager !== settingsManager else { return }
        self.uploadManager = uploadManager
        self.settingsManager = settingsManager
        cancellables.removeAll()

        uploadManager.$isUploading
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] uploading in self?.uploadingChanged(uploading) }
            .store(in: &cancellables)
        NetworkReachability.shared.$networkInterface
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.networkOrSettingChanged() }
            .store(in: &cancellables)
        settingsManager.$allowCellularBackgroundUpload
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.networkOrSettingChanged() }
            .store(in: &cancellables)
        settingsManager.$autoUploadOnOpen
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.queueVerifiedMissing() }
            .store(in: &cancellables)
        hashManager.assetsVerifiedMissingFromServer
            .receive(on: RunLoop.main)
            .sink { [weak self] identifiers in
                self?.queue(identifiers: identifiers, source: "verified while hashing")
            }
            .store(in: &cancellables)
        // The end-of-run batch check may have found more missing photos.
        hashManager.$isProcessing
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.queueVerifiedMissing() }
            .store(in: &cancellables)
    }

    /// The app came to the front: photos that failed may be retried, and a
    /// pause from the previous visit no longer applies.
    func activationBegan() {
        attemptedThisActivation.removeAll()
        isPausedByUser = false
    }

    /// Queues photos an earlier checksum verification found missing from the
    /// server. Needs no network round-trip or hashing, so uploads begin
    /// right after the app opens.
    func queueVerifiedMissing() {
        guard canQueue else { return }
        guard !isLoadingVerifiedMissing else {
            needsVerifiedMissingReload = true
            return
        }
        isLoadingVerifiedMissing = true
        Task.detached(priority: .userInitiated) { [weak self] in
            // A negative result only means something against a server baseline.
            let hasBaseline = DatabaseManager.shared.getSyncMetadata()?.lastSyncTime != nil
            let identifiers = hasBaseline
                ? DatabaseManager.shared.verifiedNotUploadedIdentifiers(visibleOnly: true) ?? []
                : []
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isLoadingVerifiedMissing = false
                self.queue(identifiers: identifiers, source: "verified earlier")
                if self.needsVerifiedMissingReload {
                    self.needsVerifiedMissingReload = false
                    self.queueVerifiedMissing()
                }
            }
        }
    }

    /// Full-library sweep, once upload status is authoritative. Call whenever
    /// upload status may have changed, or the network or setting changed.
    func startIfNeeded(
        isStatusReady: Bool,
        fetchResult: PHFetchResult<PHAsset>?,
        statusCache: [String: PhotoSyncStatus]
    ) {
        latestRequest = (isStatusReady, fetchResult, statusCache)
        guard !isPreparing else {
            // Re-run with the newest state once the current scan finishes.
            needsRecheck = true
            return
        }
        guard let uploadManager, let settingsManager, !isPausedByUser else { return }
        // fetchResult.count is an upper bound; the exact count needs a scan.
        guard let fetchResult, ForegroundAutoUploadPolicy.shouldStart(
            isEnabled: settingsManager.autoUploadOnOpen,
            isStatusReady: isStatusReady,
            pendingCount: fetchResult.count,
            isUploading: uploadManager.isUploading,
            isNetworkAllowed: isNetworkAllowed
        ) else { return }

        isPreparing = true
        let attempted = attemptedThisActivation
        Task.detached(priority: .userInitiated) { [weak self] in
            var identifiers: [String] = []
            fetchResult.enumerateObjects { asset, _, _ in
                identifiers.append(asset.localIdentifier)
            }
            let pending = ForegroundAutoUploadPolicy.notUploadedIdentifiers(
                identifiers, statusCache: statusCache, excluding: attempted
            )

            await MainActor.run { [weak self] in
                self?.finishPreparing(identifiers: pending)
            }
        }
    }

    private func finishPreparing(identifiers: [String]) {
        isPreparing = false
        queue(identifiers: identifiers, source: "library sweep")
        if needsRecheck, let request = latestRequest {
            needsRecheck = false
            startIfNeeded(
                isStatusReady: request.isStatusReady,
                fetchResult: request.fetchResult,
                statusCache: request.statusCache
            )
        }
    }

    /// Adds photos to the upload queue, newest first, starting the upload or
    /// joining the one already running.
    private func queue(identifiers: [String], source: String) {
        guard canQueue else { return }
        let fresh = ForegroundAutoUploadPolicy.unattempted(identifiers, excluding: attemptedThisActivation)
        guard !fresh.isEmpty else { return }
        attemptedThisActivation.formUnion(fresh)

        Task.detached(priority: .userInitiated) { [weak self] in
            // Deleted and hidden photos drop out here.
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let result = PHAsset.fetchAssets(withLocalIdentifiers: fresh, options: options)
            var assets: [PHAsset] = []
            assets.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in assets.append(asset) }

            await MainActor.run { [weak self] in
                self?.enqueue(assets, requested: fresh, source: source)
            }
        }
    }

    private func enqueue(_ assets: [PHAsset], requested: [String], source: String) {
        // Re-check: the user may have paused or left Wi-Fi meanwhile.
        guard canQueue, let uploadManager else {
            attemptedThisActivation.subtract(requested)
            return
        }
        guard !assets.isEmpty else { return }
        isAutoSessionActive = true
        isPausedForNetwork = false
        logInfo("Auto upload: queuing \(assets.count) asset(s) missing from server (\(source))", category: .upload)
        uploadManager.uploadAssets(assets)
    }

    private var canQueue: Bool {
        guard let settingsManager else { return false }
        return ForegroundAutoUploadPolicy.canQueue(
            isEnabled: settingsManager.autoUploadOnOpen,
            hasServer: !settingsManager.activeServerURL.isEmpty && !settingsManager.apiKey.isEmpty,
            isNetworkAllowed: isNetworkAllowed,
            isPausedByUser: isPausedByUser
        )
    }

    private var isNetworkAllowed: Bool {
        ForegroundAutoUploadPolicy.isNetworkAllowed(
            allowCellular: settingsManager?.allowCellularBackgroundUpload ?? false,
            interface: NetworkReachability.shared.networkInterface
        )
    }

    private func uploadingChanged(_ uploading: Bool) {
        if uploading {
            isPausedForNetwork = false
            isPausedByUser = false
        } else if !isPausedForNetwork {
            // Finished, or paused by the user: the automatic session is over.
            isAutoSessionActive = false
            if uploadManager?.isPaused == true {
                isPausedByUser = true
            }
        }
    }

    private func networkOrSettingChanged() {
        applyNetworkPolicy()
        // Photos skipped while the network was not allowed can go now.
        queueVerifiedMissing()
    }

    private func applyNetworkPolicy() {
        guard let uploadManager else { return }
        switch ForegroundAutoUploadPolicy.networkAction(
            isAutoSessionActive: isAutoSessionActive,
            isUploading: uploadManager.isUploading,
            isPausedForNetwork: isPausedForNetwork,
            isNetworkAllowed: isNetworkAllowed
        ) {
        case .none:
            break
        case .pause:
            logInfo("Auto upload on open: pausing, current network not allowed", category: .upload)
            isPausedForNetwork = true
            uploadManager.pauseUpload()
        case .resume:
            logInfo("Auto upload on open: resuming on allowed network", category: .upload)
            uploadManager.resumeUpload()
            if !uploadManager.isUploading {
                // Nothing left to resume.
                isPausedForNetwork = false
                isAutoSessionActive = false
            }
        }
    }
}
