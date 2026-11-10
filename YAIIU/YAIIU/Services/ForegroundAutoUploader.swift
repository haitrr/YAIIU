import Combine
import Foundation
import Photos

/// Uploads everything not yet uploaded while the app is open, including
/// photos taken while it stays open. It feeds the same queue as manual
/// uploads, so progress shows on the Upload screen.
@MainActor
final class ForegroundAutoUploader: ObservableObject {
    /// Photos already queued during this activation; a failed one is not
    /// retried until the app comes to the front again.
    private var attemptedThisActivation = Set<String>()
    private var needsRecheck = false
    private var latestRequest: (isStatusReady: Bool, fetchResult: PHFetchResult<PHAsset>?, statusCache: [String: PhotoSyncStatus])?
    private var isAutoSessionActive = false
    private var isPausedForNetwork = false
    private var isPreparing = false
    private weak var uploadManager: UploadManager?
    private weak var settingsManager: SettingsManager?
    private var cancellables = Set<AnyCancellable>()

    func bind(uploadManager: UploadManager, settingsManager: SettingsManager) {
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
            .sink { [weak self] _ in self?.applyNetworkPolicy() }
            .store(in: &cancellables)
        settingsManager.$allowCellularBackgroundUpload
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyNetworkPolicy() }
            .store(in: &cancellables)
    }

    /// The app came to the front: photos that failed may be retried.
    func activationBegan() {
        attemptedThisActivation.removeAll()
    }

    /// Call whenever upload status may have changed, or the network or
    /// setting changed. Queues every not-uploaded photo not yet attempted.
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
        guard let uploadManager, let settingsManager else { return }
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
            let result = PHAsset.fetchAssets(withLocalIdentifiers: pending, options: nil)
            var assets: [PHAsset] = []
            assets.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in assets.append(asset) }

            await MainActor.run { [weak self] in
                self?.finishPreparing(assets: assets)
            }
        }
    }

    private func finishPreparing(assets: [PHAsset]) {
        isPreparing = false
        defer {
            if needsRecheck, let request = latestRequest {
                needsRecheck = false
                startIfNeeded(
                    isStatusReady: request.isStatusReady,
                    fetchResult: request.fetchResult,
                    statusCache: request.statusCache
                )
            }
        }
        guard let uploadManager, let settingsManager else { return }
        // Re-check: the user may have started an upload or left Wi-Fi meanwhile.
        guard ForegroundAutoUploadPolicy.shouldStart(
            isEnabled: settingsManager.autoUploadOnOpen,
            isStatusReady: true,
            pendingCount: assets.count,
            isUploading: uploadManager.isUploading,
            isNetworkAllowed: isNetworkAllowed
        ) else { return }

        attemptedThisActivation.formUnion(assets.map(\.localIdentifier))
        isAutoSessionActive = true
        isPausedForNetwork = false
        logInfo("Auto upload: queuing \(assets.count) not-uploaded assets", category: .upload)
        uploadManager.uploadAssets(assets)
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
        } else if !isPausedForNetwork {
            // Finished, or paused by the user: the automatic session is over.
            isAutoSessionActive = false
        }
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
