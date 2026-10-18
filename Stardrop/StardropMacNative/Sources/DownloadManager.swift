import Foundation
import SwiftUI
import Combine

/// Installs a completed archive before DownloadManager removes its temporary copy.
/// Implementations must check cancellation before committing filesystem changes.
typealias NativeArchiveInstallation = @Sendable (URL, @escaping @Sendable () throws -> Void) async throws -> Void

struct DownloadTask: Identifiable {
    let id = UUID()
    let fileName: String
    let modID: Int
    var fileID: Int? = nil
    var progress: Double = 0.0
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var speedBytesPerSecond: Double = 0
    var isCompleted: Bool = false
    var isCancelled: Bool = false
    var isExtracting: Bool = false
    var error: String?
    let startTime: Date = Date()
    var manualDownloadURL: URL? = nil

    // Internal tracking
    var urlSessionTaskID: Int?
    var smapiDir: String = ""
    var customModsDir: String = ""
    var collectionFolder: String? = nil
    var autoEnableInProfileID: UUID? = nil
    var archiveInstallation: NativeArchiveInstallation? = nil

    var etaSeconds: Double {
        guard speedBytesPerSecond > 0, totalBytes > 0 else { return 0 }
        let remaining = totalBytes - downloadedBytes
        return Double(remaining) / speedBytesPerSecond
    }
}

class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var activeDownloads: [DownloadTask] = []

    private var session: URLSession!
    private var networkTasks: [UUID: URLSessionDownloadTask] = [:]
    private var cancellationTokens: [UUID: DownloadCancellationToken] = [:]
    private var installationTasks: [UUID: Task<Void, Never>] = [:]
    weak var modManager: ModManager?

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }

    func hasPendingManualDownload(modID: Int, fileID: Int) -> Bool {
        activeDownloads.contains {
            $0.modID == modID && ($0.fileID == fileID || $0.fileID == nil)
                && $0.manualDownloadURL != nil && !$0.isCancelled
        }
    }

    func startOrResumeDownload(url: URL, fileName: String, modID: Int, fileID: Int? = nil, smapiDir: String, customModsDir: String, modManager: ModManager, collectionFolder: String? = nil, autoEnableInProfileID: UUID? = nil, archiveInstallation: NativeArchiveInstallation? = nil) {
        self.modManager = modManager
        let urlTask = session.downloadTask(with: url)

        // Find if there is an existing manual task matching this modID and fileID
        if let index = activeDownloads.firstIndex(where: { $0.modID == modID && ($0.fileID == fileID || $0.fileID == nil) && $0.manualDownloadURL != nil && !$0.isCancelled }) {
            activeDownloads[index].manualDownloadURL = nil
            activeDownloads[index].fileID = fileID
            activeDownloads[index].isCompleted = false
            activeDownloads[index].isCancelled = false
            activeDownloads[index].error = nil
            activeDownloads[index].urlSessionTaskID = urlTask.taskIdentifier
            activeDownloads[index].progress = 0.0
            activeDownloads[index].downloadedBytes = 0
            activeDownloads[index].totalBytes = 0
            activeDownloads[index].speedBytesPerSecond = 0

            // A manually queued file keeps its original destination, including an
            // ordinary install (nil action), regardless of the currently selected profile.
        } else {
            var task = DownloadTask(fileName: fileName, modID: modID, fileID: fileID)
            task.urlSessionTaskID = urlTask.taskIdentifier
            task.smapiDir = smapiDir
            task.customModsDir = customModsDir
            task.collectionFolder = collectionFolder
            task.autoEnableInProfileID = autoEnableInProfileID
            task.archiveInstallation = archiveInstallation

            activeDownloads.append(task)
        }

        if let task = activeDownloads.first(where: { $0.urlSessionTaskID == urlTask.taskIdentifier }) {
            networkTasks[task.id] = urlTask
            cancellationTokens[task.id] = DownloadCancellationToken()
        }
        urlTask.resume()
    }

    func clearCompleted() {
        let removed = activeDownloads.filter { $0.isCompleted || $0.error != nil || $0.isCancelled }
        for task in removed {
            networkTasks.removeValue(forKey: task.id)
            cancellationTokens.removeValue(forKey: task.id)
        }
        activeDownloads.removeAll { $0.isCompleted || $0.error != nil || $0.isCancelled }
    }

    func cancelDownload(id: UUID) {
        guard let index = activeDownloads.firstIndex(where: { $0.id == id }),
              !activeDownloads[index].isCompleted else { return }
        cancellationTokens[id]?.cancel()
        networkTasks[id]?.cancel()
        installationTasks[id]?.cancel()
        activeDownloads[index].isCancelled = true
        activeDownloads[index].isExtracting = false
        activeDownloads[index].error = "Download cancelled."
    }

    func addManualDownload(fileName: String, modID: Int, fileID: Int? = nil, manualURL: URL?, errorMsg: String?, smapiDir: String = "", customModsDir: String = "", collectionFolder: String? = nil, autoEnableInProfileID: UUID? = nil, archiveInstallation: NativeArchiveInstallation? = nil) {
        var task = DownloadTask(fileName: fileName, modID: modID, fileID: fileID)
        task.manualDownloadURL = manualURL
        task.error = errorMsg ?? "Premium membership required for automatic download."
        task.smapiDir = smapiDir
        task.customModsDir = customModsDir
        task.collectionFolder = collectionFolder
        task.autoEnableInProfileID = autoEnableInProfileID
        task.archiveInstallation = archiveInstallation
        activeDownloads.append(task)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let index = activeDownloads.firstIndex(where: { $0.urlSessionTaskID == downloadTask.taskIdentifier }) else { return }

        var task = activeDownloads[index]
        task.downloadedBytes = totalBytesWritten
        task.totalBytes = totalBytesExpectedToWrite
        if totalBytesExpectedToWrite > 0 {
            task.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        }

        let elapsedTime = Date().timeIntervalSince(task.startTime)
        if elapsedTime > 0 {
            task.speedBytesPerSecond = Double(totalBytesWritten) / elapsedTime
        }

        activeDownloads[index] = task
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let index = activeDownloads.firstIndex(where: { $0.urlSessionTaskID == downloadTask.taskIdentifier }) else { return }
        let task = activeDownloads[index]
        guard !task.isCancelled else { return }
        guard let response = downloadTask.response as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            activeDownloads[index].error = "Download failed (HTTP \(status))."
            networkTasks.removeValue(forKey: task.id)
            cancellationTokens.removeValue(forKey: task.id)
            return
        }
        let manager = modManager
        guard task.archiveInstallation != nil || manager != nil else {
            activeDownloads[index].error = "The mod installer is unavailable."
            networkTasks.removeValue(forKey: task.id)
            cancellationTokens.removeValue(forKey: task.id)
            return
        }
        let token = cancellationTokens[task.id] ?? DownloadCancellationToken()
        cancellationTokens[task.id] = token
        let safeName = URL(fileURLWithPath: task.fileName).lastPathComponent
        let permanentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_" + (safeName.isEmpty ? "mod.zip" : safeName))
        do {
            try FileManager.default.moveItem(at: location, to: permanentURL)
        } catch {
            activeDownloads[index].error = "File move error: \(error.localizedDescription)"
            networkTasks.removeValue(forKey: task.id)
            cancellationTokens.removeValue(forKey: task.id)
            return
        }
        activeDownloads[index].progress = 1
        activeDownloads[index].isExtracting = true
        networkTasks.removeValue(forKey: task.id)
        if let installArchive = task.archiveInstallation {
            installationTasks[task.id] = Task { @MainActor [weak self] in
                defer { try? FileManager.default.removeItem(at: permanentURL) }
                let result: Result<Void, Error>
                do {
                    try token.checkCancellation()
                    try Task.checkCancellation()
                    try await installArchive(permanentURL, { try token.checkCancellation() })
                    try token.checkCancellation()
                    try Task.checkCancellation()
                    result = .success(())
                } catch {
                    result = .failure(error)
                }
                self?.finishInstallation(id: task.id, token: token, result: result)
            }
            return
        }
        guard let manager else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { try? FileManager.default.removeItem(at: permanentURL) }
            let result: Result<Void, Error>
            do {
                try token.checkCancellation()
                _ = try manager.installMod(
                    zipURL: permanentURL, smapiDir: task.smapiDir,
                    customModsDir: task.customModsDir, collectionFolder: task.collectionFolder,
                    autoEnableInProfileID: task.autoEnableInProfileID,
                    cancellationCheck: { try token.checkCancellation() }
                )
                try token.checkCancellation()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                self?.finishInstallation(id: task.id, token: token, result: result)
            }
        }
    }

    private func finishInstallation(id: UUID, token: DownloadCancellationToken, result: Result<Void, Error>) {
        installationTasks.removeValue(forKey: id)
        cancellationTokens.removeValue(forKey: id)
        guard let index = activeDownloads.firstIndex(where: { $0.id == id }) else { return }
        activeDownloads[index].isExtracting = false
        let wasCancelled: Bool
        if case .failure(let error) = result { wasCancelled = error is CancellationError }
        else { wasCancelled = false }
        if token.isCancelled || wasCancelled {
            activeDownloads[index].isCancelled = true
            activeDownloads[index].error = "Download cancelled."
            return
        }
        switch result {
        case .success:
            activeDownloads[index].isCompleted = true
        case .failure(let error):
            activeDownloads[index].error = "Installation failed: \(error.localizedDescription)"
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error,
              let index = activeDownloads.firstIndex(where: { $0.urlSessionTaskID == task.taskIdentifier }) else { return }
        let id = activeDownloads[index].id
        if !activeDownloads[index].isCancelled {
            activeDownloads[index].error = error.localizedDescription
        }
        activeDownloads[index].isExtracting = false
        networkTasks.removeValue(forKey: id)
        cancellationTokens.removeValue(forKey: id)
    }
}

private final class DownloadCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
    }
}
