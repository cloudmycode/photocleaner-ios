import SwiftUI

@main
struct PhotoCleanerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var photoLibrary = PhotoLibraryService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(photoLibrary)
                .task {
                    photoLibrary.start()
                }
                .onChange(of: scenePhase) {
                    if scenePhase == .active {
                        photoLibrary.refreshAuthorizationStatus()
                    }
                }
        }
    }
}
