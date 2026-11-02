import Photos
import XCTest
@testable import YAIIU

final class BackgroundUploadPolicyTests: XCTestCase {
    func testDisallowingCellularOnlyAllowsWiFi() {
        XCTAssertTrue(BackgroundUploadPolicy.canCreateNewJobs(allowCellular: false, interface: .wifi))
        XCTAssertFalse(BackgroundUploadPolicy.canCreateNewJobs(allowCellular: false, interface: .cellular))
        XCTAssertFalse(BackgroundUploadPolicy.canCreateNewJobs(allowCellular: false, interface: .other))
        XCTAssertFalse(BackgroundUploadPolicy.canCreateNewJobs(allowCellular: false, interface: .unavailable))
    }

    func testAllowingCellularAllowsWiFiAndCellularOnly() {
        XCTAssertTrue(BackgroundUploadPolicy.canCreateNewJobs(allowCellular: true, interface: .wifi))
        XCTAssertTrue(BackgroundUploadPolicy.canCreateNewJobs(allowCellular: true, interface: .cellular))
        XCTAssertFalse(BackgroundUploadPolicy.canCreateNewJobs(allowCellular: true, interface: .other))
        XCTAssertFalse(BackgroundUploadPolicy.canCreateNewJobs(allowCellular: true, interface: .unavailable))
    }
    func testNewJobRequestDisallowsCellularWhenPreferenceIsOff() {
        XCTAssertFalse(BackgroundUploadPolicy.allowsCellularAccess(for: .newJob, allowCellular: false))
        XCTAssertTrue(BackgroundUploadPolicy.allowsCellularAccess(for: .newJob, allowCellular: true))
    }
    func testRetryRequestRemainsAllowedOnCellular() {
        XCTAssertTrue(BackgroundUploadPolicy.allowsCellularAccess(for: .retry, allowCellular: false))
    }

    func testUnknownNetworkDoesNotCreateJobs() {
        XCTAssertFalse(BackgroundUploadPolicy.canCreateNewJobs(allowCellular: false, interface: .unknown))
        XCTAssertFalse(BackgroundUploadPolicy.canCreateNewJobs(allowCellular: true, interface: .unknown))
    }

    func testUnavailableNetworkDoesNotCreateJobs() {
        XCTAssertFalse(BackgroundUploadPolicy.canCreateNewJobs(allowCellular: true, interface: .unavailable))
    }
    func testIsolationGroupsPreserveAssetSiblings() {
        let jobs = [
            ("asset-a", "heic"), ("asset-b", "jpeg"),
            ("asset-a", "raw"), ("asset-c", "heic")
        ]
        let groups = BackgroundUploadPolicy.isolationGroups(
            jobs, maxGroups: 2, assetIdentifier: { $0.0 }
        )
        XCTAssertEqual(groups.map { $0.map { $0.1 } }, [["heic", "raw"], ["jpeg"]])
    }

    func testIsolationGroupsEnforceBoundAndReturnEmptyForZeroLimit() {
        let jobs = ["a", "b", "a", "c", "d"]
        let bounded = BackgroundUploadPolicy.isolationGroups(
            jobs, maxGroups: 2, assetIdentifier: { $0 }
        )
        XCTAssertEqual(bounded, [["a", "a"], ["b"]])
        let empty = BackgroundUploadPolicy.isolationGroups(
            jobs, maxGroups: 0, assetIdentifier: { $0 }
        )
        XCTAssertTrue(empty.isEmpty)
    }

}

final class BackgroundUploadCreationRecoveryTests: XCTestCase {
    private var suites = [String]()

    override func tearDown() {
        for suite in suites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        super.tearDown()
    }

    private func makePreferences() -> UserDefaults {
        let suite = "BackgroundUploadCreationRecoveryTests.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    func testInternalCreationFailureGetsOnlyOneRecoveryAcrossExtensionInstances() {
        let preferences = makePreferences()
        let error = NSError(domain: "PHPhotosErrorDomain", code: -1)
        let first = BackgroundUploadCreationRecovery(preferences: preferences)
        XCTAssertTrue(first.requestRetry(after: error))
        XCTAssertFalse(first.requestRetry(after: error))
        let relaunched = BackgroundUploadCreationRecovery(preferences: preferences)
        XCTAssertFalse(relaunched.requestRetry(after: error))
    }

    func testSuccessfulCreationAllowsRecoveryOfALaterFailure() {
        let recovery = BackgroundUploadCreationRecovery(preferences: makePreferences())
        let error = NSError(domain: "PHPhotosErrorDomain", code: -1)
        XCTAssertTrue(recovery.requestRetry(after: error))
        recovery.recordSuccessfulCreation()
        XCTAssertTrue(recovery.requestRetry(after: error))
        XCTAssertFalse(recovery.requestRetry(after: error))
    }

    func testOtherErrorsDoNotConsumeOrReceiveStateRecovery() {
        let recovery = BackgroundUploadCreationRecovery(preferences: makePreferences())
        XCTAssertFalse(recovery.requestRetry(after: NSError(domain: NSURLErrorDomain, code: -1)))
        XCTAssertFalse(recovery.requestRetry(after: NSError(domain: "PHPhotosErrorDomain", code: 3201)))
        XCTAssertTrue(recovery.requestRetry(after: NSError(domain: "PHPhotosErrorDomain", code: -1)))
    }

    func testMissingPersistentStorageDoesNotAllowUnboundedRecoveryOnRelaunch() {
        let recovery = BackgroundUploadCreationRecovery(preferences: nil)
        XCTAssertFalse(recovery.requestRetry(after: NSError(domain: "PHPhotosErrorDomain", code: -1)))
    }
}

final class LivePhotoResourceSelectionTests: XCTestCase {
    private typealias Candidate = (type: PHAssetResourceType, uniformTypeIdentifier: String)

    private func selectedTypes(_ resources: [Candidate]) -> [String] {
        PhotoLibraryManager.uploadableResourceIndices(resources).map {
            UploadResourceKind.name(
                for: resources[$0].type,
                uniformTypeIdentifier: resources[$0].uniformTypeIdentifier
            )
        }
    }

    func testPairedVideoGetsItsOwnResourceTypeAndNeverReadsAsVideoSeparator() {
        XCTAssertEqual(
            UploadResourceKind.name(for: .pairedVideo, uniformTypeIdentifier: "com.apple.quicktime-movie"),
            "live_video"
        )
        XCTAssertEqual(
            UploadResourceKind.name(for: .fullSizePairedVideo, uniformTypeIdentifier: "com.apple.quicktime-movie"),
            "live_video"
        )
        XCTAssertEqual(
            UploadResourceKind.name(for: .video, uniformTypeIdentifier: "com.apple.quicktime-movie"),
            "video"
        )
        XCTAssertFalse("asset/L0/001-\(LivePhotoResourcePolicy.resourceType)-IMG_0001.MOV".contains("-video-"))
    }

    func testLivePhotoUploadsStillAndPairedVideo() {
        let resources: [Candidate] = [
            (.photo, "public.heic"),
            (.pairedVideo, "com.apple.quicktime-movie"),
        ]
        XCTAssertEqual(PhotoLibraryManager.uploadableResourceIndices(resources), [0, 1])
        XCTAssertEqual(selectedTypes(resources), ["heic", "live_video"])
    }

    func testEditedLivePhotoPrefersFullSizeStillAndFullSizePairedVideo() {
        let resources: [Candidate] = [
            (.photo, "public.heic"),
            (.pairedVideo, "com.apple.quicktime-movie"),
            (.fullSizePhoto, "public.heic"),
            (.fullSizePairedVideo, "com.apple.quicktime-movie"),
            (.adjustmentData, "com.apple.adjustment-data"),
            (.adjustmentBasePairedVideo, "com.apple.quicktime-movie"),
        ]
        XCTAssertEqual(PhotoLibraryManager.uploadableResourceIndices(resources), [2, 3])

        // PhotoKit's resource order is not documented; selection must not depend on it.
        let reordered: [Candidate] = [
            (.fullSizePairedVideo, "com.apple.quicktime-movie"),
            (.fullSizePhoto, "public.heic"),
            (.pairedVideo, "com.apple.quicktime-movie"),
            (.photo, "public.heic"),
        ]
        XCTAssertEqual(PhotoLibraryManager.uploadableResourceIndices(reordered), [1, 0])
    }

    func testPlainVideoIsUnchanged() {
        let resources: [Candidate] = [(.video, "com.apple.quicktime-movie")]
        XCTAssertEqual(PhotoLibraryManager.uploadableResourceIndices(resources), [0])
        XCTAssertEqual(selectedTypes(resources), ["video"])

        let edited: [Candidate] = [
            (.video, "com.apple.quicktime-movie"),
            (.fullSizeVideo, "com.apple.quicktime-movie"),
        ]
        XCTAssertEqual(PhotoLibraryManager.uploadableResourceIndices(edited), [1])
    }

    func testRawPlusJPEGIsUnchanged() {
        let resources: [Candidate] = [
            (.photo, "public.jpeg"),
            (.alternatePhoto, "com.adobe.raw-image"),
        ]
        XCTAssertEqual(PhotoLibraryManager.uploadableResourceIndices(resources), [0, 1])
        XCTAssertEqual(selectedTypes(resources), ["jpeg", "raw"])
    }

    func testRawPlusJPEGLivePhotoKeepsAllThreeCopies() {
        // Not produced by the iPhone camera (Live Photos are off for RAW capture), but
        // an imported asset could carry all three resources.
        let resources: [Candidate] = [
            (.photo, "public.jpeg"),
            (.alternatePhoto, "com.adobe.raw-image"),
            (.pairedVideo, "com.apple.quicktime-movie"),
        ]
        XCTAssertEqual(PhotoLibraryManager.uploadableResourceIndices(resources), [0, 1, 2])
        XCTAssertEqual(selectedTypes(resources), ["jpeg", "raw", "live_video"])
    }

    func testPreferredPairedVideoIndexPrefersFullSize() {
        XCTAssertEqual(LivePhotoResourcePolicy.preferredPairedVideoIndex(in: [.photo, .pairedVideo]), 1)
        XCTAssertEqual(
            LivePhotoResourcePolicy.preferredPairedVideoIndex(
                in: [.photo, .pairedVideo, .fullSizePhoto, .fullSizePairedVideo]
            ),
            3
        )
        XCTAssertNil(LivePhotoResourcePolicy.preferredPairedVideoIndex(in: [.photo, .video]))
    }

    func testBackgroundUploadSkipsOnlyTheSupersededPairedVideo() {
        XCTAssertEqual(
            LivePhotoResourcePolicy.supersededPairedVideoIndices(
                in: [.photo, .pairedVideo, .fullSizePhoto, .fullSizePairedVideo]
            ),
            [1]
        )
        XCTAssertEqual(LivePhotoResourcePolicy.supersededPairedVideoIndices(in: [.photo, .pairedVideo]), [])
    }

    func testMultipartPreambleCarriesLivePhotoVideoIdOnlyWhenLinking() {
        func preamble(_ livePhotoVideoId: String?) -> String {
            let formatter = ISO8601DateFormatter()
            let data = ImmichAPIService.buildMultipartPreamble(
                boundary: "B", filename: "IMG_0001.HEIC", mimeType: "image/heic",
                deviceAssetId: "asset-heic-IMG_0001.HEIC", createdAt: Date(timeIntervalSince1970: 0),
                modifiedAt: Date(timeIntervalSince1970: 0), isFavorite: false,
                dateFormatter: formatter, iCloudId: nil, latitude: nil, longitude: nil,
                sourceChecksum: nil, livePhotoVideoId: livePhotoVideoId
            )
            return String(decoding: data, as: UTF8.self)
        }
        let videoId = "11111111-1111-4111-8111-111111111111"
        XCTAssertTrue(preamble(videoId).contains(
            "Content-Disposition: form-data; name=\"livePhotoVideoId\"\r\n\r\n\(videoId)\r\n"
        ))
        XCTAssertFalse(preamble(nil).contains("livePhotoVideoId"))
    }

    func testUploadResponseReadsImmichV2DuplicateStatus() throws {
        let duplicate = try JSONDecoder().decode(
            UploadResponse.self, from: Data(#"{"id":"a","status":"duplicate"}"#.utf8)
        )
        XCTAssertTrue(duplicate.isDuplicate)
        let created = try JSONDecoder().decode(
            UploadResponse.self, from: Data(#"{"id":"a","status":"created"}"#.utf8)
        )
        XCTAssertFalse(created.isDuplicate)
        let legacy = try JSONDecoder().decode(
            UploadResponse.self, from: Data(#"{"id":"a","duplicate":true}"#.utf8)
        )
        XCTAssertTrue(legacy.isDuplicate)
    }
}
