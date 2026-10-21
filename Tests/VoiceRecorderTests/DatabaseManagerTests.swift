import Foundation
import XCTest
@testable import VoiceRecorder

final class DatabaseManagerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceRecorderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testSegmentTranscriptAndSearchRoundTrip() throws {
        let database = try DatabaseManager(url: temporaryDirectory.appendingPathComponent("recordings.sqlite"))
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let segment = RecordingSegment(
            id: "segment-1",
            startTime: start,
            endTime: start.addingTimeInterval(300),
            fileURL: temporaryDirectory.appendingPathComponent("segment.m4a"),
            transcriptionState: TranscriptionState.queued.rawValue
        )

        try database.insert(segment: segment)
        try database.replaceTranscript(for: segment, items: [
            (start: start.addingTimeInterval(10), end: start.addingTimeInterval(13), text: "今天讨论产品方案"),
            (start: start.addingTimeInterval(20), end: start.addingTimeInterval(23), text: "The local recorder keeps data private")
        ])

        XCTAssertEqual(database.segments(on: start).count, 1)
        XCTAssertEqual(database.transcriptItems(on: start).count, 2)
        XCTAssertEqual(database.searchTranscript("产品方案").first?.text, "今天讨论产品方案")
        XCTAssertEqual(database.searchTranscript("private").first?.text, "The local recorder keeps data private")
    }

    func testSegmentOverlapAcrossMidnight() throws {
        let database = try DatabaseManager(url: temporaryDirectory.appendingPathComponent("cross-day.sqlite"))
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 23, minute: 58))!
        let segment = RecordingSegment(
            id: "cross-day",
            startTime: start,
            endTime: start.addingTimeInterval(5 * 60),
            fileURL: temporaryDirectory.appendingPathComponent("cross.m4a"),
            transcriptionState: TranscriptionState.queued.rawValue
        )
        try database.insert(segment: segment)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: start)!
        XCTAssertEqual(database.segments(on: start).count, 1)
        XCTAssertEqual(database.segments(on: nextDay).count, 1)
    }

    func testConversationGroupsContinuousSegmentsAcrossMidnight() throws {
        let database = try DatabaseManager(url: temporaryDirectory.appendingPathComponent("conversation.sqlite"))
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 23, minute: 58))!
        let first = RecordingSegment(id: "first", startTime: start, endTime: start.addingTimeInterval(300), fileURL: temporaryDirectory.appendingPathComponent("first.m4a"), transcriptionState: "complete")
        let secondStart = first.endTime.addingTimeInterval(2)
        let second = RecordingSegment(id: "second", startTime: secondStart, endTime: secondStart.addingTimeInterval(300), fileURL: temporaryDirectory.appendingPathComponent("second.m4a"), transcriptionState: "complete")
        try database.insert(segment: first)
        try database.insert(segment: second)
        try database.replaceTranscript(for: first, items: [(start: start.addingTimeInterval(5), end: start.addingTimeInterval(8), text: "before midnight")])
        try database.replaceTranscript(for: second, items: [(start: secondStart.addingTimeInterval(5), end: secondStart.addingTimeInterval(8), text: "after midnight")])

        let conversations = Conversation.group(
            segments: database.allSegments(),
            transcriptItems: database.transcriptItems(between: .distantPast, and: .distantFuture)
        )
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations[0].segments.count, 2)
        XCTAssertEqual(conversations[0].transcriptItems.map(\.text), ["before midnight", "after midnight"])
        XCTAssertEqual(conversations[0].dates.count, 2)
    }

    func testRollingTranscriptionJobPersistsTranscriptBeforeParentFinalizes() throws {
        let databaseURL = temporaryDirectory.appendingPathComponent("rolling.sqlite")
        let database = try DatabaseManager(url: databaseURL)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let audioURL = temporaryDirectory.appendingPathComponent("rolling.m4a")
        try database.enqueueTranscriptionJob(id: "chunk-1", parentSegmentID: "parent-1", start: start, end: start.addingTimeInterval(12), fileURL: audioURL)

        let job = try XCTUnwrap(database.pendingTranscriptionJobs().first)
        XCTAssertEqual(job.id, "chunk-1")
        XCTAssertEqual(job.segmentID, "parent-1")
        try database.updateTranscriptionJob(id: job.id, state: .processing)
        try database.appendTranscript(for: job, items: [(start: start.addingTimeInterval(2), end: start.addingTimeInterval(3), text: "rolling text")])

        XCTAssertEqual(database.searchTranscript("rolling text").first?.segmentID, "parent-1")
        XCTAssertTrue(database.pendingTranscriptionJobs().isEmpty)

        let finalSegment = RecordingSegment(id: "parent-1", startTime: start, endTime: start.addingTimeInterval(300), fileURL: temporaryDirectory.appendingPathComponent("parent.m4a"), transcriptionState: TranscriptionState.queued.rawValue)
        try database.insert(segment: finalSegment)
        XCTAssertEqual(database.segments(on: start).first?.duration, 300)
        XCTAssertEqual(database.transcriptItems(on: start).count, 1)
    }

    func testFavoritesAndRecentSearchesPersist() throws {
        let databaseURL = temporaryDirectory.appendingPathComponent("user-actions.sqlite")
        let database = try DatabaseManager(url: databaseURL)
        let start = Date(timeIntervalSince1970: 1_800_100_000)
        let segment = RecordingSegment(id: "saved", startTime: start, endTime: start.addingTimeInterval(60), fileURL: temporaryDirectory.appendingPathComponent("saved.m4a"), transcriptionState: "complete")
        try database.insert(segment: segment)
        try database.replaceTranscript(for: segment, items: [(start: start, end: start.addingTimeInterval(2), text: "favorite this sentence")])
        let item = try XCTUnwrap(database.transcriptItems(on: start).first)
        try database.setFavorite(item.id, enabled: true)
        try database.recordSearch("favorite")

        XCTAssertEqual(database.favoriteTranscriptItems().map(\.id), [item.id])
        XCTAssertEqual(database.recentSearches().first, "favorite")
    }
}
