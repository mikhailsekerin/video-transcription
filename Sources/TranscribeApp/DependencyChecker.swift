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
    let pipPackage: String?
    var isPresent: Bool = false
    var resolvedPath: String? = nil

    init(id: String, friendlyName: String, subtitle: String, brewPackage: String? = nil, pipPackage: String? = nil) {
        self.id = id; self.friendlyName = friendlyName; self.subtitle = subtitle
        self.brewPackage = brewPackage; self.pipPackage = pipPackage
    }
}

@MainActor
final class DependencyChecker: ObservableObject {
    @Published var phase: SetupPhase = .idle
    @Published var dependencies: [Dependency] = [
        Dependency(
            id: "homebrew",
            friendlyName: "Homebrew",
            subtitle: "Package manager — required to install the other tools"
        ),
        Dependency(
            id: "ffmpeg",
            friendlyName: "FFmpeg",
            subtitle: "Converts your video file to audio",
            brewPackage: "ffmpeg"
        ),
        Dependency(
            id: "whisper-cpp",
            friendlyName: "Whisper.cpp",
            subtitle: "GPU (Metal) transcription — fast on Apple Silicon",
            brewPackage: "whisper-cpp"
        ),
        Dependency(
            id: "faster-whisper",
            friendlyName: "Faster Whisper",
            subtitle: "CPU transcription — fallback when GPU is off",
            pipPackage: "whisper-ctranslate2"
        ),
    ]
    @Published var installLog: String = ""

    private(set) var ffmpegPath: String = "/opt/homebrew/bin/ffmpeg"
    private(set) var whisperCppPath: String = "/opt/homebrew/bin/whisper-cli"
    private(set) var fasterWhisperPath: String = "/opt/homebrew/bin/whisper-ctranslate2"

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
        let whisperCppResolved = resolve(["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli",
                                          "/opt/homebrew/bin/whisper-cpp", "/usr/local/bin/whisper-cpp"])
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fasterWhisperResolved = resolve([
            "/opt/homebrew/bin/whisper-ctranslate2",
            "/usr/local/bin/whisper-ctranslate2",
            "\(home)/.local/bin/whisper-ctranslate2",
            // Direct venv path — present even when the ~/.local/bin symlink wasn't created
            "\(home)/.local/pipx/venvs/whisper-ctranslate2/bin/whisper-ctranslate2",
        ])

        // Yield so the .checking spinner renders before we replace it
        await Task.yield()

        // Rebuild the whole array so @Published fires a single clean update
        var updated = dependencies
        for i in updated.indices {
            switch updated[i].id {
            case "homebrew":
                updated[i].isPresent = brewResolved != nil
                updated[i].resolvedPath = brewResolved
            case "ffmpeg":
                updated[i].isPresent = ffmpegResolved != nil
                updated[i].resolvedPath = ffmpegResolved
            case "whisper-cpp":
                updated[i].isPresent = whisperCppResolved != nil
                updated[i].resolvedPath = whisperCppResolved
            case "faster-whisper":
                updated[i].isPresent = fasterWhisperResolved != nil
                updated[i].resolvedPath = fasterWhisperResolved
            default: break
            }
        }
        dependencies = updated

        brewPath = brewResolved
        if let p = ffmpegResolved       { ffmpegPath       = p }
        if let p = whisperCppResolved   { whisperCppPath   = p }
        if let p = fasterWhisperResolved { fasterWhisperPath = p }

        let allPresent   = updated.allSatisfy(\.isPresent)
        let brewPresent  = updated[0].isPresent
        let toolsMissing = !updated[1].isPresent || !updated[2].isPresent || !updated[3].isPresent

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

        let missingBrew = dependencies
            .filter { !$0.isPresent }
            .compactMap(\.brewPackage)

        let missingPip = dependencies
            .filter { !$0.isPresent }
            .compactMap(\.pipPackage)

        guard !missingBrew.isEmpty || !missingPip.isEmpty else {
            await checkDependencies()
            return
        }

        do {
            if !missingBrew.isEmpty {
                try await runBrewInstall(brew: brew, packages: missingBrew)
            }
            if !missingPip.isEmpty {
                // Ensure pipx is available (handles PEP 668 managed-environment restrictions)
                let pipx: String
                if let resolved = resolvePipx() {
                    pipx = resolved
                } else {
                    pipx = try await installPipx(brew: brew)
                }
                try await runPipxInstall(pipx: pipx, packages: missingPip)
            }
            await checkDependencies()
        } catch {
            withAnimation {
                phase = .installFailed(error.localizedDescription)
            }
        }
    }

    private func resolvePipx() -> String? {
        let candidates = ["/opt/homebrew/bin/pipx", "/usr/local/bin/pipx"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func installPipx(brew: String) async throws -> String {
        appendLog("Installing pipx (required to install Python CLI tools)...\n")
        try await runBrewInstall(brew: brew, packages: ["pipx"])
        guard let path = resolvePipx() else {
            throw InstallError.pipxNotFound
        }
        return path
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
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            env["HOMEBREW_NO_ANALYTICS"] = "1"
            env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
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

    private func runPipxInstall(pipx: String, packages: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pipx)
            // --prefer-binary tells pip to pick wheel-available versions over
            // sdist-only versions, avoiding PyAV source builds on Intel Macs
            // without over-constraining the resolver (which --only-binary=av
            // did and caused ResolutionImpossible on some setups).
            // --force reinstalls cleanly if a previous failed run left a partial
            // venv (without it, pipx exits 0 saying "already installed" and the
            // binary never appears).
            process.arguments = ["install", "--force", "--pip-args=--prefer-binary"] + packages

            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            env["HOME"] = home
            env["PIPX_HOME"] = "\(home)/.local/pipx"
            env["PIPX_BIN_DIR"] = "\(home)/.local/bin"
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
                    continuation.resume(throwing: InstallError.pipxFailed(proc.terminationStatus))
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
    case pipxFailed(Int32)
    case pipxNotFound
    var errorDescription: String? {
        switch self {
        case .brewFailed(let code):  return "Homebrew exited with code \(code). Check the log for details."
        case .pipxFailed(let code):  return "pipx exited with code \(code). Check the log for details."
        case .pipxNotFound:          return "pipx could not be found after installation. Try running 'brew install pipx' manually."
        }
    }
}
