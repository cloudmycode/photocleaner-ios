import SwiftUI

@main
struct PhotoCleanerApp: App {
    @StateObject private var photoLibrary = PhotoLibraryService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(photoLibrary)
                .task {
                    photoLibrary.start()
                }
        }
    }
}
