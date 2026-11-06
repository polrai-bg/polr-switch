import Foundation

struct AppMetadata {
    private let info: [String: Any]
    let name: String
    let executable: String
    let identifier: String

    static var displayName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Profile manager" }
    static var displayVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development" }

    init(info: [String: Any]) throws {
        for key in ["CFBundleName", "CFBundleExecutable", "CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion"] {
            guard let value = info[key] as? String, !value.isEmpty else {
                throw ProfileError.message("The app bundle is missing \(key). Reinstall the profile manager.")
            }
        }
        self.info = info
        name = info["CFBundleName"] as! String
        executable = info["CFBundleExecutable"] as! String
        identifier = info["CFBundleIdentifier"] as! String
    }

    func launcherInfo(_ profile: Profile) -> [String: Any] {
        var result = info
        result["CFBundleIdentifier"] = "\(identifier).profile.\(profile.id.uuidString.lowercased())"
        result["CFBundleDisplayName"] = "\(name) \(profile.name)"
        result["LSUIElement"] = true
        result["ProfileID"] = profile.id.uuidString
        result["CFBundleIconFile"] = "Profile.icns"
        return result
    }
}
