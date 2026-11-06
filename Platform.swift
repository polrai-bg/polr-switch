import AppKit

@MainActor
enum ClaudeLauncher {
    static let app = URL(fileURLWithPath: "/Applications/Claude.app", isDirectory: true)

    static var version: String { Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Not installed" }

    static func spec(_ profile: Profile, store: ProfileStore) -> LaunchSpec {
        let copy = store.root.appendingPathComponent("apps/\(profile.id.uuidString)/Claude.app", isDirectory: true)
        return LaunchSpec(app: profile.isMain ? app : copy, data: profile.isMain ? nil : store.dataURL(profile.id))
    }

    static func running(_ spec: LaunchSpec) throws -> NSRunningApplication? {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            guard !app.isTerminated else { continue }
            do {
                if spec.matches(try ProcessArguments.read(app.processIdentifier)) { return app }
            } catch {
                if !app.isTerminated { throw error }
            }
        }
        return nil
    }

    private static func prepareCopy(_ target: URL, store: ProfileStore) throws {
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        try store.privateDirectory(parent)
        guard target.standardizedFileURL.path == target.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw ProfileError.message("The profile app must not be a symbolic link.")
        }
        if Bundle(url: target)?.bundleIdentifier == "com.anthropic.claudefordesktop",
           Bundle(url: target)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version { return }
        let stage = parent.appendingPathComponent("staging-\(UUID().uuidString).app")
        let previous = parent.appendingPathComponent("Previous Claude.app")
        defer { try? fm.removeItem(at: stage) }
        try runLocalTool("/bin/cp", ["-cR", app.path, stage.path])
        try runLocalTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", stage.path])
        if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
        let replacing = fm.fileExists(atPath: target.path)
        if replacing { try fm.moveItem(at: target, to: previous) }
        do { try fm.moveItem(at: stage, to: target) }
        catch {
            if replacing { try fm.moveItem(at: previous, to: target) }
            throw error
        }
    }

    static func open(_ id: UUID, store: ProfileStore) async throws -> pid_t {
        let profile = try store.profile(id)
        if !profile.isMain { _ = try store.prepare(id) }
        guard Bundle(url: app)?.bundleIdentifier == "com.anthropic.claudefordesktop",
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/Claude").path) else {
            throw ProfileError.message("Install Claude Desktop in Applications before opening a profile.")
        }
        let spec = spec(profile, store: store)
        for candidate in NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            guard !candidate.isTerminated, candidate.executableURL?.path == spec.executable.path else { continue }
            let arguments = try ProcessArguments.read(candidate.processIdentifier)
            guard spec.matches(arguments) else {
                throw ProfileError.message("A Claude window at this app path is using another profile. Quit that window, then reopen it through its named launcher.")
            }
        }
        let existing = try running(spec)
        if !profile.isMain && existing == nil {
            let legacy = LaunchSpec(app: app, data: store.dataURL(id))
            guard try running(legacy) == nil else {
                throw ProfileError.message("Quit this profile's older Claude window before opening its updated app copy. Its data is preserved.")
            }
            try prepareCopy(spec.app, store: store)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = false
        config.allowsRunningApplicationSubstitution = false
        config.arguments = spec.arguments
        let opened = try await NSWorkspace.shared.openApplication(at: spec.app, configuration: config)
        if let existing, opened.processIdentifier != existing.processIdentifier {
            throw ProfileError.message("macOS selected a different Claude process. Close that extra window and reopen the intended profile from this manager.")
        }
        // shortcut: verify launch identity, not account identity; account checks remain part of setup.
        for _ in 0..<20 {
            if opened.isTerminated { break }
            if let args = try? ProcessArguments.read(opened.processIdentifier), spec.matches(args) {
                return opened.processIdentifier
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw ProfileError.message("This Claude window did not use the intended profile. Quit that window and reopen it using the manager or its named launcher.")
    }

}

@MainActor
enum ProfileArtwork {
    static func color(_ name: String) -> NSColor {
        switch name {
        case "Orange": return .systemOrange
        case "Green": return .systemGreen
        case "Purple": return .systemPurple
        default: return .systemBlue
        }
    }

    static func png(label: String, color: String, size: Int) -> Data? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let s = CGFloat(size)
        Self.color(color).setFill()
        NSBezierPath(roundedRect: NSRect(x: s * 0.08, y: s * 0.08, width: s * 0.84, height: s * 0.84),
                     xRadius: s * 0.19, yRadius: s * 0.19).fill()
        let text = String(label.prefix(1)).uppercased() as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: s * 0.48, weight: .semibold),
                                                   .foregroundColor: NSColor.white]
        let measured = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (s - measured.width) / 2, y: (s - measured.height) / 2), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

}

@MainActor
enum LauncherBundle {
    static func export(_ profile: Profile, to destination: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path), let source = Bundle.main.executableURL else {
            throw ProfileError.message("Choose a new launcher filename. Existing files are never overwritten.")
        }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".profile-\(UUID().uuidString).app")
        defer { try? fm.removeItem(at: stage) }
        let macos = stage.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resources = stage.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: macos.appendingPathComponent("Loftlane"))
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.polrai.claudeprofiles.profile.\(profile.id.uuidString.lowercased())",
            "CFBundleName": "Loftlane \(profile.name)", "CFBundleDisplayName": "Loftlane \(profile.name)",
            "CFBundleExecutable": "Loftlane", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "2",
            "LSMinimumSystemVersion": "15.0", "LSUIElement": true, "NSHighResolutionCapable": true,
            "ProfileID": profile.id.uuidString, "CFBundleIconFile": "Profile.icns"
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: stage.appendingPathComponent("Contents/Info.plist"))
        let iconset = stage.appendingPathComponent("Profile.iconset", isDirectory: true)
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                guard let png = ProfileArtwork.png(label: profile.name, color: profile.color, size: size * scale) else {
                    throw ProfileError.message("Could not create the profile icon.")
                }
                let suffix = scale == 2 ? "@2x" : ""
                try png.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            }
        }
        try runLocalTool("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("Profile.icns").path])
        try fm.removeItem(at: iconset)
        try runLocalTool("/usr/bin/codesign", ["--force", "--sign", "-", stage.path])
        try runLocalTool("/usr/bin/codesign", ["--verify", "--strict", stage.path])
        try fm.moveItem(at: stage, to: destination)
    }

}

func runLocalTool(_ path: String, _ args: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw ProfileError.message("Could not prepare the launcher (\(URL(fileURLWithPath: path).lastPathComponent)). No existing app was changed.")
        }
    }
