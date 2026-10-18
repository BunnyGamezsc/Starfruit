import Foundation

// These fixtures compile with DownloadManager.swift, without the app or network.
final class ModManager {
    func installMod(zipURL: URL, smapiDir: String, customModsDir: String,
                    collectionFolder: String?, autoEnableInProfileID: UUID?,
                    cancellationCheck: () throws -> Void) throws -> [String] {
        try cancellationCheck()
        throw FixtureError.unexpectedOrdinaryInstall
    }
}

enum FixtureError: Error { case failed, unexpectedOrdinaryInstall, assertion(String) }

final class FixtureDownloadTask: URLSessionDownloadTask, @unchecked Sendable {
    private let fixtureResponse: URLResponse
    init(status: Int = 200) {
        fixtureResponse = HTTPURLResponse(url: URL(string: "https://example.invalid/mod.zip")!, statusCode: status, httpVersion: nil, headerFields: nil)!
        super.init()
    }
    override var taskIdentifier: Int { 73 }
    override var response: URLResponse? { fixtureResponse }
}

@main
@MainActor
struct DownloadRegression {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw FixtureError.assertion(message) }
    }

    static func waitForCompletion(_ manager: DownloadManager) async throws {
        for _ in 0..<200 {
            if manager.activeDownloads.first?.isExtracting == false { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw FixtureError.assertion("installation timed out")
    }

    static func fixture(_ action: @escaping NativeArchiveInstallation) throws -> (DownloadManager, URL, UUID) {
        let manager = DownloadManager()
        var task = DownloadTask(fileName: "fixture.zip", modID: 1, fileID: 2)
        task.urlSessionTaskID = 73
        task.archiveInstallation = action
        manager.activeDownloads = [task]
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("StarfruitDownloadFixture-\(UUID().uuidString).zip")
        try Data("fixture".utf8).write(to: archive)
        return (manager, archive, task.id)
    }

    static func main() async throws {
        let suite = "StarfruitDownloadFixture-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try expect(NativeModInstallTarget.shouldAsk(defaults: defaults), "destination defaults to asking")
        defaults.set(false, forKey: NativeModInstallTarget.preferenceKey)
        try expect(!NativeModInstallTarget.shouldAsk(defaults: defaults), "disabled prompt uses collection context")
        try expect(NativeModInstallTarget.choose(collectionName: "Fixture", defaults: defaults) == .collectionAddon, "disabled prompt chooses collection without showing UI")

        let archivePath = ArchivePath()
        let (success, archive, _) = try fixture { url, check in
            try check()
            guard FileManager.default.fileExists(atPath: url.path) else { throw FixtureError.assertion("custom install receives retained archive") }
            await archivePath.set(url)
        }
        success.urlSession(URLSession.shared, downloadTask: FixtureDownloadTask(), didFinishDownloadingTo: archive)
        try await waitForCompletion(success)
        try expect(success.activeDownloads[0].isCompleted, "custom install marked completed")
        let installedArchive = await archivePath.value
        try expect(installedArchive != nil && !FileManager.default.fileExists(atPath: installedArchive!.path), "successful install temporary archive removed")

        let failedPath = ArchivePath()
        let (failed, failedArchive, _) = try fixture { url, _ in
            await failedPath.set(url)
            throw FixtureError.failed
        }
        failed.urlSession(URLSession.shared, downloadTask: FixtureDownloadTask(), didFinishDownloadingTo: failedArchive)
        try await waitForCompletion(failed)
        try expect(!failed.activeDownloads[0].isCompleted && failed.activeDownloads[0].error?.contains("Installation failed") == true, "custom failure surfaced")
        let rejectedArchive = await failedPath.value
        try expect(rejectedArchive != nil && !FileManager.default.fileExists(atPath: rejectedArchive!.path), "failed install temporary archive removed")

        let cancelledPath = ArchivePath()
        let (cancelled, cancelledArchive, cancelledID) = try fixture { url, _ in await cancelledPath.set(url) }
        cancelled.urlSession(URLSession.shared, downloadTask: FixtureDownloadTask(), didFinishDownloadingTo: cancelledArchive)
        cancelled.cancelDownload(id: cancelledID)
        try await Task.sleep(nanoseconds: 20_000_000)
        try expect(cancelled.activeDownloads[0].isCancelled && !cancelled.activeDownloads[0].isCompleted, "cancel before async installer skips installation")
        let prematureInstall = await cancelledPath.value
        try expect(prematureInstall == nil, "cancelled custom installer never called")
        cancelled.clearCompleted()
        try expect(cancelled.activeDownloads.isEmpty, "cancelled work can be cleared")

        let duringPath = ArchivePath()
        let (during, duringArchive, duringID) = try fixture { url, check in
            await duringPath.set(url)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try check()
        }
        during.urlSession(URLSession.shared, downloadTask: FixtureDownloadTask(), didFinishDownloadingTo: duringArchive)
        try await Task.sleep(nanoseconds: 10_000_000)
        during.cancelDownload(id: duringID)
        try await Task.sleep(nanoseconds: 20_000_000)
        try expect(during.activeDownloads[0].isCancelled && !during.activeDownloads[0].isCompleted, "cancel interrupts async installer")
        let interruptedArchive = await duringPath.value
        try expect(interruptedArchive != nil && !FileManager.default.fileExists(atPath: interruptedArchive!.path), "cancelled install temporary archive removed")

        let rejectedPath = ArchivePath()
        let (badResponse, responseArchive, _) = try fixture { url, _ in await rejectedPath.set(url) }
        badResponse.urlSession(URLSession.shared, downloadTask: FixtureDownloadTask(status: 403), didFinishDownloadingTo: responseArchive)
        try expect(badResponse.activeDownloads[0].error == "Download failed (HTTP 403).", "HTTP failure surfaced before installation")
        let responseInstall = await rejectedPath.value
        try expect(responseInstall == nil, "HTTP failure never invokes installer")
        try FileManager.default.removeItem(at: responseArchive)

        let manual = DownloadManager()
        manual.addManualDownload(fileName: "pending.zip", modID: 10, fileID: 20,
                                 manualURL: URL(string: "https://example.invalid"), errorMsg: nil)
        try expect(manual.hasPendingManualDownload(modID: 10, fileID: 20), "manual file match found")
        try expect(!manual.hasPendingManualDownload(modID: 10, fileID: 21), "different file not matched")
        manual.cancelDownload(id: manual.activeDownloads[0].id)
        try expect(!manual.hasPendingManualDownload(modID: 10, fileID: 20), "cancelled manual match ignored")

        let resumed = DownloadManager()
        resumed.addManualDownload(fileName: "queued.zip", modID: 30, fileID: 40,
                                  manualURL: URL(string: "https://example.invalid"), errorMsg: nil,
                                  smapiDir: "/original/game", customModsDir: "")
        // A local unsupported URL exercises enqueue/resume without contacting a server.
        resumed.startOrResumeDownload(url: URL(fileURLWithPath: "/dev/null"), fileName: "resumed.zip",
                                      modID: 30, fileID: 40, smapiDir: "/other/game", customModsDir: "/other/mods",
                                      modManager: ModManager(), collectionFolder: "other-collection",
                                      autoEnableInProfileID: UUID())
        try expect(resumed.activeDownloads[0].autoEnableInProfileID == nil, "manual nil profile context preserved after profile switch")
        try expect(resumed.activeDownloads[0].collectionFolder == nil, "manual ordinary destination preserved")
        try expect(resumed.activeDownloads[0].smapiDir == "/original/game" && resumed.activeDownloads[0].customModsDir.isEmpty,
                   "manual game/default-mod directory context preserved")
        resumed.cancelDownload(id: resumed.activeDownloads[0].id)
        print("Download destination/action/cancellation regressions passed (isolated fixtures; no network or app launch).")
    }
}

actor ArchivePath {
    var value: URL?
    func set(_ url: URL) { value = url }
}
