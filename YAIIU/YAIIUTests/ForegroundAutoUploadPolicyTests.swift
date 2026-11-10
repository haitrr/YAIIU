import XCTest
@testable import YAIIU

final class ForegroundAutoUploadPolicyTests: XCTestCase {
    // MARK: - Network

    func testWifiAlwaysAllowed() {
        XCTAssertTrue(ForegroundAutoUploadPolicy.isNetworkAllowed(allowCellular: false, interface: .wifi))
        XCTAssertTrue(ForegroundAutoUploadPolicy.isNetworkAllowed(allowCellular: true, interface: .wifi))
    }

    func testCellularFollowsSetting() {
        XCTAssertFalse(ForegroundAutoUploadPolicy.isNetworkAllowed(allowCellular: false, interface: .cellular))
        XCTAssertTrue(ForegroundAutoUploadPolicy.isNetworkAllowed(allowCellular: true, interface: .cellular))
    }

    func testNoUsableNetworkIsNeverAllowed() {
        for interface in [BackgroundUploadNetworkInterface.unavailable, .unknown] {
            XCTAssertFalse(ForegroundAutoUploadPolicy.isNetworkAllowed(allowCellular: true, interface: interface))
        }
    }

    // MARK: - Start

    private func shouldStart(
        isEnabled: Bool = true,
        isStatusReady: Bool = true,
        pendingCount: Int = 5,
        isUploading: Bool = false,
        isNetworkAllowed: Bool = true
    ) -> Bool {
        ForegroundAutoUploadPolicy.shouldStart(
            isEnabled: isEnabled,
            isStatusReady: isStatusReady,
            pendingCount: pendingCount,
            isUploading: isUploading,
            isNetworkAllowed: isNetworkAllowed
        )
    }

    func testStartsWhenReadyWithPendingPhotos() {
        XCTAssertTrue(shouldStart())
    }

    func testDoesNotStartWhenDisabled() {
        XCTAssertFalse(shouldStart(isEnabled: false))
    }

    func testWaitsForAuthoritativeStatus() {
        // An unhashed library looks entirely "not uploaded"; starting early
        // would re-send photos the server already has.
        XCTAssertFalse(shouldStart(isStatusReady: false))
    }

    func testNothingToUpload() {
        XCTAssertFalse(shouldStart(pendingCount: 0))
    }

    func testDoesNotInterruptRunningUpload() {
        XCTAssertFalse(shouldStart(isUploading: true))
    }

    func testWaitsForAllowedNetwork() {
        XCTAssertFalse(shouldStart(isNetworkAllowed: false))
    }

    // MARK: - Network changes during an automatic session

    func testPausesWhenNetworkBecomesDisallowed() {
        XCTAssertEqual(
            ForegroundAutoUploadPolicy.networkAction(
                isAutoSessionActive: true, isUploading: true,
                isPausedForNetwork: false, isNetworkAllowed: false
            ),
            .pause
        )
    }

    func testResumesWhenNetworkReturns() {
        XCTAssertEqual(
            ForegroundAutoUploadPolicy.networkAction(
                isAutoSessionActive: true, isUploading: false,
                isPausedForNetwork: true, isNetworkAllowed: true
            ),
            .resume
        )
    }

    func testDoesNotResumeUploadPausedByUser() {
        XCTAssertEqual(
            ForegroundAutoUploadPolicy.networkAction(
                isAutoSessionActive: true, isUploading: false,
                isPausedForNetwork: false, isNetworkAllowed: true
            ),
            .none
        )
    }

    func testLeavesManualUploadsAlone() {
        XCTAssertEqual(
            ForegroundAutoUploadPolicy.networkAction(
                isAutoSessionActive: false, isUploading: true,
                isPausedForNetwork: false, isNetworkAllowed: false
            ),
            .none
        )
    }

    // MARK: - Selection

    func testSkipsPhotosAlreadyAttemptedThisActivation() {
        // A failed upload stays "not uploaded"; retrying it on every status
        // refresh would loop until the user leaves the app.
        let status: [String: PhotoSyncStatus] = ["a": .notUploaded, "b": .notUploaded]
        XCTAssertEqual(
            ForegroundAutoUploadPolicy.notUploadedIdentifiers(["a", "b"], statusCache: status, excluding: ["a"]),
            ["b"]
        )
    }

    func testPicksUpPhotosAddedLaterInTheSameActivation() {
        // "a" was queued on open; "c" was taken while the app stayed open.
        let status: [String: PhotoSyncStatus] = ["a": .uploaded, "c": .notUploaded]
        XCTAssertEqual(
            ForegroundAutoUploadPolicy.notUploadedIdentifiers(["c", "a"], statusCache: status, excluding: ["a"]),
            ["c"]
        )
    }

    func testSelectsEverythingNotMarkedUploaded() {
        let status: [String: PhotoSyncStatus] = [
            "a": .uploaded,
            "b": .notUploaded,
            "c": .error,
        ]
        XCTAssertEqual(
            ForegroundAutoUploadPolicy.notUploadedIdentifiers(["a", "b", "c", "d"], statusCache: status, excluding: []),
            ["b", "c", "d"]
        )
    }
}
