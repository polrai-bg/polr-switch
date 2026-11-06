import AppKit

@main
struct IntegrationTests {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loftlane-integration-\(UUID().uuidString)", isDirectory: true)
        print("Disposable integration root: \(root.path)")
        let store = ProfileStore(root: root)
        try store.seed()
        let aID = try store.save(name: "Integration A \(UUID().uuidString.prefix(6))", color: "Blue")
        let bID = try store.save(name: "Integration B \(UUID().uuidString.prefix(6))", color: "Orange")
        let profiles = try [store.profile(aID), store.profile(bID)]
        let originals = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop")
            .filter { app in
                guard let arguments = try? ProcessArguments.read(app.processIdentifier) else { return false }
                return !arguments.contains(where: { $0.hasPrefix("--user-data-dir=") })
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
        let reopened = try await ClaudeLauncher.open(profiles[0].id, store: store)
        precondition(reopened != a)
        let spec = ClaudeLauncher.spec(profiles[0], store: store)
        guard let app = try ClaudeLauncher.running(spec) else { fatalError("Missing reopened process") }
        precondition(app.terminate())
        for pid in originals { precondition(NSRunningApplication(processIdentifier: pid)?.isTerminated == false) }
        if let main = try store.load().first(where: \.isMain), originals.count == 1 {
            let mainPID = try await ClaudeLauncher.open(main.id, store: store)
            precondition(mainPID == originals[0])
        }
        print("PASS: two independent Claude processes, correct profile arguments, repeat launch reuses same PID, quit/relaunch preserves profile, Main reuses original Claude")
        print("Not tested: login identity, Cowork execution, browser integration, update restart")
    }
}
