import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class ProfilesModel: ObservableObject {
    static let shared = ProfilesModel()
    let store = ProfileStore.standard
    @Published var profiles: [Profile] = []
    @Published var selected: UUID?
    @Published var running: Set<UUID> = []
    @Published var opening: Set<UUID> = []
    @Published var exporting: Set<UUID> = []
    @Published var error: String?
    @Published var statusError: String?
    @Published var available = false
    @Published var showArchived = false {
        didSet { ensureValidSelection() }
    }
    @Published var version = ClaudeLauncher.version
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    var visibleProfiles: [Profile] {
        profiles.filter { showArchived || !$0.archived }
    }

    private func ensureValidSelection() {
        if !visibleProfiles.contains(where: { $0.id == selected }) {
            selected = visibleProfiles.first?.id
        }
    }

    func start() {
        do { try store.seed(); try reload(); available = true }
        catch { self.error = error.localizedDescription }
        refresh()
        guard timer == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in self.refresh() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func reload() throws {
        profiles = try store.load()
        ensureValidSelection()
    }

    func refresh() {
        version = ClaudeLauncher.version
        do {
            var found = Set<UUID>()
            for p in profiles {
                if try ClaudeLauncher.running(ClaudeLauncher.spec(p, store: store)) != nil {
                    found.insert(p.id)
                }
            }
            running = found
            statusError = nil
        } catch { statusError = error.localizedDescription }
    }

    func canOpen(_ profile: Profile) -> Bool {
        available && !profile.archived && !opening.contains(profile.id)
    }

    func open(_ profile: Profile) {
        guard canOpen(profile) else { return }
        opening.insert(profile.id)
        Task {
            defer { opening.remove(profile.id); refresh() }
            do { _ = try await ClaudeLauncher.open(profile.id, store: store) }
            catch { self.error = error.localizedDescription }
        }
    }

    func save(_ profile: Profile?, name: String, color: ProfileColor) -> Bool {
        do {
            selected = try store.save(id: profile?.id, name: name, color: color)
            try reload()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func archive(_ profile: Profile) {
        do {
            try ClaudeLauncher.setArchived(profile.id, !profile.archived, store: store)
            try reload()
        } catch { self.error = error.localizedDescription }
    }

    func reveal(_ profile: Profile) {
        do {
            let url = profile.isMain ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude") : try store.prepare(profile.id)
            NSWorkspace.shared.open(url)
        }
        catch { self.error = error.localizedDescription }
    }

    func export(_ profile: Profile) {
        guard !exporting.contains(profile.id) else { return }
        let panel = NSSavePanel()
        panel.title = "Save profile launcher"
        panel.prompt = "Create launcher"
        panel.nameFieldStringValue = "\(AppMetadata.displayName) \(profile.name.replacingOccurrences(of: "/", with: "-" )).app"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting.insert(profile.id)
        Task {
            defer { exporting.remove(profile.id) }
            do {
                try await LauncherBundle.export(profile, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let text = Bundle.main.object(forInfoDictionaryKey: "ProfileID") as? String {
            Task {
                do {
                    guard let id = UUID(uuidString: text) else { throw ProfileError.message("This launcher has an invalid profile ID.") }
                    _ = try await ClaudeLauncher.open(id, store: .standard)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Could not open Claude profile"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
                NSApp.terminate(nil)
            }
        } else {
            ProfilesModel.shared.start()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@main
struct POLRSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = ProfilesModel.shared
    private let isLauncher = Bundle.main.object(forInfoDictionaryKey: "ProfileID") != nil

    var body: some Scene {
        Window(AppMetadata.displayName, id: "profiles") {
            if !isLauncher { ProfilesView(model: model) }
        }
        .defaultSize(width: 920, height: 740)
        .defaultLaunchBehavior(isLauncher ? .suppressed : .presented)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
        MenuBarExtra(AppMetadata.displayName, systemImage: "square.stack.3d.up", isInserted: .constant(!isLauncher)) {
            ForEach(model.profiles.filter { !$0.archived }) { profile in
                Button { model.open(profile) } label: {
                    Label("\(model.running.contains(profile.id) ? "Focus" : "Open") \(profile.name)",
                          systemImage: model.running.contains(profile.id) ? "circle.fill" : "circle")
                }
                .disabled(!model.canOpen(profile))
            }
            if let issue = model.statusError ?? (!model.available ? model.error : nil) {
                Divider()
                Text(issue)
                Button("Retry status check") { model.refresh() }
            }
            Divider()
            ShowManagerButton()
            Button("Quit \(AppMetadata.displayName)") { NSApp.terminate(nil) }
        }
    }
}

struct ShowManagerButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Show profiles") { openWindow(id: "profiles"); NSApp.activate(ignoringOtherApps: true) }
    }
}

struct ProfilesView: View {
    @ObservedObject var model: ProfilesModel
    @State private var editing = false
    @State private var editingProfile: Profile?
    @State private var archiveCandidate: Profile?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                        .resizable().frame(width: 36, height: 36)
                    Text(AppMetadata.displayName).font(.system(size: 17, weight: .semibold))
                    Spacer(minLength: 0)
                }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 28)
                Text("PROFILES").font(.system(size: 10, weight: .semibold)).tracking(1.8)
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.bottom, 8)
                List(selection: $model.selected) {
                    ForEach(model.visibleProfiles) { profile in
                        HStack(spacing: 12) {
                            ProfileBadge(profile: profile, size: 36)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                                Text(profile.archived ? "Archived" : profile.isMain ? "Main Claude" : model.running.contains(profile.id) ? "Running" : "Closed")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if !profile.archived && model.running.contains(profile.id) {
                                Circle().fill(.green).frame(width: 6, height: 6)
                                    .accessibilityLabel("Running")
                            }
                        }.padding(.vertical, 8).tag(profile.id)
                    }
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 16) {
                    Divider()
                    Button { editingProfile = nil; editing = true } label: {
                        Label("Add profile", systemImage: "plus").frame(maxWidth: .infinity)
                    }.controlSize(.large).disabled(!model.available)
                    Toggle("Show archived", isOn: $model.showArchived).font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(20)
            }.navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            if let profile = model.visibleProfiles.first(where: { $0.id == model.selected }) {
                detail(profile)
            } else {
                ContentUnavailableView("Your Claude profiles", systemImage: "square.stack.3d.up",
                                       description: Text("Add a profile to keep another account signed in."))
            }
        }
        .frame(minWidth: 820, minHeight: 640)
        .sheet(isPresented: $editing) { ProfileEditor(model: model, profile: editingProfile).id(editingProfile?.id) }
        .alert("Could not complete this action", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("Archive this profile? Its data and saved login will be kept.",
                            isPresented: Binding(get: { archiveCandidate != nil }, set: { if !$0 { archiveCandidate = nil } }), titleVisibility: .visible) {
            Button("Archive profile") { if let p = archiveCandidate { model.archive(p) }; archiveCandidate = nil }
        }
    }

    private func detail(_ profile: Profile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 18) {
                        ProfileBadge(profile: profile, size: 64)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(profile.name).font(.system(size: 30, weight: .semibold))
                            Label {
                                Text(profile.archived ? "Archived" : model.running.contains(profile.id) ? "Claude is running" : "Ready to open")
                            } icon: {
                                Image(systemName: profile.archived ? "archivebox" : model.running.contains(profile.id) ? "circle.fill" : "circle")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(!profile.archived && model.running.contains(profile.id) ? Color.green : Color.secondary)
                            }
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.primary.opacity(0.045), in: Capsule())
                        }
                        Spacer(minLength: 0)
                        Button { editingProfile = profile; editing = true } label: {
                            Image(systemName: "slider.horizontal.3").font(.system(size: 14, weight: .medium))
                                .frame(width: 32, height: 32)
                                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.borderless).foregroundStyle(.secondary)
                            .help("Edit profile name and color").accessibilityLabel("Edit profile")
                    }
                    if profile.archived {
                        Text("Your data is still here. Restore this profile to open it again.").foregroundStyle(.secondary)
                        Button("Restore profile") { model.archive(profile) }.buttonStyle(.borderedProminent).controlSize(.large)
                    } else {
                        HStack(spacing: 10) {
                            Button { model.open(profile) } label: {
                                Label(model.opening.contains(profile.id) ? "Opening..." : model.running.contains(profile.id) ? "Focus Claude" : "Open Claude", systemImage: "arrow.up.forward.app")
                                    .fontWeight(.semibold)
                            }.buttonStyle(.borderedProminent).controlSize(.large)
                                .disabled(!model.canOpen(profile))
                            Button(model.exporting.contains(profile.id) ? "Creating launcher..." : "Create launcher...") { model.export(profile) }
                                .controlSize(.large).disabled(model.exporting.contains(profile.id))
                        }
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.06)))

                if !profile.archived {
                    VStack(spacing: 0) {
                        ProfileInfoCard(
                            title: profile.isMain ? "Your regular Claude app" : "Set up this account",
                            symbol: "person.crop.circle",
                            text: profile.isMain ? "This opens or focuses your normal Claude instance, with your existing login, conversations, and Cowork sessions." : "Open Claude and sign in to the account you want here. Use an email code when offered. Browser sign-in may return to another open Claude window.",
                            note: profile.isMain ? "No separate data folder or new sign-in is needed." : "This profile starts fresh. Your existing Claude account stays in its original app.")
                        Divider().padding(.horizontal, 22)
                        ProfileInfoCard(
                            title: "Chat + Cowork preview", symbol: "checklist",
                            text: "Sign in to both profiles, run a small Cowork task in each using different folders, then quit and reopen each session.",
                            note: "Repeat this check for each new account. Local Chrome-extension pairing may be unavailable in separate profiles.")
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.06)))
                    HStack {
                        Button { model.reveal(profile) } label: { Label("Show data folder", systemImage: "folder") }
                        Spacer()
                        if !profile.isMain {
                            Button { archiveCandidate = profile } label: { Label("Archive...", systemImage: "archivebox") }
                        }
                    }.buttonStyle(.borderless).font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                if let statusError = model.statusError {
                    HStack {
                        Label(statusError, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                        Spacer()
                        Button("Retry") { model.refresh() }.controlSize(.small)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Divider().padding(.bottom, 4)
                    Text("Claude \(model.version) · \(AppMetadata.displayName) preview \(AppMetadata.displayVersion)")
                        .font(.system(size: 10, weight: .medium))
                    Text("Use these launchers to reopen profiles. Profile Dock icons use your chosen color. Quit and reopen a profile after changing its name or color. Recheck your accounts after Claude updates.")
                        .font(.system(size: 11)).lineSpacing(3)
                }.foregroundStyle(.secondary).padding(.top, 4)
            }.frame(maxWidth: 760).padding(28).frame(maxWidth: .infinity)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ProfileInfoCard: View {
    let title: String
    let symbol: String
    let text: String
    let note: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(.system(size: 13, weight: .semibold)).padding(.top, 2)
                Text(text).font(.system(size: 12)).lineSpacing(4)
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(22)
    }
}

struct ProfileBadge: View {
    let profile: Profile
    let size: CGFloat
    var body: some View {
        Text(String(profile.name.prefix(1)).uppercased())
            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(nsColor: ProfileArtwork.color(profile.color)).gradient, in: RoundedRectangle(cornerRadius: size * 0.28))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28).strokeBorder(.white.opacity(0.18)))
            .accessibilityHidden(true)
    }
}

struct ProfileEditor: View {
    @ObservedObject var model: ProfilesModel
    let profile: Profile?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color: ProfileColor = .blue
    @State private var error: String?

    init(model: ProfilesModel, profile: Profile?) {
        self.model = model
        self.profile = profile
        _name = State(initialValue: profile?.name ?? "")
        _color = State(initialValue: profile?.color ?? .blue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Label(profile == nil ? "New profile" : "Edit profile", systemImage: "person.crop.square")
                .font(.system(size: 22, weight: .semibold))
            VStack(alignment: .leading, spacing: 10) {
                Text("Name").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).controlSize(.large)
                Picker("Color", selection: $color) { ForEach(ProfileColor.allCases, id: \.self) { Text($0.rawValue) } }
                    .padding(.top, 8)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if model.save(profile, name: name, color: color) { dismiss() }
                    else { error = model.error; model.error = nil }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }.controlSize(.large)
        }.padding(30).frame(width: 360)
    }
}
