import Foundation
import SwiftUI

struct DownloadTask: Identifiable {
    let id = UUID()
    let fileName: String
    let modID: Int
    var progress: Double
    var isCompleted: Bool = false
    var error: String?
}

class DownloadManager: ObservableObject {
    @Published var activeDownloads: [DownloadTask] = []
    
    private var session: URLSession!
    
    init() {
        let configuration = URLSessionConfiguration.default
        self.session = URLSession(configuration: configuration, delegate: nil, delegateQueue: .main)
    }
    
    func startDownload(url: URL, fileName: String, modID: Int, smapiDir: String, customModsDir: String, modManager: ModManager) {
        let task = DownloadTask(fileName: fileName, modID: modID, progress: 0)
        activeDownloads.append(task)
        
        let urlTask = session.downloadTask(with: url) { localURL, response, error in
            if let error = error {
                DispatchQueue.main.async {
                    if let index = self.activeDownloads.firstIndex(where: { $0.modID == modID }) {
                        self.activeDownloads[index].error = error.localizedDescription
                    }
                }
                return
            }
            
            guard let localURL = localURL else { return }
            
            // Call ModManager to install the downloaded zip
            DispatchQueue.main.async {
                modManager.installMod(zipURL: localURL, smapiDir: smapiDir, customModsDir: customModsDir)
                if let index = self.activeDownloads.firstIndex(where: { $0.modID == modID }) {
                    self.activeDownloads[index].isCompleted = true
                    self.activeDownloads[index].progress = 1.0
                }
            }
        }
        
        urlTask.resume()
    }
}
