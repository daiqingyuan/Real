import AppKit

@MainActor func runUninstallTests() -> [String] {
    var failures: [String] = []
    func check(_ value: @autoclosure () throws -> Bool, _ message: String) {
        if (try? value()) != true { failures.append("Uninstall: " + message) }
    }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("real-uninstall-tests-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    func makeApp(_ name: String, id: String = "local.dan.real") throws -> URL {
        let app = root.appendingPathComponent(name).appendingPathComponent("Real.app")
        let executable = app.appendingPathComponent("Contents/MacOS/real")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture only".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "real", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }
    enum FixtureError: Error { case denied }
    do {
        let app = try makeApp("current")
        let other = try makeApp("other-copy")
        let home = root.appendingPathComponent("home")
        let target = UninstallTarget(appURL: app, homeURL: home)
        try target.validate()
        let wrong = try makeApp("wrong", id: "someone.else")
        check((try? UninstallTarget(appURL: wrong, homeURL: home).validate()) == nil, "reject unrelated bundle identity")
        check((try? UninstallTarget(appURL: root, homeURL: home).validate()) == nil, "reject parent folder and non-app paths")
        let link = root.appendingPathComponent("Alias.app")
        try fm.createSymbolicLink(at: link, withDestinationURL: app)
        check((try? UninstallTarget(appURL: link, homeURL: home).validate()) == nil, "reject symlinked application")
        let badExecutable = try makeApp("bad-executable")
        let executable = badExecutable.appendingPathComponent("Contents/MacOS/real")
        try fm.removeItem(at: executable)
        try fm.createSymbolicLink(at: executable, withDestinationURL: app.appendingPathComponent("Contents/MacOS/real"))
        check((try? UninstallTarget(appURL: badExecutable, homeURL: home).validate()) == nil, "reject executable outside bundle")

        var actions: [String] = []
        var cleaned = 0, completed = 0, failUnregister = false, failTrash = false
        var service: UninstallService!
        service = UninstallService(target: target, unregister: {
            actions.append("unregister")
            if failUnregister { throw FixtureError.denied }
        }, suspend: { actions.append("stop") }, resume: { actions.append("resume") }, trash: { url in
            actions.append("trash")
            check(url == app, "must target this exact app only")
            // A second in-flight request cannot run another transaction.
            service.confirm()
            if failTrash { throw FixtureError.denied }
        }, cleanData: { cleaned += 1; actions.append("clean"); return [] }, finish: { _ in completed += 1; actions.append("finish") })
        service.confirm()
        check(actions.isEmpty, "confirmation without a presented dialog does nothing")
        service.present(); service.removeData = true; service.dismiss(); service.confirm()
        check(actions.isEmpty && cleaned == 0, "cancel does not unregister, stop, trash or clean")
        service.present()
        check(!service.removeData, "a new dialog always defaults to preserving app data")
        failUnregister = true; service.removeData = true; service.confirm()
        check(actions == ["unregister"] && cleaned == 0 && completed == 0 && !service.isWorking,
              "login unregister failure leaves app and data intact")
        actions = []; failUnregister = false; failTrash = true; service.confirm()
        check(actions == ["unregister", "stop", "trash", "resume"] && cleaned == 0 && completed == 0,
              "trash failure resumes backend without deleting settings or files")
        check(!service.errorMessage.isEmpty, "failed removal stays visible with an error")
        actions = []; failTrash = false; service.removeData = false; service.confirm()
        check(actions == ["unregister", "stop", "trash", "finish"] && completed == 1 && cleaned == 0,
              "normal removal keeps data and follows stop-before-trash order")
        check(fm.fileExists(atPath: other.path), "other application copy stays untouched")

        // End-to-end owned-data plan against an isolated home. Trash is moved
        // into this fixture, never the user's app or real preference domain.
        var preferences = ["kept": "value"], tokenRemoved = false
        for url in target.dataURLs {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("metadata".utf8).write(to: url.appendingPathComponent("fixture.json"))
        }
        let original = home.appendingPathComponent("Documents/Original.txt")
        try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originalData = Data("user original - never remove".utf8)
        try originalData.write(to: original)
        let exported = home.appendingPathComponent("Documents/Exported diagnostics.json")
        try originalData.write(to: exported)
        let trashFolder = root.appendingPathComponent("trash")
        try fm.createDirectory(at: trashFolder, withIntermediateDirectories: true)
        let trash: (URL) throws -> Void = { url in
            try fm.moveItem(at: url, to: trashFolder.appendingPathComponent(UUID().uuidString))
        }
        let cleanedService = UninstallService(target: target, unregister: {}, suspend: {}, resume: {}, trash: trash,
            cleanData: { target.cleanData(trash: trash, clearPreferences: { preferences.removeAll() }, clearTokens: { tokenRemoved = true }) },
            finish: { errors in check(errors.isEmpty, "normal fixture cleanup succeeds") })
        cleanedService.present(); cleanedService.removeData = true; cleanedService.confirm()
        check(!fm.fileExists(atPath: app.path) && fm.fileExists(atPath: other.path), "successful transaction moves only selected bundle")
        check(target.dataURLs.allSatisfy { !fm.fileExists(atPath: $0.path) } && preferences.isEmpty && tokenRemoved,
              "checked cleanup covers owned files, preferences and scoped token callback")
        check(try Data(contentsOf: original) == originalData, "shelf original remains byte-identical")
        check(try Data(contentsOf: exported) == originalData, "exported diagnostic remains byte-identical")
        check(fm.fileExists(atPath: trashFolder.path), "removed fixture files remain recoverable")

        // Missing data, symlink targets and partial failures are recoverable.
        let symlinkTarget = target.dataURLs[0]
        try fm.createSymbolicLink(at: symlinkTarget, withDestinationURL: original.deletingLastPathComponent())
        let symlinkFailures = target.cleanData(trash: trash, clearPreferences: {}, clearTokens: {})
        let originalAfterSymlink = try Data(contentsOf: original)
        check(symlinkFailures == [symlinkTarget.path] && originalAfterSymlink == originalData,
              "symlinked app data cannot erase its destination")
        try fm.removeItem(at: symlinkTarget)
        let missingErrors = target.cleanData(trash: trash, clearPreferences: {}, clearTokens: {})
        check(missingErrors.isEmpty, "missing app data is already clean")
        let tokenErrors = target.cleanData(trash: trash, clearPreferences: {}, clearTokens: { throw FixtureError.denied })
        check(tokenErrors.count == 1, "failed credential cleanup is reported")

        // Exercise macOS' real trash API only on a newly-created empty fixture.
        let nativeFixture = root.appendingPathComponent("Native trash fixture " + UUID().uuidString)
        try fm.createDirectory(at: nativeFixture, withIntermediateDirectories: true)
        var trashedURL: NSURL?
        try fm.trashItem(at: nativeFixture, resultingItemURL: &trashedURL)
        check(!fm.fileExists(atPath: nativeFixture.path) && trashedURL != nil, "native move-to-Trash works for isolated fixture")
        if let trashedURL { try fm.removeItem(at: trashedURL as URL) }
    } catch { failures.append("Uninstall fixture: " + error.localizedDescription) }
    if failures.isEmpty { print("PASS: uninstall cancellation, target safety, failure recovery, optional cleanup and native Trash fixture") }
    return failures
}
