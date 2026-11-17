import SwiftUI
import KanCore

enum SceneID {
    static let library = "library"
    static let onboarding = "onboarding"
}

/// The app's single model, shared by the scenes and the app delegate.
@MainActor
enum AppRuntime {
    static let model = AppModel(services: ServiceSelection.make())
}

/// Live services when this build has them, otherwise (or with KAN_MOCK=1) the mocks.
@MainActor
enum ServiceSelection {
    static func make() -> KanServices {
        if ProcessInfo.processInfo.environment["KAN_MOCK"] == "1" {
            KanLog.info("KAN_MOCK=1: using mock services")
            return MockServices.make()
        }
        if let live = LiveServices.make() { return live }
        KanLog.warning("Live services aren't available in this build; using mock services")
        return MockServices.make()
    }
}

/// The SwiftUI app: a menu-bar extra (no Dock icon: LSUIElement), the library window, the
/// onboarding window and Settings. Windows are opened on demand through `WindowRouter`.
struct KanMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppRuntime.model

    var body: some Scene {
        // First scene: the menu-bar item. Because it comes first, no window opens at launch.
        MenuBarExtra {
            MenuContentView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("Kan Library", id: SceneID.library) {
            LibraryRootView()
                .environment(model)
                .managedWindow()
        }
        .defaultSize(width: 1100, height: 720)

        Window("Welcome to Kan", id: SceneID.onboarding) {
            OnboardingView()
                .environment(model)
                .managedWindow()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environment(model)
                .managedWindow()
        }
    }
}
