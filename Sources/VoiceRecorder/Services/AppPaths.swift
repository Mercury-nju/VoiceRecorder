import Foundation

struct AppPaths: Sendable {
    let rootURL: URL
    let audioURL: URL
    let databaseURL: URL
    let modelsURL: URL
    let logsURL: URL

    init(fileManager: FileManager = .default) throws {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        rootURL = applicationSupport.appendingPathComponent("VoiceRecorder", isDirectory: true)
        audioURL = rootURL.appendingPathComponent("Audio", isDirectory: true)
        databaseURL = rootURL.appendingPathComponent("Database/recordings.sqlite")
        modelsURL = rootURL.appendingPathComponent("Models", isDirectory: true)
        logsURL = rootURL.appendingPathComponent("Logs", isDirectory: true)

        try fileManager.createDirectory(at: audioURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: modelsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logsURL, withIntermediateDirectories: true)
    }

    func audioDirectory(for date: Date, fileManager: FileManager = .default) throws -> URL {
        let directory = audioURL.appendingPathComponent(DateTools.storageDate(date), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func storageUsageBytes(fileManager: FileManager = .default) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    func availableImportantCapacity(fileManager: FileManager = .default) -> Int64? {
        let values = try? rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
