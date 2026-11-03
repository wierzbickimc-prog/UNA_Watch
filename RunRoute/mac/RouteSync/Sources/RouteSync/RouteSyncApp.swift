import AppKit
import SwiftUI

@main
struct RouteSyncApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = UploadModel()

    var body: some Scene {
        Window("RouteSync", id: "main") {
            ContentView(model: model)
                .onAppear { delegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

/// Handles files opened from Finder, including any that launched the app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pending: [URL] = []

    @MainActor var model: UploadModel? {
        didSet {
            if let model, !pending.isEmpty {
                model.open(pending)
                pending = []
            }
        }
    }

    @MainActor func application(_ application: NSApplication, open urls: [URL]) {
        if let model {
            model.open(urls)
        } else {
            pending += urls
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
