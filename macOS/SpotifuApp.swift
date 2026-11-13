import SwiftUI
#if SWIFT_PACKAGE
import SpotifuUI
#endif

@main struct SpotifuApp: App {
    var body: some Scene {
        WindowGroup { NavigationView { DownloadsView() }.frame(minWidth: 650, minHeight: 700) }
    }
}
