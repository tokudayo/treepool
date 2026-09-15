#if os(macOS)
import SwiftUI

@main
struct TreepoolMenuApp: App {
    @NSApplicationDelegateAdaptor(MenuAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
#endif
