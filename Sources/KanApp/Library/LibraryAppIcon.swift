import AppKit
import SwiftUI
import KanCore

/// App icons for calls: the installed app's icon (found through Launch Services by bundle id, or by
/// the app's name via `AppCatalog`), otherwise an SF Symbol for the platform. Main-actor only;
/// lookups are cached for the life of the process.
@MainActor
enum LibraryAppIcons {
    private static var cache: [String: NSImage] = [:]
    private static var misses: Set<String> = []

    static func icon(appName: String?, bundleID: String?) -> NSImage? {
        let key = (bundleID ?? "") + "|" + (appName ?? "").lowercased()
        if let cached = cache[key] { return cached }
        if misses.contains(key) { return nil }
        if let url = applicationURL(appName: appName, bundleID: bundleID) {
            let image = NSWorkspace.shared.icon(forFile: url.path)
            cache[key] = image
            return image
        }
        misses.insert(key)
        return nil
    }

    static func symbol(for platform: CallPlatform?) -> String {
        switch platform {
        case .zoom?, .googleMeet?, .facetime?, .webex?, .skype?, .jitsi?, .whereby?: return "video.fill"
        case .teams?: return "person.3.fill"
        case .slack?: return "number"
        case .discord?: return "gamecontroller.fill"
        case .telegram?: return "paperplane.fill"
        case .signal?, .messenger?: return "message.fill"
        case .browser?: return "globe"
        case .manual?: return "mic.fill"
        case .imported?: return "square.and.arrow.down.fill"
        case .whatsapp?, .other?, nil: return "phone.fill"
        }
    }

    private static func applicationURL(appName: String?, bundleID: String?) -> URL? {
        var candidates: [String] = []
        if let bundleID, !bundleID.isEmpty { candidates.append(bundleID) }
        if let appName = appName?.trimmingCharacters(in: .whitespaces), !appName.isEmpty,
           let known = AppCatalog.known.first(where: { $0.name.caseInsensitiveCompare(appName) == .orderedSame }) {
            candidates.append(contentsOf: known.bundleIDs)
        }
        for id in candidates {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        if let appName = appName?.trimmingCharacters(in: .whitespaces), !appName.isEmpty, !appName.contains("/") {
            let url = URL(fileURLWithPath: "/Applications/\(appName).app")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}

/// A call's app icon at `size` points.
struct LibraryAppIcon: View {
    var appName: String?
    var bundleID: String?
    var platform: CallPlatform?
    var size: CGFloat = 20

    var body: some View {
        if let image = LibraryAppIcons.icon(appName: appName, bundleID: bundleID) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityLabel(appName ?? "App")
        } else {
            Image(systemName: LibraryAppIcons.symbol(for: platform))
                .font(.system(size: size * 0.55, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.22).fill(.quaternary))
                .accessibilityLabel(appName ?? platform?.displayName ?? "Call")
        }
    }
}
