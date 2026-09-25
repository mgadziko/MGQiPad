import SwiftUI

@main
struct MGQiPadApp: App {
    @StateObject private var player = PlayerViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(player)
        }
    }
}
