import Foundation
import SwiftUI

enum SetupPhase: Equatable {
    case idle
    case checking
    case ready
    case needsSetup
    case needsHomebrew
    case installing
    case installFailed(String)
}

struct Dependency: Identifiable {
    let id: String
    let friendlyName: String
    let subtitle: String
    let brewPackage: String?
    var isPresent: Bool = false
    var resolvedPath: String? = nil
}

@MainActor
final class DependencyChecker: ObservableObject {
    @Published var phase: SetupPhase = .idle
    @Published var dependencies: [Dependency] = [
        Dependency(
            id: "homebrew",
            friendlyName: "Homebrew",
            subtitle: "Package manager — required to install the other tools",
            brewPackage: nil
        ),
        Dependency(
            id: "ffmpeg",
            friendlyName: "FFmpeg",
            subtitle: "Converts your video file to audio",
            brewPackage: "ffmpeg"
        ),
        Dependency(
            id: "whisper",
            friendlyName: "Whisper AI",
            subtitle: "Turns speech into text",
            brewPackage: "openai-whisper"
        ),
    ]
    @Published var installLog: String = ""

    private(set) var ffmpegPath: String = "/opt/homebrew/bin/ffmpeg"
    private(set) var whisperPath: String = "/opt/homebrew/bin/whisper"

    private var brewPath: String? = nil
    private var installProcess: Process?

    static let homebrewInstallCommand =
        #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#

    func checkDependencies() async {
        phase = .checking

        let fm = FileManager.default

        func resolve(_ candidates: [String]) -> String? {
            candidates.first { fm.fileExists(atPath: $0) }
        }

        // Probe all paths off-main to avoid blocking the render loop
        let brewResolved  = resolve(["/opt/homebrew/bin/brew",   "/usr/local/bin/brew"])
        let ffmpegResolved = resolve(["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"])
        let whisperResolved = resolve(["/opt/homebrew/bin/whisper", "/usr/local/bin/whisper"])

        // Yield so the .checking spinner renders before we replace it
        await Task.yield()

        // Rebuild the whole array so @Published fires a single clean update
        var updated = dependencies
        updated[0].isPresent = brewResolved != nil
        updated[0].resolvedPath = brewResolved
        updated[1].isPresent = ffmpegResolved != nil
        updated[1].resolvedPath = ffmpegResolved
        updated[2].isPresent = whisperResolved != nil
        updated[2].resolvedPath = whisperResolved
        dependencies = updated

        brewPath = brewResolved
        if let p = ffmpegResolved  { ffmpegPath  = p }
        if let p = whisperResolved { whisperPath = p }

        let allPresent   = updated.allSatisfy(\.isPresent)
        let brewPresent  = updated[0].isPresent
        let toolsMissing = !updated[1].isPresent || !updated[2].isPresent

        if allPresent {
            phase = .ready
        } else if !brewPresent {
            phase = .needsHomebrew
        } else if toolsMissing {
            phase = .needsSetup
        }
    }

    func installMissing() async {
        installLog = ""
        phase = .installing

        guard let brew = brewPath else {
            phase = .needsHomebrew
            return
        }

        let missing = dependencies
            .compactMap { dep -> String? in
                guard !dep.isPresent, let pkg = dep.brewPackage else { return nil }
                return pkg
            }

        guard !missing.isEmpty else {
            await checkDependencies()
            return
        }

        do {
            try await runBrewInstall(brew: brew, packages: missing)
            await checkDependencies()
        } catch {
            withAnimation {
                phase = .installFailed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        installProcess?.terminate()
        phase = .needsSetup
        appendLog("\nInstallation cancelled.")
    }

    private func runBrewInstall(brew: String, packages: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: brew)
            process.arguments = ["install"] + packages

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                    Task { @MainActor [weak self] in
                        self?.appendLog(text)
                    }
                }
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: InstallError.brewFailed(proc.terminationStatus))
                }
            }

            do {
                self.installProcess = process
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func appendLog(_ text: String) {
        installLog += text
    }
}

enum InstallError: LocalizedError {
    case brewFailed(Int32)
    var errorDescription: String? {
        switch self {
        case .brewFailed(let code): return "Homebrew exited with code \(code). Check the log for details."
        }
    }
}
