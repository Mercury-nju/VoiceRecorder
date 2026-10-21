import AppKit
@preconcurrency import AVFoundation
import Combine

@MainActor
final class RecordingManager: NSObject, ObservableObject, @preconcurrency AVAudioRecorderDelegate {
    @Published private(set) var state: RecordingState = .initializing
    @Published private(set) var microphoneGranted = false
    @Published private(set) var lastError: String?
    @Published private(set) var elapsedRecordingTime: TimeInterval = 0
    @Published private(set) var liveMeterLevels: [CGFloat] = []

    var onSegmentFinalized: ((RecordingSegment) -> Void)?

    private let paths: AppPaths
    private let database: DatabaseManager
    private let transcription: TranscriptionService
    private var recorder: AVAudioRecorder?
    private var segmentTimer: Timer?
    private var transcriptionTimer: Timer?
    private var healthTimer: Timer?
    private var elapsedTimer: Timer?
    private var currentStart: Date?
    private var currentPartialURL: URL?
    private var resumeAfterFinish = false
    private var pendingStateAfterFinish: RecordingState?
    private var currentSegmentID: String?
    private var generation = 0
    private var lastObservedFileSize: Int = 0
    private var stalledChecks = 0
    private var retryCount = 0
    private var snapshotInFlight = false
    private var lastSnapshotEnd: TimeInterval = 0
    private var accumulatedRecordingTime: TimeInterval = 0
    private var retryWorkItem: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var deviceConnectObserver: NSObjectProtocol?
    private var deviceDisconnectObserver: NSObjectProtocol?
    private let segmentLength: TimeInterval = 5 * 60
    private let transcriptionInterval: TimeInterval = 12
    private let minimumFreeBytes: Int64 = 100 * 1024 * 1024
    private let userPausedKey = "recording.userPaused"

    private var userPaused: Bool {
        get { UserDefaults.standard.object(forKey: userPausedKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: userPausedKey) }
    }

    init(paths: AppPaths, database: DatabaseManager, transcription: TranscriptionService) {
        self.paths = paths
        self.database = database
        self.transcription = transcription
        super.init()
    }

    func prepareForLaunch() {
        installLifecycleObservers()
        recoverCompletedPartials()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneGranted = true
            userPaused = true
            state = .ready
        case .notDetermined:
            microphoneGranted = false
            state = .initializing
        case .denied, .restricted:
            microphoneGranted = false
            state = .error("麦克风权限未授予")
            lastError = "请在系统设置 > 隐私与安全性 > 麦克风中允许“声音记录仪”。"
        @unknown default:
            microphoneGranted = false
            state = .error("无法确认麦克风权限")
        }
    }

    func requestPermissions(startRecording: Bool = false) {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.microphoneGranted = granted
                guard granted else {
                    self.state = .error("未授予麦克风权限")
                    self.lastError = "请在系统设置 > 隐私与安全性 > 麦克风中允许“声音记录仪”。"
                    return
                }
                self.transcription.requestAuthorization()
                self.userPaused = !startRecording
                self.state = .ready
                self.lastError = nil
                if startRecording {
                    self.startRecordingIfPossible(reason: "首次授权")
                }
            }
        }
    }

    func requestPermissionsAndStart() {
        requestPermissions(startRecording: true)
    }

    func toggleRecording() {
        if state.isRecording || state == .recovering {
            pauseByUser()
        } else {
            resumeByUser()
        }
    }

    func pauseByUser() {
        userPaused = true
        resumeAfterFinish = false
        pendingStateAfterFinish = .pausedByUser
        stopCurrentSegment()
        if recorder == nil { state = .pausedByUser }
    }

    func resumeByUser() {
        guard microphoneGranted else {
            requestPermissions()
            return
        }
        userPaused = false
        startRecordingIfPossible(reason: "用户恢复")
    }

    func retryAfterError() {
        guard !userPaused else { return }
        startRecordingIfPossible(reason: "手动恢复")
    }

    private func startRecordingIfPossible(reason: String) {
        guard recorder == nil else { return }
        guard !userPaused else {
            state = .pausedByUser
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            microphoneGranted = false
            let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
            state = .error(authorization == .notDetermined ? "需要麦克风权限" : "麦克风权限已拒绝")
            return
        }
        microphoneGranted = true
        if let available = paths.availableImportantCapacity(), available < minimumFreeBytes {
            state = .error("可用空间不足 100 MB")
            lastError = "为保护已有数据，录音已停止。释放磁盘空间后可重试。"
            return
        }

        do {
            let start = Date()
            let directory = try paths.audioDirectory(for: start)
            let id = UUID().uuidString
            let timeName = Self.filenameTime.string(from: start)
            let partialURL = directory.appendingPathComponent("\(timeName)_\(id).partial.m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            let newRecorder = try AVAudioRecorder(url: partialURL, settings: settings)
            newRecorder.delegate = self
            newRecorder.isMeteringEnabled = true
            guard newRecorder.prepareToRecord(), newRecorder.record() else {
                throw NSError(domain: "VoiceRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法开始音频采集"])
            }
            recorder = newRecorder
            currentStart = start
            currentPartialURL = partialURL
            currentSegmentID = id
            lastSnapshotEnd = 0
            generation &+= 1
            lastObservedFileSize = 0
            stalledChecks = 0
            state = .recording
            lastError = nil
            liveMeterLevels = []
            scheduleRotation()
            scheduleTranscriptionSnapshots()
            scheduleHealthChecks()
            elapsedTimer?.invalidate()
            elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let currentStart = self.currentStart else { return }
                    self.elapsedRecordingTime = self.accumulatedRecordingTime + Date().timeIntervalSince(currentStart)
                    self.recorder?.updateMeters()
                    let decibels = self.recorder?.averagePower(forChannel: 0) ?? -60
                    let level = CGFloat(max(0.04, min(1, (decibels + 60) / 60)))
                    self.liveMeterLevels.append(level)
                    if self.liveMeterLevels.count > 36 { self.liveMeterLevels.removeFirst(self.liveMeterLevels.count - 36) }
                }
            }
        } catch {
            state = .error("录音设备不可用")
            lastError = "\(reason)：\(error.localizedDescription)"
            scheduleAutomaticRetry(reason: reason)
        }
    }

    private func scheduleRotation() {
        segmentTimer?.invalidate()
        segmentTimer = Timer.scheduledTimer(withTimeInterval: segmentLength, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.rotateSegment() }
        }
    }

    private func scheduleTranscriptionSnapshots() {
        transcriptionTimer?.invalidate()
        transcriptionTimer = Timer.scheduledTimer(withTimeInterval: transcriptionInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.submitTranscriptionSnapshot() }
        }
    }

    private func submitTranscriptionSnapshot() {
        guard recorder != nil, let start = currentStart, let partialURL = currentPartialURL,
              let segmentID = currentSegmentID else { return }
        guard !snapshotInFlight else { return }
        let snapshot = paths.rootURL.appendingPathComponent("transcription-\(segmentID)-\(UUID().uuidString).m4a")
        do {
            try FileManager.default.copyItem(at: partialURL, to: snapshot)
            let elapsed = min(segmentLength, max(0, Date().timeIntervalSince(start)))
            guard elapsed - lastSnapshotEnd >= transcriptionInterval else {
                try? FileManager.default.removeItem(at: snapshot)
                return
            }
            let chunkStart = start.addingTimeInterval(lastSnapshotEnd)
            let chunkEnd = start.addingTimeInterval(elapsed)
            snapshotInFlight = true
            transcription.enqueueChunk(id: UUID().uuidString, parentSegmentID: segmentID, startTime: chunkStart, endTime: chunkEnd, fileURL: snapshot)
            lastSnapshotEnd = elapsed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.snapshotInFlight = false }
        } catch {
            // A file copy can briefly fail while AVAudioRecorder updates its container.
        }
    }

    private func scheduleHealthChecks() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkRecordingHealth() }
        }
    }

    private func checkRecordingHealth() {
        guard let recorder, let partialURL = currentPartialURL else { return }
        let size = (try? partialURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if recorder.isRecording && size > lastObservedFileSize {
            lastObservedFileSize = size
            stalledChecks = 0
            retryCount = 0
        } else {
            stalledChecks += 1
        }
        guard stalledChecks >= 3 else { return }
        generation &+= 1
        resumeAfterFinish = true
        pendingStateAfterFinish = .recovering
        stopCurrentSegment()
        scheduleAutomaticRetry(reason: "录音文件停止增长")
    }

    private func rotateSegment() {
        guard recorder != nil else { return }
        resumeAfterFinish = true
        pendingStateAfterFinish = .recovering
        stopCurrentSegment()
    }

    private func stopCurrentSegment() {
        segmentTimer?.invalidate()
        segmentTimer = nil
        transcriptionTimer?.invalidate()
        transcriptionTimer = nil
        healthTimer?.invalidate()
        healthTimer = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recorder?.stop()
        if recorder == nil, let finalState = pendingStateAfterFinish { state = finalState }
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let stoppedRecorder = recorder
        self.recorder = nil
        let start = currentStart
        let partialURL = currentPartialURL
        currentStart = nil
        currentPartialURL = nil
        snapshotInFlight = false
        let shouldResume = resumeAfterFinish
        resumeAfterFinish = false
        let finalState = pendingStateAfterFinish
        let segmentID = currentSegmentID
        pendingStateAfterFinish = nil
        currentSegmentID = nil

        if let start {
            accumulatedRecordingTime += max(0, Date().timeIntervalSince(start))
            elapsedRecordingTime = accumulatedRecordingTime
        }

        guard flag, let start, let partialURL else {
            state = .error("音频切片未完成")
            lastError = "录音设备结束时未能安全写入当前切片。"
            return
        }
        let callbackGeneration = generation
        finalize(partialURL: partialURL, id: segmentID ?? UUID().uuidString, start: start, end: Date(), recorder: stoppedRecorder)
        if shouldResume && !userPaused {
            state = .recovering
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.generation == callbackGeneration, !self.userPaused, self.recorder == nil else { return }
                self.startRecordingIfPossible(reason: "切片续录")
            }
        } else if let finalState {
            state = finalState
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        self.recorder = nil
        segmentTimer?.invalidate()
        segmentTimer = nil
        state = .error("音频编码异常")
        lastError = error?.localizedDescription ?? "系统无法完成音频编码。"
        scheduleAutomaticRetry(reason: "音频编码异常")
    }

    private func finalize(partialURL: URL, id: String, start: Date, end: Date, recorder: AVAudioRecorder) {
        let finalURL = partialURL.deletingPathExtension().deletingPathExtension().appendingPathExtension("m4a")
        do {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: partialURL, to: finalURL)
            let segment = RecordingSegment(
                id: id,
                startTime: start,
                endTime: end,
                fileURL: finalURL,
                transcriptionState: TranscriptionState.queued.rawValue
            )
            try database.insert(segment: segment)
            transcription.enqueue(segment)
            onSegmentFinalized?(segment)
        } catch {
            state = .error("保存录音失败")
            lastError = error.localizedDescription
        }
    }

    private func installLifecycleObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        sleepObserver = workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleSleep() }
        }
        wakeObserver = workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
        deviceDisconnectObserver = NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleDeviceUnavailable() }
        }
        deviceConnectObserver = NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleDeviceAvailable() }
        }
    }

    private func handleSleep() {
        guard !userPaused else { return }
        generation &+= 1
        retryWorkItem?.cancel()
        resumeAfterFinish = false
        pendingStateAfterFinish = .sleeping
        stopCurrentSegment()
        if recorder == nil { state = .sleeping }
    }

    private func handleWake() {
        guard !userPaused else { return }
        generation &+= 1
        retryWorkItem?.cancel()
        state = .recovering
        startRecordingIfPossible(reason: "系统唤醒")
    }

    private func handleDeviceUnavailable() {
        guard !userPaused else { return }
        generation &+= 1
        resumeAfterFinish = true
        pendingStateAfterFinish = .error("等待麦克风设备")
        stopCurrentSegment()
        scheduleAutomaticRetry(reason: "等待麦克风设备")
    }

    private func handleDeviceAvailable() {
        guard !userPaused else { return }
        generation &+= 1
        retryWorkItem?.cancel()
        if recorder != nil {
            resumeAfterFinish = true
            pendingStateAfterFinish = .recovering
            stopCurrentSegment()
            return
        }
        startRecordingIfPossible(reason: "麦克风设备恢复")
    }

    private func scheduleAutomaticRetry(reason: String) {
        guard !userPaused, retryCount < 5 else { return }
        retryCount += 1
        let expectedGeneration = generation
        let delay = min(60.0, pow(2.0, Double(retryCount)))
        retryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expectedGeneration, !self.userPaused, self.recorder == nil else { return }
            self.startRecordingIfPossible(reason: "\(reason)后自动重试")
        }
        retryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func recoverCompletedPartials() {
        guard let enumerator = FileManager.default.enumerator(at: paths.audioURL, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".partial.m4a") {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0 else { continue }
            // An interrupted container may not be playable. Preserve it for forensic recovery rather than indexing it as valid audio.
            let recovered = url.deletingPathExtension().deletingPathExtension().appendingPathExtension("interrupted.m4a")
            try? FileManager.default.moveItem(at: url, to: recovered)
        }
    }

    private static let filenameTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH-mm-ss"
        return formatter
    }()
}
