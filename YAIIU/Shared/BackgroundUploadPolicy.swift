import Foundation
import Photos

/// Network state used to decide whether the extension may create new upload jobs.
public enum BackgroundUploadNetworkInterface: Equatable {
    case wifi
    case cellular
    case other
    case unavailable
    case unknown
}

public enum BackgroundUploadPolicy {
    /// Existing retry and acknowledgement jobs are not subject to this policy.
    public static func canCreateNewJobs(
        allowCellular: Bool,
        interface: BackgroundUploadNetworkInterface
    ) -> Bool {
        switch interface {
        case .wifi:
            return true
        case .cellular:
            return allowCellular
        case .other, .unavailable, .unknown:
            return false
        }
    }
    public enum RequestPurpose {
        case newJob
        case retry
    }

    public static func allowsCellularAccess(
        for purpose: RequestPurpose,
        allowCellular: Bool
    ) -> Bool {
        switch purpose {
        case .newJob:
            return allowCellular
        case .retry:
            return true
        }
    }
    /// Bound diagnostic retries and keep all copies of a selected asset together.
    public static func isolationGroups<Item, AssetID: Hashable>(
        _ jobs: [Item],
        maxGroups: Int,
        assetIdentifier: (Item) -> AssetID
    ) -> [[Item]] {
        guard maxGroups > 0 else { return [] }
        var groups = [[Item]]()
        var indices = [AssetID: Int]()
        for job in jobs {
            let identifier = assetIdentifier(job)
            if let index = indices[identifier] {
                groups[index].append(job)
            } else if groups.count < maxGroups {
                indices[identifier] = groups.count
                groups.append([job])
            }
        }
        return groups
    }

}

/// Limits public-API state recovery across extension process lifetimes.
final class BackgroundUploadCreationRecovery {
    private let preferences: UserDefaults?
    private let attemptedKey = "yaiiu_background_upload_creation_recovery_attempted"

    init(preferences: UserDefaults?) {
        self.preferences = preferences
    }

    /// A creation failure can mean PhotoKit is still finishing its previous pass.
    /// Permit one yield to the system, not an unlimited retry loop for bad resources.
    func requestRetry(after error: NSError) -> Bool {
        guard error.domain == "PHPhotosErrorDomain", error.code == -1,
              let preferences, !preferences.bool(forKey: attemptedKey) else {
            return false
        }
        preferences.set(true, forKey: attemptedKey)
        return true
    }

    func recordSuccessfulCreation() {
        preferences?.removeObject(forKey: attemptedKey)
    }
}

/// Resource type names stored in uploaded_assets/upload_jobs.resource_type and
/// embedded in deviceAssetId ("<assetId>-<type>-<filename>").
enum UploadResourceKind {
    static func name(for type: PHAssetResourceType, uniformTypeIdentifier: String) -> String {
        // A Live Photo clip's UTI is a QuickTime movie; classify it by resource
        // type before the UTI checks so it is never stored as a plain "video".
        if LivePhotoResourcePolicy.isPairedVideo(type) {
            return LivePhotoResourcePolicy.resourceType
        }
        let uti = uniformTypeIdentifier.lowercased()
        let rawIndicators = ["raw-image", "dng", "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2"]
        if rawIndicators.contains(where: uti.contains) || type == .alternatePhoto {
            return "raw"
        }
        if uti.contains("video") || uti.contains("movie") || uti.contains("mp4") || uti.contains("quicktime")
            || type == .video || type == .fullSizeVideo {
            return "video"
        }
        if type == .photo || type == .fullSizePhoto {
            if uti.contains("heic") || uti.contains("heif") { return "heic" }
            if uti.contains("png") { return "png" }
            return "jpeg"
        }
        return "primary"
    }
}

/// A Live Photo's motion clip is a .pairedVideo resource; editing the photo adds a
/// .fullSizePairedVideo holding the edited clip.
enum LivePhotoResourcePolicy {
    /// Underscored so "-live_video-" in a deviceAssetId never contains the "-video-"
    /// separator. Like "raw", it is a companion: it never confirms the still.
    static let resourceType = "live_video"
    /// Builds before Live Photo support uploaded the clip in the foreground as "video".
    static let legacyResourceType = "video"

    static func isPairedVideo(_ type: PHAssetResourceType) -> Bool {
        type == .pairedVideo || type == .fullSizePairedVideo
    }

    /// The clip to upload, preferring the edited version like .fullSizePhoto.
    static func preferredPairedVideoIndex(in types: [PHAssetResourceType]) -> Int? {
        types.firstIndex(of: .fullSizePairedVideo) ?? types.firstIndex(of: .pairedVideo)
    }

    /// Paired clips that must not be uploaded because an edited clip replaces them.
    static func supersededPairedVideoIndices(in types: [PHAssetResourceType]) -> Set<Int> {
        guard let preferred = preferredPairedVideoIndex(in: types) else { return [] }
        return Set(types.indices.filter { isPairedVideo(types[$0]) && $0 != preferred })
    }
}
