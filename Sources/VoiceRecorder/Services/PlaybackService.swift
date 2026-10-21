@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
final class PlaybackService: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var totalDuration: Double = 0
    @Published private(set) var currentTitle = "未选择录音"
    @Published private(set) var playbackAnchor: Date?
    @Published private(set) var currentPlaybackDate: Date?
    @Published var rate: Float = 1.0 {
        didSet { player.rate = isPlaying ? rate : 0 }
    }
    @Published var volume: Float = 0.72 {
        didSet { player.volume = volume }
    }

    private let player = AVQueuePlayer()
    private var timeObserver: Any?
    private var timelineItems: [(item: AVPlayerItem, segment: RecordingSegment, start: Double, end: Double)] = []
    private var initialOffset: TimeInterval = 0

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let entry = self.timelineItems.first(where: { $0.item === self.player.currentItem }) else { return }
                let position = min(self.totalDuration, max(0, entry.start + time.seconds))
                self.currentTime = position
                self.currentPlaybackDate = entry.segment.startTime.addingTimeInterval(time.seconds)
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queueDidFinish),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        NotificationCenter.default.removeObserver(self)
    }

    func play(segments: [RecordingSegment], at absoluteTime: Date) {
        let existing = segments.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        guard let firstIndex = existing.firstIndex(where: { $0.startTime <= absoluteTime && $0.endTime > absoluteTime }) ?? existing.indices.first else {
            return
        }
        let ordered = Array(existing[firstIndex...])
        guard let first = ordered.first else { return }
        resetQueue()
        initialOffset = max(0, absoluteTime.timeIntervalSince(first.startTime))
        var cursor = 0.0
        timelineItems = ordered.map { segment in
            let item = AVPlayerItem(url: segment.fileURL)
            let duration = segment.duration
            defer { cursor += duration }
            return (item, segment, cursor, cursor + duration)
        }
        totalDuration = timelineItems.last?.end ?? 0
        playbackAnchor = absoluteTime
        currentPlaybackDate = absoluteTime
        currentTitle = "\(DateTools.time(absoluteTime)) 开始"

        for entry in timelineItems {
            player.insert(entry.item, after: nil)
        }
        player.playImmediately(atRate: rate)
        seek(to: initialOffset)
        isPlaying = true
    }

    func toggle() {
        if isPlaying { pause() } else { resume() }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func resume() {
        guard player.currentItem != nil else { return }
        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    func seek(to seconds: Double) {
        guard player.currentItem != nil else { return }
        let target = min(totalDuration, max(0, seconds))
        guard let index = timelineItems.firstIndex(where: { target < $0.end }) ?? timelineItems.indices.last else { return }
        let entry = timelineItems[index]
        let localTime = max(0, target - entry.start)
        if player.currentItem !== entry.item {
            player.pause()
            player.removeAllItems()
            for queued in timelineItems[index...] { player.insert(queued.item, after: nil) }
        }
        player.seek(to: CMTime(seconds: localTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
        currentPlaybackDate = entry.segment.startTime.addingTimeInterval(localTime)
    }

    func stop() {
        resetQueue()
        currentTitle = "未选择录音"
    }

    func setVolume(_ value: Float) {
        volume = min(1, max(0, value))
    }

    private func resetQueue() {
        player.pause()
        player.removeAllItems()
        timelineItems = []
        initialOffset = 0
        currentTime = 0
        totalDuration = 0
        playbackAnchor = nil
        currentPlaybackDate = nil
        isPlaying = false
    }

    @objc private func queueDidFinish(_ notification: Notification) {
        if player.items().isEmpty || player.currentItem == nil {
            isPlaying = false
        }
    }
}
