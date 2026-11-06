import Foundation
import Darwin

@main
struct Tests {
    static func check(_ condition: Bool) { precondition(condition) }
    static func rejects(_ action: () throws -> Void) {
        do { try action(); fatalError("Expected rejection") } catch { }
    }

    @MainActor
    static func main() async throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--expect-busy" {
            do {
                let lease = try FileLease(at: URL(fileURLWithPath: CommandLine.arguments[2]))
                lease.release()
                exit(1)
            } catch {
                guard error.localizedDescription.contains("operation is in progress") else { exit(2) }
                exit(0)
            }
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("claude-profiles-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let store = ProfileStore(root: root)
        try store.seed()
        let seeded = try store.load()
        check(seeded.count == 2)
        check(seeded[1].name == "Work")
        check(seeded[0].isMain)
        rejects { _ = try store.prepare(seeded[0].id) }
        rejects { try store.setArchived(seeded[0].id, true) }
        try store.seed()
        check(try store.load().map(\.id) == seeded.map(\.id))
        let id = try store.save(name: "  Work / café $(literal)  ", color: .blue)
        let path = try store.prepare(id)
        check(path.path.contains(id.uuidString))
        check(!path.path.contains("café"))
        check(try store.profile(id).name == "Work / café $(literal)")
        _ = try store.save(id: id, name: "Renamed", color: .green)
        check(store.dataURL(id) == path)
        rejects { _ = try store.save(name: "renamed", color: .orange) }
        rejects { _ = try store.save(name: " ", color: .blue) }
        rejects { _ = try store.save(name: "a\nb", color: .blue) }
        rejects { _ = try JSONDecoder().decode(ProfileColor.self, from: Data("\"Unknown\"".utf8)) }
        try store.setArchived(id, true)
        rejects { _ = try store.prepare(id) }
        check(fm.fileExists(atPath: path.path))
        try store.setArchived(id, false)
        check(try store.profile(id).name == "Renamed")

        let app = URL(fileURLWithPath: "/Applications/Claude.app")
        let mainSpec = LaunchSpec(app: app, data: nil)
        check(mainSpec.arguments.isEmpty)
        check(mainSpec.matches([mainSpec.executable.path]))
        check(!mainSpec.matches([mainSpec.executable.path, "--user-data-dir=/other"]))
        check(!mainSpec.matches([mainSpec.executable.path, "--user-data-dir", "/other"]))
        let spec = LaunchSpec(app: app, data: URL(fileURLWithPath: "/private/tmp/profile with spaces"))
        check(spec.arguments.count == 1)
        check(spec.matches([spec.executable.path] + spec.arguments))
        check(!spec.matches([spec.executable.path]))
        check(!spec.matches([spec.executable.path, spec.arguments[0] + "2"]))
        check(!spec.matches(["/bin/echo"] + spec.arguments))
        check(!spec.matches([spec.executable.path] + spec.arguments + spec.arguments))
        check(!spec.matches([spec.executable.path] + spec.arguments + ["--type=renderer"]))
        let args = [spec.executable.path, spec.arguments[0], "", "--test"]
        var count = Int32(args.count)
        var buffer = withUnsafeBytes(of: &count) { Array($0) }
        buffer += Array(spec.executable.path.utf8) + [0, 0, 0]
        for arg in args { buffer += Array(arg.utf8) + [0] }
        buffer += Array("SECRET_ENV=not-an-argument".utf8) + [0]
        check(try ProcessArguments.decode(buffer) == args)
        rejects { _ = try ProcessArguments.decode([0, 1]) }
        rejects { _ = try ProcessArguments.decode(Array(buffer.prefix(9))) }

        let fixtureApp = root.appendingPathComponent("Fixture.app")
        let fixtureExecutable = fixtureApp.appendingPathComponent("Contents/MacOS/Claude")
        try fm.createDirectory(at: fixtureExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: fixtureExecutable)
        let fixtureAlias = root.appendingPathComponent("Alias.app")
        try fm.createSymbolicLink(at: fixtureAlias, withDestinationURL: fixtureApp)
        let fixtureSpec = LaunchSpec(app: fixtureApp, data: nil)
        check(fixtureSpec.matches([fixtureAlias.appendingPathComponent("Contents/MacOS/Claude").path]))
        check(!fixtureSpec.matches([fixtureAlias.appendingPathComponent("Contents/MacOS/Other").path]))

        let original = try Data(contentsOf: store.registryURL)
        try Data("broken".utf8).write(to: store.registryURL)
        rejects { _ = try store.save(name: "Will not overwrite", color: .blue) }
        check(try Data(contentsOf: store.registryURL) == Data("broken".utf8))
        try original.write(to: store.registryURL)
        let fd = Darwin.open(root.appendingPathComponent("registry.lock").path, O_RDWR)
        check(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0)
        rejects { _ = try store.load() }
        flock(fd, LOCK_UN)
        Darwin.close(fd)
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: path)
        rejects { try store.privateDirectory(alias) }
        check(try store.load().count == 3)
        var legacy = Registry(profiles: try store.load())
        legacy.version = 1
        legacy.profiles[0].usesDefaultProfile = nil
        legacy.profiles[1].archived = true
        let savedIDs = legacy.profiles.map(\.id)
        try JSONEncoder().encode(legacy).write(to: store.registryURL)
        try store.seed()
        let migrated = try store.load()
        check(migrated.map(\.id) == savedIDs)
        check(migrated[0].isMain && migrated[1].archived && migrated[2].name == "Renamed")
        let lease = try store.operationLease(id)
        rejects { _ = try ProfileStore(root: root).operationLease(id) }
        rejects { try ClaudeLauncher.setArchived(id, true, store: store) }
        do {
            _ = try await ClaudeLauncher.open(id, store: store)
            fatalError("Concurrent open should be refused before touching Claude")
        } catch { check(error.localizedDescription.contains("operation is in progress")) }
        let independent = try store.operationLease(seeded[0].id)
        independent.release()
        try await runLocalTool(CommandLine.arguments[0], ["--expect-busy", root.appendingPathComponent("operation-\(id.uuidString).lock").path])
        lease.release()
        try store.operationLease(id).release()
        check(try store.profile(id).archived == false)

        let plistURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Info.plist")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), options: [], format: nil) as! [String: Any]
        let metadata = try AppMetadata(info: plist)
        let launcher = metadata.launcherInfo(try store.profile(id))
        for key in ["CFBundleName", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion"] {
            check(launcher[key] as? String == plist[key] as? String)
        }
        check(launcher["CFBundleIdentifier"] as? String != plist["CFBundleIdentifier"] as? String)
        check(launcher["ProfileID"] as? String == id.uuidString)
        check(launcher["CFBundleDisplayName"] as? String == "\(metadata.name) Renamed")
        rejects { _ = try AppMetadata(info: [:]) }
        try await runLocalTool("/usr/bin/true", [])
        do {
            try await runLocalTool("/usr/bin/false", [])
            fatalError("Failed subprocess should be reported")
        } catch { check(error.localizedDescription.contains("exit 1")) }
        print("PASS: cross-process lifecycle exclusion, archive/open coordination, metadata inheritance, and async tool errors")
        print("PASS: registry integrity, stable IDs, names, archive/restore, exact launch matching, process parsing, locking, and symlink rejection")
    }
}
