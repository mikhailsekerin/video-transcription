import SwiftUI

@main
struct TranscribeApp: App {
    @StateObject private var checker = DependencyChecker()

    var body: some Scene {
        WindowGroup {
            RootView(checker: checker)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 800, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct RootView: View {
    @ObservedObject var checker: DependencyChecker

    var body: some View {
        Group {
            if checker.phase == .ready {
                ContentView(ffmpegPath: checker.ffmpegPath, whisperCppPath: checker.whisperCppPath, fasterWhisperPath: checker.fasterWhisperPath)
            } else {
                SetupView(checker: checker)
            }
        }
        .task {
            DependencyCheckerAccess.shared = checker
            if checker.phase == .idle {
                await checker.checkDependencies()
            }
        }
    }
}
