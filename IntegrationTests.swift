import AppKit

@main
struct IntegrationTests {
    @MainActor
    static func checkIcon(_ application: NSRunningApplication, color: ProfileColor) throws {
        guard let tiff = application.icon?.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let actual = bitmap.colorAt(x: bitmap.pixelsWide / 4, y: bitmap.pixelsHigh / 4)?.usingColorSpace(.deviceRGB),
              let png = ProfileArtwork.png(label: "I", color: color, size: 512),
              let expectedTIFF = NSImage(data: png)?.tiffRepresentation,
              let expectedBitmap = NSBitmapImageRep(data: expectedTIFF),
              let expected = expectedBitmap.colorAt(x: expectedBitmap.pixelsWide / 4, y: expectedBitmap.pixelsHigh / 4)?.usingColorSpace(.deviceRGB) else {
            throw ProfileError.message("Missing running profile icon")
        }
        guard abs(actual.redComponent - expected.redComponent) < 0.04,
              abs(actual.greenComponent - expected.greenComponent) < 0.04,
              abs(actual.blueComponent - expected.blueComponent) < 0.04 else {
            throw ProfileError.message("Running icon does not match profile color: \(color.rawValue)")
        }
    }

    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("polr-switch-integration-\(UUID().uuidString)", isDirectory: true)
        print("Disposable integration root: \(root.path)")
        let store = ProfileStore(root: root)
        try store.seed()
        let aID = try store.save(name: "Integration A \(UUID().uuidString.prefix(6))", color: .blue)
        let bID = try store.save(name: "Integration B \(UUID().uuidString.prefix(6))", color: .orange)
        let profiles = try [store.profile(aID), store.profile(bID)]
        defer {
            for profile in profiles {
                if let app = try? ClaudeLauncher.running(ClaudeLauncher.spec(profile, store: store)) { _ = app.terminate() }
            }
        }
        let mainSpec = LaunchSpec(app: ClaudeLauncher.app, data: nil)
        let originals = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop")
            .filter { app in
                guard let arguments = try? ProcessArguments.read(app.processIdentifier) else { return false }
                return mainSpec.matches(arguments)
            }.map(\.processIdentifier)
        let a = try await ClaudeLauncher.open(profiles[0].id, store: store)
        let b = try await ClaudeLauncher.open(profiles[1].id, store: store)
        precondition(a != b && !originals.contains(a) && !originals.contains(b))
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let again = try await ClaudeLauncher.open(profiles[0].id, store: store)
        precondition(a == again)
        for (profile, pid) in zip(profiles, [a, b]) {
            let spec = ClaudeLauncher.spec(profile, store: store)
            guard spec.matches(try ProcessArguments.read(pid)) else { fatalError("Profile argument mismatch") }
            guard let app = try ClaudeLauncher.running(spec) else { fatalError("Missing test process") }
            precondition(app.processIdentifier == pid)
            try checkIcon(app, color: profile.color)
            precondition(app.terminate())
        }
        for _ in 0..<30 {
            if NSRunningApplication(processIdentifier: a)?.isTerminated != false && NSRunningApplication(processIdentifier: b)?.isTerminated != false { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard NSRunningApplication(processIdentifier: a)?.isTerminated != false,
              NSRunningApplication(processIdentifier: b)?.isTerminated != false else {
            throw ProfileError.message("Test instances did not close. They were not force-quit.")
        }
        _ = try store.save(id: profiles[0].id, name: profiles[0].name, color: .green)
        let reopened = try await ClaudeLauncher.open(profiles[0].id, store: store)
        precondition(reopened != a)
        let spec = ClaudeLauncher.spec(profiles[0], store: store)
        guard let app = try ClaudeLauncher.running(spec) else { fatalError("Missing reopened process") }
        try checkIcon(app, color: .green)
        precondition(app.terminate())
        let checkCopy = root.appendingPathComponent("Signature Check.app")
        try await runLocalTool("/bin/cp", ["-cR", spec.app.path, checkCopy.path])
        precondition(NSWorkspace.shared.setIcon(nil, forFile: checkCopy.path, options: []))
        try await runLocalTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", checkCopy.path])
        try await runLocalTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", ClaudeLauncher.app.path])
        print("PASS: distinct running icon colors, color change after relaunch, original Claude signature, and copy signature after removing Finder metadata")
        for pid in originals { precondition(NSRunningApplication(processIdentifier: pid)?.isTerminated == false) }
        if let main = try store.load().first(where: \.isMain), originals.count == 1 {
            let mainPID = try await ClaudeLauncher.open(main.id, store: store)
            precondition(mainPID == originals[0])
            print("PASS: Main reuses original Claude")
        }
        print("PASS: two independent Claude processes, correct profile arguments, repeat launch reuses same PID, quit/relaunch preserves profile")
        print("Not tested: login identity, Cowork execution, browser integration, update restart")
    }
}
