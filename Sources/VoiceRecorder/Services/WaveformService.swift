@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
final class WaveformService: ObservableObject {
    @Published private(set) var samples: [String: [CGFloat]] = [:]
    private var loading = Set<String>()

    func load(_ segments: [RecordingSegment]) {
        let pending = segments.filter { samples[$0.id] == nil && loading.insert($0.id).inserted }
        guard !pending.isEmpty else { return }
        Task { @MainActor [weak self] in
            for segment in pending {
                let values = await Task.detached(priority: .utility) {
                    Self.readEnvelope(url: segment.fileURL, bucketCount: 36)
                }.value
                guard let self else { return }
                self.loading.remove(segment.id)
                if !values.isEmpty { self.samples[segment.id] = values }
            }
        }
    }

    nonisolated private static func readEnvelope(url: URL, bucketCount: Int) -> [CGFloat] {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384),
              let channelData = buffer.floatChannelData else { return [] }

        let frameCount = Int(file.length)
        let channelCount = Int(file.processingFormat.channelCount)
        let framesPerBucket = max(1, frameCount / bucketCount)
        var peaks = Array(repeating: Float.zero, count: bucketCount)
        var consumed = 0

        while consumed < frameCount {
            do {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(16_384, frameCount - consumed)))
            } catch {
                return []
            }
            let count = Int(buffer.frameLength)
            guard count > 0 else { break }
            for frame in 0..<count {
                let bucket = min(bucketCount - 1, (consumed + frame) / framesPerBucket)
                for channel in 0..<channelCount {
                    peaks[bucket] = max(peaks[bucket], abs(channelData[channel][frame]))
                }
            }
            consumed += count
        }

        let maximum = peaks.max() ?? 0
        guard maximum > 0 else { return peaks.map { _ in 0.04 } }
        return peaks.map { CGFloat(sqrt($0 / maximum)) }
    }
}
