import SwiftUI

@main
struct MacroKnotApp: App {
    @StateObject private var permissions = PermissionState()

    var body: some Scene {
        WindowGroup {
            ContentView(permissions: permissions)
                .frame(minWidth: 820, minHeight: 620)
        }
    }
}
