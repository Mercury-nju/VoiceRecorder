import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let paths: AppPaths
    let database: DatabaseManager
    let transcription: TranscriptionService
    let recording: RecordingManager
    let playback: PlaybackService
    let waveforms: WaveformService
    let exporter: ExportService
    let settings: SettingsManager

    @Published var selectedDate = DateTools.startOfDay(Date())
    @Published private(set) var availableDays: [Date] = []
    @Published private(set) var segments: [RecordingSegment] = []
    @Published private(set) var transcriptItems: [TranscriptItem] = []
    @Published private(set) var conversations: [Conversation] = []
    @Published var searchText = "" {
        didSet { performSearch() }
    }
    @Published private(set) var searchResults: [TranscriptItem] = []
    @Published private(set) var focusedTranscriptID: Int64?
    @Published private(set) var favoriteTranscriptIDs: Set<Int64> = []
    @Published private(set) var recentSearches: [String] = []
    @Published private(set) var selectedTimelineDate = DateTools.startOfDay(Date())
    @Published private(set) var selectedTimelineTime = Date()
    @Published var notice: String?
    private var playbackCancellables = Set<AnyCancellable>()

    init() {
        do {
            paths = try AppPaths()
            database = try DatabaseManager(url: paths.databaseURL)
        } catch {
            fatalError("无法初始化本地安全存储：\(error.localizedDescription)")
        }
        transcription = TranscriptionService(database: database)
        recording = RecordingManager(paths: paths, database: database, transcription: transcription)
        playback = PlaybackService()
        waveforms = WaveformService()
        exporter = ExportService(database: database)
        settings = SettingsManager()

        playback.$currentPlaybackDate
            .compactMap { $0 }
            .removeDuplicates(by: { DateTools.startOfDay($0) == DateTools.startOfDay($1) })
            .sink { [weak self] date in
                guard let self else { return }
                let day = DateTools.startOfDay(date)
                guard day != self.selectedDate else { return }
                self.selectedDate = day
                self.selectedTimelineDate = day
                self.selectedTimelineTime = date
                self.reloadCurrentDay()
            }
            .store(in: &playbackCancellables)

        Publishers.Merge3(recording.objectWillChange, transcription.objectWillChange, playback.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &playbackCancellables)
        waveforms.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &playbackCancellables)

        recording.onSegmentFinalized = { [weak self] _ in
            Task { @MainActor in self?.reloadCurrentDay() }
        }
        transcription.onSegmentTranscribed = { [weak self] _ in
            Task { @MainActor in self?.reloadCurrentDay() }
        }
        DispatchQueue.main.async { [weak self] in
            self?.reloadCurrentDay()
            self?.recording.prepareForLaunch()
        }
    }

    func select(day: Date) {
        selectedDate = DateTools.startOfDay(day)
        selectedTimelineDate = DateTools.startOfDay(day)
        searchText = ""
        reloadCurrentDay()
    }

    func reloadCurrentDay() {
        segments = database.segments(on: selectedDate)
        waveforms.load(segments)
        transcriptItems = database.transcriptItems(on: selectedDate)
        let allSegments = database.allSegments()
        let allTranscript = database.transcriptItems(between: .distantPast, and: .distantFuture)
        conversations = Conversation.group(segments: allSegments, transcriptItems: allTranscript)
        let today = DateTools.startOfDay(Date())
        let indexed = database.availableDays()
        availableDays = Array(Set(indexed + [today])).sorted(by: >)
        performSearch()
        favoriteTranscriptIDs = Set(database.favoriteTranscriptIDs())
        recentSearches = database.recentSearches()
    }

    func select(conversation: Conversation) {
        select(day: conversation.startTime)
    }

    func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchResults = query.isEmpty ? [] : database.searchTranscript(query)
    }

    func saveCurrentSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        try? database.recordSearch(query)
        recentSearches = database.recentSearches()
    }

    func toggleFavorite(_ item: TranscriptItem) {
        let enabled = !favoriteTranscriptIDs.contains(item.id)
        try? database.setFavorite(item.id, enabled: enabled)
        if enabled { favoriteTranscriptIDs.insert(item.id) }
        else { favoriteTranscriptIDs.remove(item.id) }
    }

    var selectedDayDuration: TimeInterval {
        let dayStart = DateTools.startOfDay(selectedDate)
        let dayEnd = DateTools.endOfDay(selectedDate)
        return segments.reduce(0) { total, segment in
            total + max(0, min(segment.endTime, dayEnd).timeIntervalSince(max(segment.startTime, dayStart)))
        }
    }

    var focusedSegment: RecordingSegment? {
        let anchor = playback.currentPlaybackDate ?? selectedTimelineTime
        if let containing = segments.first(where: { $0.startTime <= anchor && $0.endTime > anchor }) { return containing }
        guard let nearest = segments.min(by: { abs($0.startTime.timeIntervalSince(anchor)) < abs($1.startTime.timeIntervalSince(anchor)) }),
              abs(nearest.startTime.timeIntervalSince(anchor)) <= 15 * 60 else { return nil }
        return nearest
    }

    var focusedSegmentTranscript: String? {
        guard let segment = focusedSegment else { return nil }
        return transcriptItems.first(where: { $0.segmentID == segment.id })?.text
    }

    var currentTranscriptItem: TranscriptItem? {
        guard let date = playback.currentPlaybackDate else { return nil }
        return transcriptItems.first(where: { $0.startTime <= date && $0.endTime > date })
    }

    var favoriteTranscriptItems: [TranscriptItem] {
        database.favoriteTranscriptItems()
    }

    var filteredTranscriptItems: [TranscriptItem] { transcriptItems }

    func play(_ item: TranscriptItem) {
        selectedDate = DateTools.startOfDay(item.startTime)
        focusedTranscriptID = item.id
        searchText = ""
        reloadCurrentDay()
        play(at: item.startTime)
    }

    func play(at date: Date, reportMissingAudio: Bool = true) {
        selectedTimelineDate = DateTools.startOfDay(date)
        selectedTimelineTime = date
        let all = database.allSegments().sorted { $0.startTime < $1.startTime }
        guard let index = all.firstIndex(where: { $0.startTime <= date && $0.endTime > date }) ?? all.indices.min(by: {
            abs(all[$0].startTime.timeIntervalSince(date)) < abs(all[$1].startTime.timeIntervalSince(date))
        }), abs(all[index].startTime.timeIntervalSince(date)) < 300 else {
            playback.stop()
            if reportMissingAudio { notice = "该时间点没有可播放的本地音频。" }
            return
        }
        var contiguous = [all[index]]
        var previous = all[index]
        for candidate in all.dropFirst(index + 1) {
            guard candidate.startTime.timeIntervalSince(previous.endTime) < 12 else { break }
            contiguous.append(candidate)
            previous = candidate
        }
        playback.play(segments: contiguous, at: date)
    }

    func navigateTimeline(to date: Date) {
        selectedTimelineDate = DateTools.startOfDay(date)
        selectedTimelineTime = date
        if DateTools.startOfDay(date) != selectedDate { select(day: date) }
        if let item = database.transcriptItems(on: date).first(where: { $0.startTime <= date && $0.endTime >= date }) {
            focusedTranscriptID = item.id
        }
        play(at: date, reportMissingAudio: false)
    }

    func retryTranscription(for segment: RecordingSegment) {
        transcription.retry(segment)
    }

    func exportAudio(from start: Date, to end: Date, completion: @escaping (Result<URL, Error>) -> Void) {
        exporter.exportAudio(from: start, to: end, completion: completion)
    }

    func exportText(from start: Date, to end: Date, completion: @escaping (Result<URL, Error>) -> Void) {
        exporter.exportText(from: start, to: end, completion: completion)
    }

    func openStorageFolder() {
        NSWorkspace.shared.open(paths.rootURL)
    }

    func clearAllLocalData() {
        recording.pauseByUser()
        do {
            let files = try database.deleteAllRecords()
            for file in files { try? FileManager.default.removeItem(at: file) }
            try? FileManager.default.removeItem(at: paths.audioURL)
            try? FileManager.default.createDirectory(at: paths.audioURL, withIntermediateDirectories: true)
            playback.stop()
            reloadCurrentDay()
            notice = "已从本机删除音频、转录和索引。"
        } catch {
            notice = "删除失败：\(error.localizedDescription)"
        }
    }

    var storageUsageText: String {
        ByteCountFormatter.string(fromByteCount: paths.storageUsageBytes(), countStyle: .file)
    }
}
