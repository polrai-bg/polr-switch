import AppKit
import Darwin

@MainActor
enum ClaudeLauncher {
    static let app = URL(fileURLWithPath: "/Applications/Claude.app", isDirectory: true)

    static var version: String { Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Not installed" }

    static func spec(_ profile: Profile, store: ProfileStore) -> LaunchSpec {
        let copy = store.root.appendingPathComponent("apps/\(profile.id.uuidString)/Claude.app", isDirectory: true)
        return LaunchSpec(app: profile.isMain ? app : copy, data: profile.isMain ? nil : store.dataURL(profile.id))
    }

    private static func isLiveProcess(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated else { return false }
        let pid = app.processIdentifier
        guard pid > 0 else { return false }
        return Darwin.kill(pid, 0) == 0 || errno != ESRCH
    }

    static func running(_ spec: LaunchSpec) throws -> NSRunningApplication? {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            guard isLiveProcess(app), let path = app.executableURL?.path, spec.ownsExecutable(path) else { continue }
            do {
                if spec.matches(try ProcessArguments.read(app.processIdentifier)) { return app }
            } catch {
                if isLiveProcess(app) { throw error }
            }
        }
        return nil
    }

    private static func prepareCopy(_ target: URL, store: ProfileStore) async throws {
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        try store.privateDirectory(parent)
        try store.rejectSymlink(target, message: "The profile app must not be a symbolic link.")
        if Bundle(url: target)?.bundleIdentifier == "com.anthropic.claudefordesktop",
           Bundle(url: target)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version { return }
        let stage = parent.appendingPathComponent("staging-\(UUID().uuidString).app")
        let previous = parent.appendingPathComponent("Previous Claude.app")
        defer { try? fm.removeItem(at: stage) }
        try await runLocalTool("/bin/cp", ["-cR", app.path, stage.path])
        try await runLocalTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", stage.path])
        if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
        let replacing = fm.fileExists(atPath: target.path)
        if replacing { try fm.moveItem(at: target, to: previous) }
        do { try fm.moveItem(at: stage, to: target) }
        catch {
            if replacing { try? fm.moveItem(at: previous, to: target) }
            throw error
        }
        if replacing { try? fm.removeItem(at: previous) }
    }

    static func open(_ id: UUID, store: ProfileStore) async throws -> pid_t {
        let lease = try store.operationLease(id)
        defer { lease.release() }
        let profile = try store.profile(id)
        if !profile.isMain { _ = try store.prepare(id) }
        guard Bundle(url: app)?.bundleIdentifier == "com.anthropic.claudefordesktop",
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/Claude").path) else {
            throw ProfileError.message("Install Claude Desktop in Applications before opening a profile.")
        }
        let spec = spec(profile, store: store)
        var existing: NSRunningApplication?
        for candidate in NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            guard isLiveProcess(candidate), let path = candidate.executableURL?.path, spec.ownsExecutable(path) else { continue }
            let arguments: [String]
            do {
                arguments = try ProcessArguments.read(candidate.processIdentifier)
            } catch {
                if !isLiveProcess(candidate) { continue }
                throw error
            }
            if LaunchSpec.isHelperProcess(arguments) { continue }
            guard spec.matches(arguments) else {
                throw ProfileError.message("A Claude window at this app path is using another profile. Quit that window, then reopen it through its named launcher.")
            }
            existing = existing ?? candidate
        }
        if !profile.isMain && existing == nil {
            let legacy = LaunchSpec(app: app, data: store.dataURL(id))
            guard try running(legacy) == nil else {
                throw ProfileError.message("Quit this profile's older Claude window before opening its updated app copy. Its data is preserved.")
            }
            try await prepareCopy(spec.app, store: store)
        }
        try ProfileArtwork.apply(to: profile, store: store)
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
            if !isLiveProcess(opened) { break }
            if let args = try? ProcessArguments.read(opened.processIdentifier), spec.matches(args) {
                return opened.processIdentifier
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw ProfileError.message("This Claude window did not use the intended profile. Quit that window and reopen it using the manager or its named launcher.")
    }

    static func setArchived(_ id: UUID, _ archived: Bool, store: ProfileStore) throws {
        let lease = try store.operationLease(id)
        defer { lease.release() }
        guard let profile = try store.load().first(where: { $0.id == id }) else {
            throw ProfileError.message("Profile not found.")
        }
        if archived {
            let legacy = LaunchSpec(app: app, data: profile.isMain ? nil : store.dataURL(id))
            guard try running(spec(profile, store: store)) == nil, try running(legacy) == nil else {
                throw ProfileError.message("Quit this profile's Claude window before archiving it. Its data and saved login will be kept.")
            }
        }
        try store.setArchived(id, archived)
    }
}

@MainActor
enum ProfileArtwork {
    static func apply(to profile: Profile, store: ProfileStore) throws {
        guard !profile.isMain else { return }
        let app = ClaudeLauncher.spec(profile, store: store).app
        try store.rejectSymlink(app.appendingPathComponent("Icon\r"))
        guard let data = png(profile: profile, store: store, size: 512),
              let image = NSImage(data: data) else {
            throw ProfileError.message("Could not render this profile's Dock icon.")
        }
        guard NSWorkspace.shared.setIcon(image, forFile: app.path, options: []) else {
            throw ProfileError.message("Could not apply this profile's Dock icon. Check the profile app's folder permissions, then try again.")
        }
        // Finder metadata keeps Claude's signed Contents intact; never re-sign Claude.
    }

    static func color(_ color: ProfileColor) -> NSColor {
        switch color {
        case .orange: return .systemOrange
        case .green: return .systemGreen
        case .purple: return .systemPurple
        case .blue: return .systemBlue
        }
    }

    static func normalizedBackgroundPNG(from url: URL) throws -> Data {
        guard let source = NSImage(contentsOf: url),
              source.size.width > 0, source.size.height > 0 else {
            throw ProfileError.message("Could not read that image file. Choose a PNG, JPEG, or HEIC image.")
        }
        let maxRep = source.representations.max { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
        let srcW = (maxRep?.pixelsWide ?? 0) > 0 ? CGFloat(maxRep!.pixelsWide) : source.size.width
        let srcH = (maxRep?.pixelsHigh ?? 0) > 0 ? CGFloat(maxRep!.pixelsHigh) : source.size.height
        let side = min(1024, max(1, Int(min(srcW, srcH).rounded())))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw ProfileError.message("Could not read that image file. Choose a PNG, JPEG, or HEIC image.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let s = CGFloat(side)
        let imgScale = max(s / source.size.width, s / source.size.height)
        let drawW = source.size.width * imgScale
        let drawH = source.size.height * imgScale
        let drawRect = NSRect(x: (s - drawW) / 2, y: (s - drawH) / 2, width: drawW, height: drawH)
        source.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw ProfileError.message("Could not read that image file. Choose a PNG, JPEG, or HEIC image.")
        }
        return pngData
    }

    static func loadBackgroundImage(for profile: Profile, store: ProfileStore) -> NSImage? {
        guard profile.iconImageToken != nil, let data = store.loadIconImageData(profile.id) else {
            return nil
        }
        return NSImage(data: data)
    }

    static func png(profile: Profile, store: ProfileStore, size: Int) -> Data? {
        png(
            text: profile.resolvedIconText,
            position: profile.resolvedIconPosition,
            color: profile.color,
            backgroundImage: loadBackgroundImage(for: profile, store: store),
            size: size
        )
    }

    static func png(label: String, color: ProfileColor, size: Int) -> Data? {
        png(
            text: String(label.prefix(1)).uppercased(),
            position: .center,
            color: color,
            backgroundImage: nil,
            size: size
        )
    }

    static func image(text: String, position: IconTextPosition = .center, color: ProfileColor,
                      backgroundImage: NSImage? = nil, size: Int) -> NSImage? {
        guard let data = png(text: text, position: position, color: color, backgroundImage: backgroundImage, size: size) else {
            return nil
        }
        return NSImage(data: data)
    }

    static func png(text: String, position: IconTextPosition = .center, color: ProfileColor,
                    backgroundImage: NSImage? = nil, size: Int) -> Data? {
        guard size > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        let s = CGFloat(size)
        let rect = NSRect(x: s * 0.08, y: s * 0.08, width: s * 0.84, height: s * 0.84)
        let radius = s * 0.19
        let clipPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        clipPath.addClip()
        Self.color(color).setFill()
        clipPath.fill()

        if let backgroundImage, backgroundImage.size.width > 0, backgroundImage.size.height > 0 {
            let imgScale = max(rect.width / backgroundImage.size.width, rect.height / backgroundImage.size.height)
            let drawW = backgroundImage.size.width * imgScale
            let drawH = backgroundImage.size.height * imgScale
            let drawRect = NSRect(x: rect.midX - drawW / 2, y: rect.midY - drawH / 2, width: drawW, height: drawH)
            backgroundImage.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        NSGraphicsContext.restoreGraphicsState()

        let borderWidth = max(1, s * 0.01)
        let borderPath = NSBezierPath(
            roundedRect: rect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
            xRadius: max(0, radius - borderWidth / 2),
            yRadius: max(0, radius - borderWidth / 2)
        )
        borderPath.lineWidth = borderWidth
        NSColor.white.withAlphaComponent(0.18).setStroke()
        borderPath.stroke()

        if !text.isEmpty {
            let baseRatio: CGFloat
            switch text.count {
            case 1: baseRatio = 0.48
            case 2: baseRatio = 0.36
            case 3: baseRatio = 0.28
            case 4: baseRatio = 0.23
            case 5: baseRatio = 0.19
            default: baseRatio = 0.165
            }
            var fontSize = s * baseRatio
            let usableRect = rect.insetBy(dx: rect.width * 0.09, dy: rect.height * 0.09)
            let padX = backgroundImage != nil ? s * 0.045 : 0
            let padY = backgroundImage != nil ? s * 0.025 : 0
            let maxTextWidth = max(1, usableRect.width - padX * 2)
            let maxTextHeight = max(1, usableRect.height - padY * 2)

            var attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            var measured = (text as NSString).size(withAttributes: attrs)
            if measured.width > maxTextWidth || measured.height > maxTextHeight {
                let factor = min(maxTextWidth / max(1, measured.width), maxTextHeight / max(1, measured.height))
                fontSize = max(1, fontSize * factor)
                attrs[.font] = NSFont.systemFont(ofSize: fontSize, weight: .bold)
                measured = (text as NSString).size(withAttributes: attrs)
            }

            let boxWidth = measured.width + padX * 2
            let boxHeight = measured.height + padY * 2

            let boxX: CGFloat
            switch position {
            case .topLeft, .left, .bottomLeft:
                boxX = usableRect.minX
            case .top, .center, .bottom:
                boxX = usableRect.midX - boxWidth / 2
            case .topRight, .right, .bottomRight:
                boxX = usableRect.maxX - boxWidth
            }

            // AppKit NSBitmapImageRep uses a bottom-left origin (y = 0 at bottom, y = size at top).
            let boxY: CGFloat
            switch position {
            case .topLeft, .top, .topRight:
                boxY = usableRect.maxY - boxHeight
            case .left, .center, .right:
                boxY = usableRect.midY - boxHeight / 2
            case .bottomLeft, .bottom, .bottomRight:
                boxY = usableRect.minY
            }

            if backgroundImage != nil {
                let boxRect = NSRect(x: boxX, y: boxY, width: boxWidth, height: boxHeight)
                let pillRadius = min(boxHeight / 2, max(2, s * 0.045))
                NSColor.black.withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: boxRect, xRadius: pillRadius, yRadius: pillRadius).fill()
            }

            (text as NSString).draw(at: NSPoint(x: boxX + padX, y: boxY + padY), withAttributes: attrs)
        }

        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}

@MainActor
enum LauncherBundle {
    static func canReplace(at destination: URL) -> Bool {
        var info = stat()
        if Darwin.lstat(destination.path, &info) != 0 { return errno == ENOENT }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        let plistURL = destination.appendingPathComponent("Contents/Info.plist")
        guard Darwin.lstat(plistURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let profileID = plist["ProfileID"] as? String,
              UUID(uuidString: profileID) != nil else {
            return false
        }
        return true
    }

    static func export(_ profile: Profile, to destination: URL,
                       store: ProfileStore = .standard,
                       executableURL: URL? = Bundle.main.executableURL,
                       info: [String: Any]? = Bundle.main.infoDictionary) async throws {
        let fm = FileManager.default
        guard canReplace(at: destination), let source = executableURL else {
            throw ProfileError.message("Choose a new launcher filename. Existing files are never overwritten.")
        }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".profile-\(UUID().uuidString).app")
        defer { try? fm.removeItem(at: stage) }
        let macos = stage.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resources = stage.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let metadata = try AppMetadata(info: info ?? [:])
        try fm.copyItem(at: source, to: macos.appendingPathComponent(metadata.executable))
        let plist = metadata.launcherInfo(profile)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: stage.appendingPathComponent("Contents/Info.plist"))
        let iconset = stage.appendingPathComponent("Profile.iconset", isDirectory: true)
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                guard let png = ProfileArtwork.png(profile: profile, store: store, size: size * scale) else {
                    throw ProfileError.message("Could not create the profile icon.")
                }
                let suffix = scale == 2 ? "@2x" : ""
                try png.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            }
        }
        try await runLocalTool("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("Profile.icns").path])
        try fm.removeItem(at: iconset)
        try await runLocalTool("/usr/bin/codesign", ["--force", "--sign", "-", stage.path])
        try await runLocalTool("/usr/bin/codesign", ["--verify", "--strict", stage.path])
        var existingInfo = stat()
        if Darwin.lstat(destination.path, &existingInfo) == 0 {
            guard canReplace(at: destination) else {
                throw ProfileError.message("Choose a new launcher filename. Existing files are never overwritten.")
            }
            _ = try fm.replaceItemAt(destination, withItemAt: stage)
        } else {
            try fm.moveItem(at: stage, to: destination)
        }
    }

}
