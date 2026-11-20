import XCTest
@testable import YAIIU

final class UploadStatusSummaryTests: XCTestCase {
    func testCacheStatusesMapToStages() {
        let summary = UploadStatusSummary.make(
            libraryIdentifiers: ["up", "none", "hashing", "pending", "checking", "missing", "err"],
            statusCache: [
                "up": .uploaded,
                "hashing": .processing,
                "pending": .pending,
                "checking": .checking,
                "missing": .notUploaded,
                "err": .error,
            ],
            queue: [:]
        )

        XCTAssertEqual(summary.identifiers[.uploaded], ["up"])
        XCTAssertEqual(summary.identifiers[.waitingForHash], ["none", "hashing"])
        XCTAssertEqual(summary.identifiers[.checkingServer], ["pending", "checking"])
        XCTAssertEqual(summary.identifiers[.notUploaded], ["missing"])
        XCTAssertEqual(summary.identifiers[.hashError], ["err"])
        XCTAssertEqual(summary.total, 7)
    }

    func testQueueStatusWinsOverCacheStatus() {
        let summary = UploadStatusSummary.make(
            libraryIdentifiers: ["a", "b", "c", "d", "e", "f"],
            statusCache: ["a": .notUploaded, "b": .notUploaded, "c": .notUploaded,
                          "d": .uploaded, "e": .notUploaded, "f": .notUploaded],
            queue: ["a": .uploading, "b": .preparing, "c": .processing,
                    "d": .failed, "e": .pending, "f": .completed]
        )

        XCTAssertEqual(summary.identifiers[.uploading], ["a", "b", "c"])
        XCTAssertEqual(summary.identifiers[.failed], ["d"])
        XCTAssertEqual(summary.identifiers[.queued], ["e"])
        XCTAssertEqual(summary.identifiers[.uploaded], ["f"])
        XCTAssertEqual(summary.count(.notUploaded), 0)
        XCTAssertEqual(summary.total, 6)
    }

    func testQueuedPhotoMissingFromLibraryIsStillCounted() {
        let summary = UploadStatusSummary.make(
            libraryIdentifiers: ["a"],
            statusCache: ["a": .uploaded],
            queue: ["deleted": .failed]
        )

        XCTAssertEqual(summary.identifiers[.failed], ["deleted"])
        XCTAssertEqual(summary.count(.uploaded), 1)
        XCTAssertEqual(summary.total, 2)
    }

    func testEmptyInputsProduceEmptySummary() {
        let summary = UploadStatusSummary.make(libraryIdentifiers: [], statusCache: [:], queue: [:])

        XCTAssertEqual(summary.total, 0)
        for stage in UploadStage.allCases {
            XCTAssertEqual(summary.count(stage), 0)
        }
    }
}

final class RecentUploadsQueryTests: XCTestCase {
    private var databaseURL: URL!
    private var connection: SQLiteConnection!
    private var repository: UploadRecordRepository!

    override func setUp() {
        super.setUp()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("yaiiu-recent-\(UUID().uuidString).sqlite")
        connection = SQLiteConnection.testing(databasePath: databaseURL.path)
        connection.ensureInitialized()
        repository = UploadRecordRepository(connection: connection)
    }

    override func tearDown() {
        repository = nil
        connection = nil
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
        }
        databaseURL = nil
        super.tearDown()
    }

    private func record(_ id: String, _ type: String, _ filename: String, at time: TimeInterval, duplicate: Bool = false) {
        repository.recordUploadedAsset(
            localIdentifier: id, resourceType: type, filename: filename,
            immichId: "immich-\(id)-\(type)", isDuplicate: duplicate,
            uploadedAt: Date(timeIntervalSince1970: time)
        )
    }

    func testRecentUploadsAreGroupedPerAssetNewestFirst() {
        record("old", "heic", "OLD.HEIC", at: 100)
        record("new", "raw", "NEW.DNG", at: 300)
        record("new", "heic", "NEW.HEIC", at: 200)
        record("new", LivePhotoResourcePolicy.resourceType, "NEW.MOV", at: 250)

        let recent = repository.recentUploads(limit: 10)

        XCTAssertEqual(recent.map(\.localIdentifier), ["new", "old"])
        XCTAssertEqual(recent[0].filename, "NEW.HEIC")
        XCTAssertEqual(recent[0].resourceTypes, [LivePhotoResourcePolicy.resourceType, "heic", "raw"].sorted())
        XCTAssertEqual(recent[0].uploadedAt, Date(timeIntervalSince1970: 300))
        XCTAssertFalse(recent[0].isDuplicate)
    }

    func testRecentUploadsRespectLimitAndDuplicateFlag() {
        record("a", "heic", "A.JPG", at: 1, duplicate: true)
        record("b", "heic", "B.JPG", at: 2, duplicate: true)
        record("c", "heic", "C.JPG", at: 3)

        let recent = repository.recentUploads(limit: 2)

        XCTAssertEqual(recent.map(\.localIdentifier), ["c", "b"])
        XCTAssertFalse(recent[0].isDuplicate)
        XCTAssertTrue(recent[1].isDuplicate)
    }
}
