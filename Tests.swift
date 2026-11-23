import Foundation
import AppKit
import Darwin

@main
struct Tests {
    static func check(_ condition: Bool, line: UInt = #line) { precondition(condition, "Check failed at line \(line)") }
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
        check(LaunchSpec.isHelperProcess([spec.executable.path, "--type=renderer"]))
        check(!LaunchSpec.isHelperProcess([spec.executable.path] + spec.arguments))
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
        let danglingAlias = root.appendingPathComponent("dangling-alias")
        try fm.createSymbolicLink(at: danglingAlias, withDestinationURL: root.appendingPathComponent("missing-target"))
        rejects { try store.privateDirectory(danglingAlias) }
        rejects { try store.privateDirectory(danglingAlias.appendingPathComponent("nested")) }
        rejects { try ProfileStore(root: alias).seed() }
        let tmpRoot = URL(fileURLWithPath: "/tmp").appendingPathComponent("claude-profiles-tmp-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmpRoot) }
        let tmpStore = ProfileStore(root: tmpRoot)
        try tmpStore.seed()
        check(try tmpStore.load().count == 2)
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
        let iconProfile = try store.profile(id)
        let iconApp = ClaudeLauncher.spec(iconProfile, store: store).app
        try fm.createDirectory(at: iconApp, withIntermediateDirectories: true)
        let iconTarget = root.appendingPathComponent("protected-icon")
        try Data("untouched".utf8).write(to: iconTarget)
        try fm.createSymbolicLink(at: iconApp.appendingPathComponent("Icon\r"), withDestinationURL: iconTarget)
        rejects { try ProfileArtwork.apply(to: iconProfile, store: store) }
        check(try Data(contentsOf: iconTarget) == Data("untouched".utf8))
        print("PASS: custom Dock icons reject symlinked icon metadata")

        let renamedProfile = try store.profile(id)
        let launcher = metadata.launcherInfo(renamedProfile)
        for key in ["CFBundleName", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion"] {
            check(launcher[key] as? String == plist[key] as? String)
        }
        check(launcher["CFBundleIdentifier"] as? String != plist["CFBundleIdentifier"] as? String)
        check(launcher["ProfileID"] as? String == id.uuidString)
        check(launcher["CFBundleDisplayName"] as? String == "\(metadata.name) Renamed")
        rejects { _ = try AppMetadata(info: [:]) }
        let exportedURL = root.appendingPathComponent("POLR Switch Renamed.app")
        let binaryURL = URL(fileURLWithPath: CommandLine.arguments[0])
        try await LauncherBundle.export(renamedProfile, to: exportedURL, executableURL: binaryURL, info: plist)
        check(LauncherBundle.canReplace(at: exportedURL))
        var updatedProfile = renamedProfile
        updatedProfile.name = "Renamed Again"
        try await LauncherBundle.export(updatedProfile, to: exportedURL, executableURL: binaryURL, info: plist)
        let exportedPlist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: exportedURL.appendingPathComponent("Contents/Info.plist")),
            options: [], format: nil) as! [String: Any]
        check(exportedPlist["CFBundleDisplayName"] as? String == "\(metadata.name) Renamed Again")
        check(!LauncherBundle.canReplace(at: fixtureApp))
        check(!LauncherBundle.canReplace(at: fixtureAlias))
        do {
            try await LauncherBundle.export(updatedProfile, to: fixtureApp, executableURL: binaryURL, info: plist)
            fatalError("Non-launcher bundle should not be overwritten")
        } catch { check(error.localizedDescription.contains("never overwritten")) }
        try await runLocalTool("/usr/bin/true", [])
        do {
            try await runLocalTool("/usr/bin/false", [])
            fatalError("Failed subprocess should be reported")
        } catch { check(error.localizedDescription.contains("exit 1")) }

        // Icon customization tests
        check(try checkedIconText(nil) == nil)
        check(try checkedIconText("") == "")
        check(try checkedIconText("   ") == "")
        check(try checkedIconText("A") == "A")
        check(try checkedIconText("  POLR99  ") == "POLR99")
        rejects { _ = try checkedIconText("1234567") }
        rejects { _ = try checkedIconText("a\nb") }

        let legacyID = UUID()
        let legacyJSON = """
        {"version":2,"profiles":[{"id":"\(legacyID.uuidString)","name":"Alpha","color":"Blue","archived":false}]}
        """
        let decodedLegacy = try JSONDecoder().decode(Registry.self, from: Data(legacyJSON.utf8))
        check(decodedLegacy.profiles.count == 1)
        check(decodedLegacy.profiles[0].iconText == nil)
        check(decodedLegacy.profiles[0].iconTextPosition == nil)
        check(decodedLegacy.profiles[0].iconImageToken == nil)
        check(decodedLegacy.profiles[0].resolvedIconText == "A")
        check(decodedLegacy.profiles[0].resolvedIconPosition == .center)

        func solidPNG(width: Int, height: Int, color: NSColor) -> Data {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let ctx = NSGraphicsContext(bitmapImageRep: rep)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            color.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            NSGraphicsContext.restoreGraphicsState()
            return rep.representation(using: .png, properties: [:])!
        }

        let wideImageURL = root.appendingPathComponent("wide-logo.png")
        try solidPNG(width: 2400, height: 1200, color: .systemRed).write(to: wideImageURL)
        let normalizedData = try ProfileArtwork.normalizedBackgroundPNG(from: wideImageURL)
        let normalizedRep = NSBitmapImageRep(data: normalizedData)!
        check(normalizedRep.pixelsWide == 1024 && normalizedRep.pixelsHigh == 1024)

        let customID = try store.save(
            name: "Custom Icon",
            color: .blue,
            icon: ProfileIconUpdate(text: "POLR99", position: .topRight, image: .set(normalizedData))
        )
        let customProfile = try store.profile(customID)
        check(customProfile.iconText == "POLR99")
        check(customProfile.iconTextPosition == .topRight)
        check(customProfile.resolvedIconText == "POLR99")
        check(customProfile.resolvedIconPosition == .topRight)
        check(customProfile.iconImageToken != nil)
        check(store.loadIconImageData(customID) == normalizedData)

        let savedToken = customProfile.iconImageToken
        _ = try store.save(id: customID, name: "Custom Icon Updated", color: .purple)
        let preserved = try store.profile(customID)
        check(preserved.iconText == "POLR99")
        check(preserved.iconTextPosition == .topRight)
        check(preserved.iconImageToken == savedToken)

        _ = try store.save(
            id: customID,
            name: "Custom Icon Updated",
            color: .purple,
            icon: ProfileIconUpdate(text: "", position: .center, image: .remove)
        )
        let cleared = try store.profile(customID)
        check(cleared.iconText == "")
        check(cleared.resolvedIconText == "")
        check(cleared.iconTextPosition == nil)
        check(cleared.iconImageToken == nil)
        check(!fm.fileExists(atPath: store.iconImageURL(customID).path))
        check(store.loadIconImageData(customID) == nil)

        try fm.createSymbolicLink(at: store.iconImageURL(customID), withDestinationURL: iconTarget)
        rejects {
            _ = try store.save(
                id: customID,
                name: "Custom Icon Updated",
                color: .purple,
                icon: ProfileIconUpdate(text: nil, position: .center, image: .set(normalizedData))
            )
        }
        rejects {
            _ = try store.save(
                id: customID,
                name: "Custom Icon Updated",
                color: .purple,
                icon: ProfileIconUpdate(text: nil, position: .center, image: .remove)
            )
        }
        check(store.loadIconImageData(customID) == nil)
        check(try Data(contentsOf: iconTarget) == Data("untouched".utf8))
        try fm.removeItem(at: store.iconImageURL(customID))

        func whitePixelCounts(in pngData: Data) -> (upper: Int, lower: Int) {
            let rep = NSBitmapImageRep(data: pngData)!
            var upper = 0
            var lower = 0
            let midY = rep.pixelsHigh / 2
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if c.alphaComponent > 0.85 && c.redComponent > 0.85 && c.greenComponent > 0.85 && c.blueComponent > 0.85 {
                        if y < midY { upper += 1 } else { lower += 1 }
                    }
                }
            }
            return (upper, lower)
        }

        let topPNG = ProfileArtwork.png(text: "TOP", position: .top, color: .blue, size: 256)!
        let topCounts = whitePixelCounts(in: topPNG)
        check(topCounts.upper > 0 && topCounts.lower == 0)

        let bottomPNG = ProfileArtwork.png(text: "BOT", position: .bottom, color: .blue, size: 256)!
        let bottomCounts = whitePixelCounts(in: bottomPNG)
        check(bottomCounts.lower > 0 && bottomCounts.upper == 0)

        let emptyPNG = ProfileArtwork.png(text: "", position: .center, color: .blue, size: 256)!
        let emptyCounts = whitePixelCounts(in: emptyPNG)
        check(emptyCounts.upper == 0 && emptyCounts.lower == 0)

        let wideTextPNG = ProfileArtwork.png(text: "WWWWWW", position: .bottomRight, color: .orange, size: 256)!
        let wideCounts = whitePixelCounts(in: wideTextPNG)
        check(wideCounts.lower > 0 && wideCounts.upper == 0)

        let redBG = NSImage(data: solidPNG(width: 256, height: 256, color: .systemRed))!
        let bgPNG = ProfileArtwork.png(text: "", position: .center, color: .blue, backgroundImage: redBG, size: 256)!
        let bgRep = NSBitmapImageRep(data: bgPNG)!
        let centerColor = bgRep.colorAt(x: 128, y: 128)!.usingColorSpace(.deviceRGB)!
        check(centerColor.redComponent > 0.7 && centerColor.blueComponent < 0.3)

        let exportCustomID = try store.save(
            name: "Launcher Custom",
            color: .green,
            icon: ProfileIconUpdate(text: "POLR", position: .bottomLeft, image: .set(normalizedData))
        )
        let exportCustomProfile = try store.profile(exportCustomID)
        let customLauncherURL = root.appendingPathComponent("POLR Switch Launcher Custom.app")
        try await LauncherBundle.export(exportCustomProfile, to: customLauncherURL, store: store, executableURL: binaryURL, info: plist)
        let icnsURL = customLauncherURL.appendingPathComponent("Contents/Resources/Profile.icns")
        check(fm.fileExists(atPath: icnsURL.path))
        let icnsAttrs = try fm.attributesOfItem(atPath: icnsURL.path)
        check(((icnsAttrs[.size] as? NSNumber)?.intValue ?? 0) > 0)

        print("PASS: custom icon text, 9-position placement, background images, normalization, symlink rejection, and launcher export")
        print("PASS: cross-process lifecycle exclusion, archive/open coordination, metadata inheritance, and async tool errors")
        print("PASS: registry integrity, stable IDs, names, archive/restore, exact launch matching, process parsing, locking, and symlink rejection")
    }
}
