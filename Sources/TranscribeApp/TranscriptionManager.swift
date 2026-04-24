import Foundation
import Combine

enum TranscriptionStep: Equatable {
    case idle
    case converting
    case transcribing
    case done
    case failed(String)
}

@MainActor
class TranscriptionManager: ObservableObject {
    @Published var step: TranscriptionStep = .idle
    @Published var log: String = ""
    @Published var srtContent: String = ""
    @Published var markdownContent: String = ""
    @Published var mediaDurationSec: Double = 0
    @Published var progress: Double = 0        // 0.0–1.0
    @Published var progressLabel: String = ""  // e.g. "0:30 / 1:23"
    @Published var isDownloadingModel = false
    @Published var modelDownloadPercent: Int = 0

    let ffmpegPath: String
    let whisperCppPath: String
    let fasterWhisperPath: String
    private var currentProcess: Process?
    private var totalDurationSec: Double = 0
    private var wasCancelled = false

    init(ffmpegPath: String, whisperCppPath: String, fasterWhisperPath: String) {
        self.ffmpegPath = ffmpegPath
        self.whisperCppPath = whisperCppPath
        self.fasterWhisperPath = fasterWhisperPath
    }

    func run(videoURL: URL, language: String, model: String, initialPrompt: String = "", removeFiller: Bool = false, useGPU: Bool = false, trimSilence: Bool = false) {
        log = ""
        srtContent = ""
        markdownContent = ""
        progress = 0
        progressLabel = ""
        totalDurationSec = 0
        mediaDurationSec = 0
        isDownloadingModel = false
        modelDownloadPercent = 0
        wasCancelled = false
        step = .converting

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscribeApp-\(UUID().uuidString)")

        Task {
            do {
                try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                let wavURL = try await convertToWav(videoURL: videoURL, workDir: workDir, trimSilence: trimSilence)
                mediaDurationSec = totalDurationSec
                progress = 0
                progressLabel = ""
                step = .transcribing
                let srt = try await transcribe(wavURL: wavURL, language: language, model: model, initialPrompt: initialPrompt, useGPU: useGPU)
                srtContent = srt
                markdownContent = srtToMarkdown(srt, removeFiller: removeFiller)
                progress = 1.0
                step = .done
            } catch {
                if !wasCancelled {
                    step = .failed(error.localizedDescription)
                    appendLog("Error: \(error.localizedDescription)")
                }
            }
            try? FileManager.default.removeItem(at: workDir)
        }
    }

    func cancel() {
        wasCancelled = true
        currentProcess?.terminate()
        step = .idle
        progress = 0
        progressLabel = ""
        appendLog("\nCancelled.")
    }

    // MARK: – Conversion

    private func convertToWav(videoURL: URL, workDir: URL, trimSilence: Bool) async throws -> URL {
        let wavURL = workDir.appendingPathComponent("audio").appendingPathExtension("wav")

        var audioFilter = "highpass=f=100,loudnorm"
        if trimSilence {
            audioFilter += ",silenceremove=stop_periods=-1:stop_duration=1:stop_threshold=-35dB,asetpts=N/SR/TB"
        }

        appendLog("Converting video to WAV\(trimSilence ? " (silence trimming on)" : "")...\n")
        appendLog("ffmpeg -i \(videoURL.lastPathComponent) -vn -ac 1 -ar 16000 -af \"\(audioFilter)\" -c:a pcm_s16le \(wavURL.lastPathComponent)\n\n")

        try await runProcess(
            launchPath: ffmpegPath,
            arguments: ["-i", videoURL.path, "-vn", "-ac", "1", "-ar", "16000",
                        "-af", audioFilter, "-c:a", "pcm_s16le", wavURL.path, "-y"]
        )
        return wavURL
    }

    // MARK: – Transcription

    private func transcribe(wavURL: URL, language: String, model: String, initialPrompt: String, useGPU: Bool) async throws -> String {
        if useGPU {
            return try await transcribeWithCpp(wavURL: wavURL, language: language, model: model, initialPrompt: initialPrompt)
        } else {
            return try await transcribeWithFasterWhisper(wavURL: wavURL, language: language, model: model, initialPrompt: initialPrompt)
        }
    }

    private func transcribeWithCpp(wavURL: URL, language: String, model: String, initialPrompt: String) async throws -> String {
        let modelPath = try await ensureWhisperCppModel(model)
        let outputDir = wavURL.deletingLastPathComponent()
        let outputPrefix = outputDir.appendingPathComponent(wavURL.deletingPathExtension().lastPathComponent).path

        appendLog("\nTranscribing with Whisper.cpp (Metal GPU)...\n")
        appendLog("whisper-cli -m ggml-\(model).bin -f \(wavURL.lastPathComponent) -l \(language) --output-srt\n\n")

        var args = ["-m", modelPath, "-f", wavURL.path, "-l", language,
                    "--output-srt", "-of", outputPrefix,
                    "--entropy-thold", "2.4",  // drop hallucinated segments above this entropy
                    "--max-context", "0"]       // don't carry context across segments → fewer loops
        if !initialPrompt.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["--prompt", initialPrompt]
        }
        try await runProcess(launchPath: whisperCppPath, arguments: args)

        let srtURL = URL(fileURLWithPath: outputPrefix + ".srt")
        guard FileManager.default.fileExists(atPath: srtURL.path),
              let content = try? String(contentsOf: srtURL, encoding: .utf8) else {
            let dirListing = (try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? []
            throw TranscribeError.srtNotFound("\(srtURL.lastPathComponent) — dir: \(dirListing.joined(separator: ", "))")
        }
        return content
    }

    private func transcribeWithFasterWhisper(wavURL: URL, language: String, model: String, initialPrompt: String) async throws -> String {
        let outputDir = wavURL.deletingLastPathComponent()

        appendLog("\nTranscribing with Faster-Whisper (CPU)...\n")
        appendLog("whisper-ctranslate2 \(wavURL.lastPathComponent) --language \(language) --model \(resolvedModel(model)) --device cpu --compute_type int8 --output_format srt\n\n")

        var args = [wavURL.path, "--language", language, "--model", resolvedModel(model),
                    "--device", "cpu", "--compute_type", "int8",
                    "--output_format", "srt", "--output_dir", outputDir.path]
        if !initialPrompt.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["--initial_prompt", initialPrompt]
        }
        try await runProcess(launchPath: fasterWhisperPath, arguments: args)

        let srtURL = outputDir
            .appendingPathComponent(wavURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("srt")

        guard FileManager.default.fileExists(atPath: srtURL.path),
              let content = try? String(contentsOf: srtURL, encoding: .utf8) else {
            let dirListing = (try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? []
            throw TranscribeError.srtNotFound("\(srtURL.lastPathComponent) — dir: \(dirListing.joined(separator: ", "))")
        }
        return content
    }

    // MARK: – Whisper.cpp model management

    // Maps picker name → versioned model name used by both whisper-cli and whisper-ctranslate2
    private func resolvedModel(_ model: String) -> String {
        switch model {
        case "large": return "large-v3"
        default:      return model
        }
    }

    // Maps picker name → GGML filename (without .bin)
    private func ggmlName(for model: String) -> String {
        "ggml-\(resolvedModel(model))"
    }

    private func whisperCppModelPath(for model: String) -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/whisper/\(ggmlName(for: model)).bin").path
    }

    private func ensureWhisperCppModel(_ model: String) async throws -> String {
        let modelPath = whisperCppModelPath(for: model)
        if FileManager.default.fileExists(atPath: modelPath) {
            return modelPath
        }
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/whisper")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let filename = "\(ggmlName(for: model)).bin"
        let url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)"
        // Download to .partial then rename, so a cancel/failure never leaves
        // a truncated .bin that looks valid to the next run. --fail makes curl
        // exit non-zero on HTTP errors instead of saving the error page.
        let partialPath = modelPath + ".partial"
        try? FileManager.default.removeItem(atPath: partialPath)
        appendLog("Downloading \(filename) (one-time, ~\(modelSizeMB(model)) MB)...\n")
        isDownloadingModel = true
        modelDownloadPercent = 0
        do {
            try await runProcess(launchPath: "/usr/bin/curl",
                                 arguments: ["-L", "--fail", "--progress-bar", "-o", partialPath, url])
        } catch {
            try? FileManager.default.removeItem(atPath: partialPath)
            isDownloadingModel = false
            throw error
        }
        try FileManager.default.moveItem(atPath: partialPath, toPath: modelPath)
        isDownloadingModel = false
        return modelPath
    }

    private func modelSizeMB(_ model: String) -> String {
        switch model {
        case "tiny":   return "75"
        case "base":   return "142"
        case "small":  return "466"
        case "medium": return "1500"
        case "large":  return "2900"
        default:       return "?"
        }
    }

    // MARK: – Process runner

    private func runProcess(launchPath: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                    Task { @MainActor [weak self] in
                        self?.appendLog(text)
                        self?.parseProgressChunk(text)
                    }
                }
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: TranscribeError.processFailed(proc.terminationStatus))
                }
            }

            do {
                self.currentProcess = process
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: – Progress parsing

    private func parseProgressChunk(_ text: String) {
        switch step {
        case .converting:   parseFFmpegChunk(text)
        case .transcribing: parseWhisperChunk(text)
        default: break
        }
    }

    private func parseFFmpegChunk(_ text: String) {
        // Capture total duration once from "Duration: HH:MM:SS.ss,"
        if totalDurationSec == 0, let r = text.range(of: "Duration: ") {
            let after = text[r.upperBound...]
            if let comma = after.firstIndex(of: ",") {
                let tc = String(after[after.startIndex..<comma]).trimmingCharacters(in: .whitespaces)
                totalDurationSec = parseTimecode(tc) ?? 0
            }
        }
        // Update from all "time=HH:MM:SS.ss" tokens, keep last valid one
        var search = text
        var latestT: Double? = nil
        while let r = search.range(of: "time=") {
            let after = String(search[r.upperBound...])
            let token = String(after.prefix(while: { !$0.isWhitespace && $0 != "\r" }))
            if let t = parseTimecode(token) { latestT = t }
            search = String(search[r.upperBound...])
        }
        if let t = latestT, totalDurationSec > 0 {
            progress = min(t / totalDurationSec, 1.0)
            progressLabel = formatTimeRange(t, of: totalDurationSec)
        }
    }

    private func parseWhisperChunk(_ text: String) {
        // Detect tqdm-style model download before any transcription output
        if !text.contains(" --> ") {
            if let pct = parseTqdmPercent(text) {
                isDownloadingModel = true
                modelDownloadPercent = pct
                return
            }
        } else if isDownloadingModel {
            isDownloadingModel = false
        }

        guard totalDurationSec > 0 else { return }
        // Parse "[HH:MM:SS.mmm --> HH:MM:SS.mmm]" lines, track latest end time
        var search = text
        var latestEnd: Double? = nil
        while let arrowRange = search.range(of: " --> ") {
            let after = search[arrowRange.upperBound...]
            let endToken = String(after.prefix(while: { $0 != "]" && !$0.isWhitespace }))
            if let t = parseTimecode(endToken) { latestEnd = t }
            search = String(search[arrowRange.upperBound...])
        }
        if let t = latestEnd {
            progress = min(t / totalDurationSec, 1.0)
            progressLabel = formatTimeRange(t, of: totalDurationSec)
        }
    }

    private func parseTqdmPercent(_ text: String) -> Int? {
        // Matches e.g. "  0%|" or " 42%|" or "100%|"
        var latest: Int? = nil
        var search = text
        while let r = search.range(of: "%|") {
            let before = search[..<r.lowerBound]
            let digits = before.reversed().prefix(while: { $0.isNumber })
            let num = String(digits.reversed())
            if let n = Int(num), n >= 0, n <= 100 { latest = n }
            search = String(search[r.upperBound...])
        }
        return latest
    }

    // MARK: – Helpers

    private func parseTimecode(_ s: String) -> Double? {
        let normalized = s.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":", maxSplits: 2)
        guard parts.count == 3,
              let h = Double(parts[0]),
              let m = Double(parts[1]),
              let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    private func formatTimeRange(_ current: Double, of total: Double) -> String {
        func fmt(_ s: Double) -> String {
            let m = Int(s) / 60; let sec = Int(s) % 60
            return String(format: "%d:%02d", m, sec)
        }
        return "\(fmt(current)) / \(fmt(total))"
    }

    func srtToMarkdown(_ srt: String, removeFiller: Bool = false) -> String {
        let segments = parsedSegments(srt)
        guard !segments.isEmpty else { return "" }

        func stamp(_ s: Double) -> String {
            let total = Int(s)
            let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
            return h > 0 ? String(format: "[%d:%02d:%02d]", h, m, sec)
                         : String(format: "[%d:%02d]", m, sec)
        }

        var lines: [String] = []
        for seg in segments {
            var text = seg.text
            if removeFiller { text = stripFillerWords(text) }
            lines.append("\(stamp(seg.start)) \(text)")
        }
        return lines.joined(separator: "\n")
    }

    private func parsedSegments(_ srt: String) -> [(start: Double, end: Double, text: String)] {
        let blocks = srt.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var parsed: [(start: Double, end: Double, text: String)] = []
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            guard let timeLine = lines.first(where: { $0.contains("-->") }),
                  let tlIdx = lines.firstIndex(of: timeLine) else { continue }
            let halves = timeLine.components(separatedBy: " --> ")
            guard halves.count == 2,
                  let start = parseTimecode(halves[0].trimmingCharacters(in: .whitespaces)),
                  let end   = parseTimecode(halves[1].trimmingCharacters(in: .whitespaces)) else { continue }
            let text = lines[(tlIdx + 1)...]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !text.isEmpty { parsed.append((start, end, text)) }
        }

        // Remove hallucination loops: drop any segment whose normalised text
        // already appeared in the last 6 segments (catches non-consecutive repeats too).
        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .punctuationCharacters)
             .lowercased()
             .components(separatedBy: .whitespaces)
             .filter { !$0.isEmpty }
             .joined(separator: " ")
        }
        var deduped: [(start: Double, end: Double, text: String)] = []
        for segment in parsed {
            let n = norm(segment.text)
            let window = deduped.suffix(6).map { norm($0.text) }
            if !window.contains(n) { deduped.append(segment) }
        }
        return deduped
    }

    private func stripFillerWords(_ text: String) -> String {
        let fillers = ["\\bum\\b", "\\buh\\b", "\\bäh\\b", "\\bähm\\b", "\\bhmm\\b",
                       "\\blike\\b", "\\byou know\\b", "\\bI mean\\b"]
        var result = text
        for pattern in fillers {
            result = result.replacingOccurrences(of: pattern, with: "",
                options: [.regularExpression, .caseInsensitive])
        }
        // Collapse multiple spaces left by removed words
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private func appendLog(_ text: String) {
        log += text
    }
}

enum TranscribeError: LocalizedError {
    case processFailed(Int32)
    case srtNotFound(String)

    var errorDescription: String? {
        switch self {
        case .processFailed(let code): return "Process exited with code \(code)"
        case .srtNotFound(let path): return "SRT file not found at \(path)"
        }
    }
}
