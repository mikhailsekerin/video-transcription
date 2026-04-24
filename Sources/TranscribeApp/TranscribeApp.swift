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
            cleanupOrphanedTempFolders()
            if checker.phase == .idle {
                await checker.checkDependencies()
            }
        }
    }

    private func cleanupOrphanedTempFolders() {
        let tempDir = FileManager.default.temporaryDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) else { return }
        for url in contents {
            if url.lastPathComponent.hasPrefix("TranscribeApp-") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
