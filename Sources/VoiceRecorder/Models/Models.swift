import Foundation

struct RecordingSegment: Identifiable, Hashable, Sendable {
    let id: String
    let startTime: Date
    let endTime: Date
    let fileURL: URL
    let transcriptionState: String

    var duration: TimeInterval { max(0, endTime.timeIntervalSince(startTime)) }
    var isTranscribed: Bool { transcriptionState == "complete" }
}

struct TranscriptItem: Identifiable, Hashable, Sendable {
    let id: Int64
    let segmentID: String
    let startTime: Date
    let endTime: Date
    let text: String

    var duration: TimeInterval { max(0, endTime.timeIntervalSince(startTime)) }
}

struct Conversation: Identifiable, Hashable, Sendable {
    let segments: [RecordingSegment]
    let transcriptItems: [TranscriptItem]

    var id: String { segments.first?.id ?? "conversation-\(startTime.timeIntervalSince1970)" }
    var startTime: Date { segments.first?.startTime ?? transcriptItems.first?.startTime ?? .distantPast }
    var endTime: Date { segments.last?.endTime ?? transcriptItems.last?.endTime ?? startTime }
    var duration: TimeInterval { max(0, endTime.timeIntervalSince(startTime)) }
    var dates: Set<Date> { Set(segments.map { DateTools.startOfDay($0.startTime) } + segments.map { DateTools.startOfDay($0.endTime.addingTimeInterval(-0.001)) }) }

    static func group(segments: [RecordingSegment], transcriptItems: [TranscriptItem], maximumGap: TimeInterval = 12) -> [Conversation] {
        let ordered = segments.sorted { $0.startTime < $1.startTime }
        guard !ordered.isEmpty else { return [] }
        var groups: [[RecordingSegment]] = [[ordered[0]]]
        for segment in ordered.dropFirst() {
            if let previous = groups[groups.count - 1].last,
               segment.startTime.timeIntervalSince(previous.endTime) <= maximumGap {
                groups[groups.count - 1].append(segment)
            } else {
                groups.append([segment])
            }
        }
        return groups.map { group in
            let start = group[0].startTime
            let end = group[group.count - 1].endTime
            let ids = Set(group.map(\.id))
            return Conversation(segments: group, transcriptItems: transcriptItems.filter { ids.contains($0.segmentID) && $0.startTime < end && $0.endTime > start })
        }
    }
}

enum RecordingState: Equatable {
    case initializing
    case ready
    case recording
    case pausedByUser
    case sleeping
    case recovering
    case error(String)

    var title: String {
        switch self {
        case .initializing: return "等待麦克风授权"
        case .ready: return "等待开始"
        case .recording: return "正在录音"
        case .pausedByUser: return "已暂停"
        case .sleeping: return "系统睡眠"
        case .recovering: return "正在恢复"
        case .error(let message): return "需要处理：\(message)"
        }
    }

    var symbolName: String {
        switch self {
        case .recording: return "record.circle.fill"
        case .ready: return "mic.fill"
        case .pausedByUser: return "pause.circle.fill"
        case .sleeping: return "moon.zzz.fill"
        case .recovering: return "arrow.triangle.2.circlepath.circle.fill"
        case .initializing: return "mic"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

enum TranscriptionState: String {
    case queued
    case processing
    case complete
    case failed
    case unavailable
}

struct TranscriptionJob: Sendable {
    let id: String
    let segmentID: String
    let startTime: Date
    let endTime: Date
    let fileURL: URL
    let attempts: Int

    var segment: RecordingSegment {
        RecordingSegment(id: segmentID, startTime: startTime, endTime: endTime, fileURL: fileURL, transcriptionState: TranscriptionState.queued.rawValue)
    }
}

enum DateTools {
    static let calendar = Calendar.autoupdatingCurrent

    static func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    static func endOfDay(_ date: Date) -> Date {
        calendar.date(byAdding: .day, value: 1, to: startOfDay(date)) ?? date
    }

    static func storageDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    static func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter.string(from: date)
    }
}
