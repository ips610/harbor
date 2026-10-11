import Foundation

/// The app's display name. To rename the app, change APP_NAME in app.conf:
/// build.sh writes it into Info.plist, and everything here reads it back.
enum AppInfo {
    static let fallbackName = "harbor"

    static let name: String =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? fallbackName
}
