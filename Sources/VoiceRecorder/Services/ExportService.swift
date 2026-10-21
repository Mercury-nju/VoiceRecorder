import AppKit
@preconcurrency import AVFoundation
import Foundation

@MainActor
final class ExportService {
    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    func exportAudio(from start: Date, to end: Date, completion: @escaping (Result<URL, Error>) -> Void) {
        guard end > start else {
            completion(.failure(ExportError.invalidRange))
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出音频片段"
        panel.nameFieldStringValue = "声音记录 \(DateTools.storageDate(start)).m4a"
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let segments = database.segments(overlapping: start, and: end)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.composeAudio(segments: segments, start: start, end: end, destination: destination, completion: completion)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func exportText(from start: Date, to end: Date, completion: @escaping (Result<URL, Error>) -> Void) {
        guard end > start else {
            completion(.failure(ExportError.invalidRange))
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出转录文本"
        panel.nameFieldStringValue = "声音记录 \(DateTools.storageDate(start)).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let items = database.transcriptItems(between: start, and: end)
        let text = items.map { "[\(DateTools.time($0.startTime))] \($0.text)" }.joined(separator: "\n")
        DispatchQueue.global(qos: .utility).async {
            do {
                try text.write(to: destination, atomically: true, encoding: .utf8)
                DispatchQueue.main.async { completion(.success(destination)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private nonisolated func composeAudio(
        segments: [RecordingSegment],
        start: Date,
        end: Date,
        destination: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) throws {
        let validSegments = segments.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        guard !validSegments.isEmpty else { throw ExportError.noAudio }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.compositionFailed
        }
        var cursor = CMTime.zero
        for segment in validSegments {
            let asset = AVURLAsset(url: segment.fileURL)
            guard let track = asset.tracks(withMediaType: .audio).first else { continue }
            let segmentStart = max(0, start.timeIntervalSince(segment.startTime))
            let segmentEnd = min(segment.duration, end.timeIntervalSince(segment.startTime))
            let duration = max(0, segmentEnd - segmentStart)
            guard duration > 0 else { continue }
            let range = CMTimeRange(
                start: CMTime(seconds: segmentStart, preferredTimescale: 48_000),
                duration: CMTime(seconds: duration, preferredTimescale: 48_000)
            )
            try compositionTrack.insertTimeRange(range, of: track, at: cursor)
            cursor = cursor + range.duration
        }
        guard cursor > .zero else { throw ExportError.noAudio }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExportError.compositionFailed
        }
        exporter.outputURL = destination
        exporter.outputFileType = .m4a
        exporter.exportAsynchronously {
            let result: Result<URL, Error>
            switch exporter.status {
            case .completed:
                result = .success(destination)
            case .failed, .cancelled:
                result = .failure(exporter.error ?? ExportError.exportFailed)
            default:
                result = .failure(ExportError.exportFailed)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    enum ExportError: LocalizedError {
        case invalidRange
        case noAudio
        case compositionFailed
        case exportFailed

        var errorDescription: String? {
            switch self {
            case .invalidRange: return "结束时间必须晚于开始时间。"
            case .noAudio: return "所选时间范围没有可导出的音频。"
            case .compositionFailed: return "无法建立音频导出任务。"
            case .exportFailed: return "导出音频失败。"
            }
        }
    }
}
