import Foundation

/// Decides when the app uploads everything not yet uploaded while it is open.
enum ForegroundAutoUploadPolicy {
    enum NetworkAction: Equatable {
        case none
        case pause
        case resume
    }

    /// Same network rule as the background extension, so one cellular setting
    /// governs both automatic upload paths.
    static func isNetworkAllowed(allowCellular: Bool, interface: BackgroundUploadNetworkInterface) -> Bool {
        BackgroundUploadPolicy.canCreateNewJobs(allowCellular: allowCellular, interface: interface)
    }

    /// Starts only once upload status is authoritative; an unhashed library
    /// would otherwise look "not uploaded".
    static func shouldStart(
        isEnabled: Bool,
        isStatusReady: Bool,
        pendingCount: Int,
        isUploading: Bool,
        isNetworkAllowed: Bool
    ) -> Bool {
        isEnabled
            && isStatusReady
            && pendingCount > 0
            && !isUploading
            && isNetworkAllowed
    }

    /// Only automatic sessions react to network changes; a session the user
    /// paused, or an upload the user started, is left alone.
    static func networkAction(
        isAutoSessionActive: Bool,
        isUploading: Bool,
        isPausedForNetwork: Bool,
        isNetworkAllowed: Bool
    ) -> NetworkAction {
        guard isAutoSessionActive else { return .none }
        if isUploading && !isNetworkAllowed { return .pause }
        if isPausedForNetwork && !isUploading && isNetworkAllowed { return .resume }
        return .none
    }

    /// Matches "Select All Not Uploaded": anything without an uploaded status,
    /// minus photos already queued during this app activation, so a failed
    /// upload is not retried on every status refresh.
    static func notUploadedIdentifiers<S: Sequence>(
        _ identifiers: S,
        statusCache: [String: PhotoSyncStatus],
        excluding attempted: Set<String>
    ) -> [String] where S.Element == String {
        identifiers.filter { (statusCache[$0] ?? .pending) != .uploaded && !attempted.contains($0) }
    }
}
