import Foundation
import Darwin

@main
struct Tests {
    static func check(_ condition: Bool) { precondition(condition) }
    static func rejects(_ action: () throws -> Void) {
        do { try action(); fatalError("Expected rejection") } catch { }
    }

    static func main() throws {
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
        let id = try store.save(name: "  Work / café $(literal)  ", color: "Blue")
        let path = try store.prepare(id)
        check(path.path.contains(id.uuidString))
        check(!path.path.contains("café"))
        check(try store.profile(id).name == "Work / café $(literal)")
        _ = try store.save(id: id, name: "Renamed", color: "Green")
        check(store.dataURL(id) == path)
        rejects { _ = try store.save(name: "renamed", color: "Orange") }
        rejects { _ = try store.save(name: " ", color: "Blue") }
        rejects { _ = try store.save(name: "a\nb", color: "Blue") }
        rejects { _ = try store.save(name: "Valid", color: "Unknown") }
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

        let original = try Data(contentsOf: store.registryURL)
        try Data("broken".utf8).write(to: store.registryURL)
        rejects { _ = try store.save(name: "Will not overwrite", color: "Blue") }
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
        print("PASS: registry integrity, stable IDs, names, archive/restore, exact launch matching, process parsing, locking, and symlink rejection")
    }
}
