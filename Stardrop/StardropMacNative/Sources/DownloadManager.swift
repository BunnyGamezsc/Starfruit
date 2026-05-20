import Foundation
import SwiftUI
import Combine

struct DownloadTask: Identifiable {
    let id = UUID()
    let fileName: String
    let modID: Int
    var progress: Double = 0.0
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var speedBytesPerSecond: Double = 0
    var isCompleted: Bool = false
    var isExtracting: Bool = false
    var error: String?
    let startTime: Date = Date()
    
    // Internal tracking
    var urlSessionTaskID: Int?
    var smapiDir: String = ""
    var customModsDir: String = ""
    var collectionFolder: String? = nil
    var autoEnableInProfileID: UUID? = nil
    
    var etaSeconds: Double {
        guard speedBytesPerSecond > 0, totalBytes > 0 else { return 0 }
        let remaining = totalBytes - downloadedBytes
        return Double(remaining) / speedBytesPerSecond
    }
}

class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var activeDownloads: [DownloadTask] = []
    
    private var session: URLSession!
    weak var modManager: ModManager?
    
    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }
    
    func startDownload(url: URL, fileName: String, modID: Int, smapiDir: String, customModsDir: String, modManager: ModManager, collectionFolder: String? = nil, autoEnableInProfileID: UUID? = nil) {
        if self.modManager == nil {
            self.modManager = modManager
        }
        
        let urlTask = session.downloadTask(with: url)
        
        var task = DownloadTask(fileName: fileName, modID: modID)
        task.urlSessionTaskID = urlTask.taskIdentifier
        task.smapiDir = smapiDir
        task.customModsDir = customModsDir
        task.collectionFolder = collectionFolder
        task.autoEnableInProfileID = autoEnableInProfileID
        
        activeDownloads.append(task)
        urlTask.resume()
    }
    
    func clearCompleted() {
        activeDownloads.removeAll { $0.isCompleted || $0.error != nil }
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
        
        var task = activeDownloads[index]
        task.progress = 1.0
        task.isExtracting = true
        activeDownloads[index] = task
        
        let tempDir = FileManager.default.temporaryDirectory
        let permanentURL = tempDir.appendingPathComponent(UUID().uuidString + "_" + task.fileName)
        
        do {
            try FileManager.default.moveItem(at: location, to: permanentURL)
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self, let modManager = self.modManager else { return }
                
                modManager.installMod(zipURL: permanentURL, smapiDir: task.smapiDir, customModsDir: task.customModsDir, collectionFolder: task.collectionFolder, autoEnableInProfileID: task.autoEnableInProfileID)
                
                try? FileManager.default.removeItem(at: permanentURL)
                
                DispatchQueue.main.async {
                    if let finalIndex = self.activeDownloads.firstIndex(where: { $0.id == task.id }) {
                        self.activeDownloads[finalIndex].isExtracting = false
                        self.activeDownloads[finalIndex].isCompleted = true
                    }
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.activeDownloads[index].error = "File move error: \(error.localizedDescription)"
                self.activeDownloads[index].isExtracting = false
            }
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            guard let index = activeDownloads.firstIndex(where: { $0.urlSessionTaskID == task.taskIdentifier }) else { return }
            activeDownloads[index].error = error.localizedDescription
            activeDownloads[index].isExtracting = false
        }
    }
}
