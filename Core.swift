import Foundation
import Darwin

struct Profile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var color: ProfileColor
    var archived = false
    var usesDefaultProfile: Bool? = nil
    var isMain: Bool { usesDefaultProfile == true }
}

struct Registry: Codable {
    var version = 2
    var profiles: [Profile]
}

enum ProfileError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

enum ProfileColor: String, Codable, CaseIterable {
    case blue = "Blue", orange = "Orange", green = "Green", purple = "Purple"
}

final class FileLease {
    private var descriptor: Int32

    init(at url: URL) throws {
        descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw ProfileError.message("Cannot open the profile operation lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            descriptor = -1
            throw ProfileError.message("Another profile operation is in progress. Try again shortly.")
        }
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

func checkedName(_ name: String) throws -> String {
    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.count <= 60,
          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        throw ProfileError.message("Use a name between 1 and 60 characters, without control characters.")
    }
    return value
}

final class ProfileStore {
    let root: URL
    private let fm = FileManager.default
    var registryURL: URL { root.appendingPathComponent("profiles.json") }

    init(root: URL) { self.root = root.standardizedFileURL }

    // Keep the preview storage location so existing logins and launchers continue to work.
    static var standard: ProfileStore {
        ProfileStore(root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude Profiles", isDirectory: true))
    }

    func rejectSymlink(_ url: URL, message: String = "A profile storage path is a symbolic link. Choose a normal local folder.") throws {
        let target = url.standardizedFileURL
        let stopAtRoot = target.path == root.path || target.path.hasPrefix(root.path + "/")
        var current = target
        while true {
            var info = stat()
            if Darwin.lstat(current.path, &info) == 0 {
                if (info.st_mode & S_IFMT) == S_IFLNK {
                    throw ProfileError.message(message)
                }
            } else if errno != ENOENT {
                throw ProfileError.message(message)
            }
            if (stopAtRoot && current.path == root.path) || current.path == "/" { break }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { break }
            current = parent
        }
    }

    func privateDirectory(_ url: URL) throws {
        try rejectSymlink(url)
        try fm.createDirectory(at: url, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func locked<T>(_ action: () throws -> T) throws -> T {
        try privateDirectory(root)
        let lease = try FileLease(at: root.appendingPathComponent("registry.lock"))
        defer { lease.release() }
        return try action()
    }

    func operationLease(_ id: UUID) throws -> FileLease {
        try privateDirectory(root)
        return try FileLease(at: root.appendingPathComponent("operation-\(id.uuidString).lock"))
    }

    private func read() throws -> Registry {
        try rejectSymlink(registryURL, message: "The profile registry must not be a symbolic link.")
        guard fm.fileExists(atPath: registryURL.path) else { return Registry(profiles: []) }
        let attrs = try fm.attributesOfItem(atPath: registryURL.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? NSNumber)?.intValue ?? Int.max < 1_048_576 else {
            throw ProfileError.message("The profile registry is not a valid small file. It has been left untouched.")
        }
        let registry: Registry
        do { registry = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: registryURL)) }
        catch { throw ProfileError.message("The profile registry could not be read. It has been left untouched. Restore profiles.json from a backup before continuing.") }
        guard [1, 2].contains(registry.version),
              Set(registry.profiles.map(\.id)).count == registry.profiles.count,
              registry.profiles.filter(\.isMain).count <= 1 else {
            throw ProfileError.message("The profile registry has an unsupported version or duplicate IDs.")
        }
        for p in registry.profiles {
            guard try checkedName(p.name) == p.name else {
                throw ProfileError.message("A stored profile has invalid details. The registry has been left untouched.")
            }
        }
        return registry
    }

    private func write(_ registry: Registry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(registry).write(to: registryURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: registryURL.path)
    }

    func load() throws -> [Profile] { try locked { try read().profiles } }

    func seed() throws {
        try locked {
            var registry = try read()
            if registry.profiles.isEmpty && !fm.fileExists(atPath: registryURL.path) {
                registry.profiles = [Profile(id: UUID(), name: "Personal", color: .blue, usesDefaultProfile: true),
                                     Profile(id: UUID(), name: "Work", color: .orange)]
            } else if !registry.profiles.contains(where: \.isMain) {
                if let i = registry.profiles.firstIndex(where: {
                    !$0.archived && ["personal", "main"].contains($0.name.lowercased())
                }) {
                    registry.profiles[i].usesDefaultProfile = true
                } else {
                    registry.profiles.insert(Profile(id: UUID(), name: "Main", color: .blue, usesDefaultProfile: true), at: 0)
                }
            } else { return }
            registry.version = 2
            try write(registry)
        }
    }

    @discardableResult
    func save(id: UUID? = nil, name: String, color: ProfileColor) throws -> UUID {
        let name = try checkedName(name)
        return try locked {
            var registry = try read()
            guard !registry.profiles.contains(where: {
                !$0.archived && $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) else { throw ProfileError.message("An active profile already uses that name.") }
            let result: UUID
            if let id {
                guard let i = registry.profiles.firstIndex(where: { $0.id == id }) else {
                    throw ProfileError.message("This profile no longer exists. Reopen the manager.")
                }
                registry.profiles[i].name = name
                registry.profiles[i].color = color
                result = id
            } else {
                result = UUID()
                registry.profiles.append(Profile(id: result, name: name, color: color))
            }
            try write(registry)
            return result
        }
    }

    func setArchived(_ id: UUID, _ archived: Bool) throws {
        try locked {
            var registry = try read()
            guard let i = registry.profiles.firstIndex(where: { $0.id == id }) else {
                throw ProfileError.message("Profile not found.")
            }
            guard !registry.profiles[i].isMain else {
                throw ProfileError.message("The main profile represents your regular Claude app and cannot be archived.")
            }
            if !archived && registry.profiles.contains(where: {
                $0.id != id && !$0.archived && $0.name.localizedCaseInsensitiveCompare(registry.profiles[i].name) == .orderedSame
            }) { throw ProfileError.message("Rename the active profile with this name before restoring this one.") }
            registry.profiles[i].archived = archived
            try write(registry)
        }
    }

    func profile(_ id: UUID) throws -> Profile {
        guard let p = try load().first(where: { $0.id == id && !$0.archived }) else {
            throw ProfileError.message("This profile is archived or missing. Open the profile manager to manage it.")
        }
        return p
    }

    func dataURL(_ id: UUID) -> URL {
        root.appendingPathComponent("profiles/\(id.uuidString)/desktop", isDirectory: true)
    }

    func prepare(_ id: UUID) throws -> URL {
        guard !(try profile(id)).isMain else {
            throw ProfileError.message("The main profile uses Claude's original storage and needs no separate folder.")
        }
        let url = dataURL(id)
        try privateDirectory(url)
        return url
    }
}

struct LaunchSpec {
    let app: URL
    let data: URL?
    var executable: URL { app.appendingPathComponent("Contents/MacOS/Claude") }
    var arguments: [String] { data.map { ["--user-data-dir=\($0.path)"] } ?? [] }

    func ownsExecutable(_ path: String) -> Bool {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path == executable.resolvingSymlinksInPath().path
    }

    static func isHelperProcess(_ arguments: [String]) -> Bool {
        arguments.contains(where: { $0.hasPrefix("--type=") })
    }

    func matches(_ arguments: [String]) -> Bool {
        guard let first = arguments.first, ownsExecutable(first) else { return false }
        let flags = arguments.dropFirst().filter { $0.hasPrefix("--user-data-dir=") || $0 == "--user-data-dir" }
        guard !Self.isHelperProcess(arguments) else { return false }
        return data == nil ? flags.isEmpty : flags.count == 1 && flags.first == self.arguments.first
    }
}

enum ProcessArguments {
    static func decode(_ data: [UInt8]) throws -> [String] {
        guard data.count >= 5 else { throw ProfileError.message("Process details were incomplete.") }
        var count: Int32 = 0
        _ = withUnsafeMutableBytes(of: &count) { data.prefix(4).copyBytes(to: $0) }
        guard count > 0 && count < 16_384 else { throw ProfileError.message("Process argument count was invalid.") }
        var i = 4
        while i < data.count && data[i] != 0 { i += 1 }
        while i < data.count && data[i] == 0 { i += 1 }
        var arguments: [String] = []
        for _ in 0..<Int(count) {
            let start = i
            while i < data.count && data[i] != 0 { i += 1 }
            guard i < data.count, let value = String(bytes: data[start..<i], encoding: .utf8) else {
                throw ProfileError.message("Could not read complete process arguments.")
            }
            arguments.append(value)
            i += 1
        }
        return arguments
    }

    static func read(_ pid: pid_t) throws -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0, size <= 8_388_608 else {
            throw ProfileError.message("Could not inspect a running Claude instance. Try again after it finishes opening or closing.")
        }
        var data = [UInt8](repeating: 0, count: size)
        let result = data.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { throw ProfileError.message("Could not inspect a running Claude instance.") }
        return try decode(Array(data.prefix(size)))
    }
}
