import SwiftUI

@main
struct SyncSpeakerApp: App {
    @StateObject private var session = SessionCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .onOpenURL { session.handleOpenURL($0) }      // Spotify auth callback
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { session.appBecameActive() }
                }
        }
    }
}
