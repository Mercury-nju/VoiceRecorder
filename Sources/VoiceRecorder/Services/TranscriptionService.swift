import Combine
import Foundation
import Speech

@MainActor
final class TranscriptionService: ObservableObject {
    @Published private(set) var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
    @Published private(set) var queueCount = 0
    @Published private(set) var statusMessage = "等待转录"
    @Published var selectedLanguage = UserDefaults.standard.string(forKey: "transcription.language") ?? "zh-CN" {
        didSet { UserDefaults.standard.set(selectedLanguage, forKey: "transcription.language") }
    }

    var onSegmentTranscribed: ((RecordingSegment) -> Void)?

    private let database: DatabaseManager
    private var pending: [TranscriptionJob] = []
    private var activeTask: SFSpeechRecognitionTask?
    private var isProcessing = false
    private let maximumAutomaticRetries = 3

    init(database: DatabaseManager) {
        self.database = database
        pending = database.pendingTranscriptionJobs().filter { $0.attempts < maximumAutomaticRetries }
        queueCount = pending.count
        if !pending.isEmpty { statusMessage = "已恢复 \(pending.count) 个待转录任务" }
    }

    func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { [weak self] newStatus in
            Task { @MainActor in
                self?.authorizationStatus = newStatus
                self?.processNextIfPossible()
            }
        }
    }

    func enqueue(_ segment: RecordingSegment) {
        enqueueJob(id: segment.id, segmentID: segment.id, start: segment.startTime, end: segment.endTime, fileURL: segment.fileURL)
    }

    func enqueueChunk(id: String, parentSegmentID: String, startTime: Date, endTime: Date, fileURL: URL) {
        enqueueJob(id: id, segmentID: parentSegmentID, start: startTime, end: endTime, fileURL: fileURL)
    }

    private func enqueueJob(id: String, segmentID: String, start: Date, end: Date, fileURL: URL) {
        do {
            try database.enqueueTranscriptionJob(id: id, parentSegmentID: segmentID, start: start, end: end, fileURL: fileURL)
            guard !pending.contains(where: { $0.id == id }) else { return }
            pending.append(TranscriptionJob(id: id, segmentID: segmentID, startTime: start, endTime: end, fileURL: fileURL, attempts: 0))
            queueCount = pending.count
            processNextIfPossible()
        } catch {
            statusMessage = "无法保存转录任务：\(error.localizedDescription)"
        }
    }

    func retry(_ segment: RecordingSegment) {
        let jobs = database.pendingTranscriptionJobs().filter { $0.segmentID == segment.id }
        if !jobs.isEmpty {
            for job in jobs where !pending.contains(where: { $0.id == job.id }) { pending.append(job) }
        } else {
            enqueue(segment)
        }
        queueCount = pending.count
        processNextIfPossible()
    }

    private func processNextIfPossible() {
        guard !isProcessing, !pending.isEmpty else { return }
        guard authorizationStatus == .authorized else {
            statusMessage = "未授予语音识别权限，录音已保留"
            return
        }
        let job = pending.removeFirst()
        queueCount = pending.count
        isProcessing = true
        statusMessage = "正在转录"
        try? database.updateTranscriptionJob(id: job.id, state: .processing)
        transcribe(job)
    }

    private func transcribe(_ job: TranscriptionJob) {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: selectedLanguage))
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            finish(job, items: nil, state: .unavailable, message: "此 Mac 未提供所选语言的设备端识别")
            return
        }
        let request = SFSpeechURLRecognitionRequest(url: job.fileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        activeTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result, result.isFinal {
                let items = result.bestTranscription.segments.map { part in
                    let start = job.startTime.addingTimeInterval(part.timestamp)
                    return (start: start, end: start.addingTimeInterval(max(part.duration, 0.1)), text: part.substring)
                }
                Task { @MainActor in self.finish(job, items: items, state: .complete, message: "转录完成") }
            } else if let error {
                Task { @MainActor in self.finish(job, items: nil, state: .failed, message: "转录失败：\(error.localizedDescription)") }
            }
        }
    }

    private func finish(_ job: TranscriptionJob, items: [(start: Date, end: Date, text: String)]?, state: TranscriptionState, message: String) {
        activeTask = nil
        isProcessing = false
        statusMessage = message
        do {
            if let items, state == .complete {
                try database.appendTranscript(for: job, items: items)
            } else {
                try database.updateTranscriptionJob(id: job.id, state: state)
            }
        } catch {
            statusMessage = "无法写入转录索引：\(error.localizedDescription)"
        }
        if state == .failed, job.attempts + 1 < maximumAutomaticRetries {
            let retryJob = TranscriptionJob(id: job.id, segmentID: job.segmentID, startTime: job.startTime, endTime: job.endTime, fileURL: job.fileURL, attempts: job.attempts + 1)
            pending.append(retryJob)
            queueCount = pending.count
        }
        onSegmentTranscribed?(job.segment)
        processNextIfPossible()
    }
}
