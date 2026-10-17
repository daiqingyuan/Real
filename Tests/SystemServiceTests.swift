import Foundation

@MainActor func runSystemServiceTests() -> [String] {
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) { if !condition { failures.append("System services: " + message) } }
    var channels = [1: 0.2, 2: 0.8]
    let originals = channels
    let partial = AudioControlTransaction.apply(elements: [1, 2], target: 0.5,
        read: { channels[$0] }, write: { channel, value in
            if channel == 2 && value == 0.5 { return false }
            channels[channel] = value; return true
        }, matches: { abs($0 - $1) < 0.001 })
    check(!partial && channels == originals, "second-channel failure restores prior writes")
    let ignored = AudioControlTransaction.apply(elements: [1, 2], target: 0.5,
        read: { channels[$0] }, write: { _, _ in true }, matches: { abs($0 - $1) < 0.001 })
    check(!ignored && channels == originals, "aggregate average matching target cannot disguise ignored channel writes")
    var writeCount = 0
    let unreadable = AudioControlTransaction.apply(elements: [1, 2, 3], target: 0.5,
        read: { channels[$0] }, write: { _, _ in writeCount += 1; return true }, matches: ==)
    check(!unreadable && writeCount == 0, "unreadable original state prevents any writes")
    let success = AudioControlTransaction.apply(elements: [1, 2], target: 0.5,
        read: { channels[$0] }, write: { channels[$0] = $1; return true }, matches: ==)
    check(success && channels.values.allSatisfy { $0 == 0.5 }, "all channels require verified success")
    var owners = CameraPreviewOwnership()
    let first = UUID(), second = UUID()
    check(!owners.release(first), "unknown preview release does not stop camera")
    owners.retain(first); owners.retain(second)
    check(!owners.release(first), "another visible preview keeps camera")
    check(!owners.release(first), "duplicate release does not stop remaining owner")
    check(owners.release(second), "last real owner stops camera")
    check(!owners.release(second), "duplicate final teardown is harmless")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("real-service-tests-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storage = directory.appendingPathComponent("bookmarks.json")
        let id = UUID()
        // A broken/offline bookmark cannot resolve. It still must survive an
        // unrelated save; this fixture never touches the user's saved shelf.
        let records: [[String: String]] = [["id": id.uuidString, "bookmark": Data([0, 1, 2]).base64EncodedString()]]
        try JSONSerialization.data(withJSONObject: records).write(to: storage)
        let shelf = ShelfService(storageURL: storage)
        check(shelf.items.isEmpty, "unavailable reference is not shown as reachable")
        shelf.add(urls: [])
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: storage)) as? [[String: Any]]
        check(restored?.count == 1 && restored?.first?["id"] as? String == id.uuidString, "unavailable bookmark survives later persistence")
        shelf.remove(id: id)
        let removed = try JSONSerialization.jsonObject(with: Data(contentsOf: storage)) as? [[String: Any]]
        check(removed?.isEmpty == true, "explicit reference removal persists")
        let sentinel = directory.appendingPathComponent("sentinel.txt")
        try Data("keep".utf8).write(to: sentinel)
        shelf.clear()
        check(FileManager.default.fileExists(atPath: sentinel.path), "clear does not delete files")
        let corruptURL = directory.appendingPathComponent("corrupt.json")
        let corruptData = Data("[{partially damaged bookmark data".utf8)
        try corruptData.write(to: corruptURL)
        let corruptShelf = ShelfService(storageURL: corruptURL)
        corruptShelf.add(urls: [])
        let recoveryFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("corrupt.recovery-") }
        check(recoveryFiles.count == 1, "unreadable storage gets a recovery copy before replacement")
        if let recovery = recoveryFiles.first {
            check(try Data(contentsOf: recovery) == corruptData, "recovery copy preserves exact original bytes")
        }
        corruptShelf.clear()
        let after = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("corrupt.recovery-") }
        check(after.count == 1, "later edits do not duplicate or delete preserved recovery data")
    } catch { failures.append("System services: isolated persistence fixture failed: " + error.localizedDescription) }
    return failures
}

#if SYSTEM_SERVICES_STANDALONE
@main struct SystemServiceTestsRunner {
    @MainActor static func main() {
        let failures = runSystemServiceTests() + runAudioSpectrumTests()
        if failures.isEmpty { print("PASS: audio write transactions, camera ownership, shelf persistence/recovery, FFT and PCM") }
        else { failures.forEach { print("FAIL: " + $0) }; exit(1) }
    }
}
#endif
