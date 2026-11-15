import SwiftUI

@main
struct TrenchesApp: App {
    var body: some Scene {
        WindowGroup {
            root
                .preferredColorScheme(.dark)
                .tint(TrenchesTheme.accent)
        }
    }

    @ViewBuilder private var root: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--verify-pipeline") || Bundle.main.object(forInfoDictionaryKey: "TrenchesRunVerification") as? Bool == true { PipelineVerificationView() }
        else { ContentView() }
        #else
        ContentView()
        #endif
    }
}
