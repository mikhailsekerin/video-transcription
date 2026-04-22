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
    @Published var txtContent: String = ""
    @Published var srtURL: URL? = nil
    @Published var progress: Double = 0        // 0.0–1.0
    @Published var progressLabel: String = ""  // e.g. "0:30 / 1:23"

    let ffmpegPath: String
    let whisperPath: String
    private var currentProcess: Process?
    private var totalDurationSec: Double = 0
    private var wasCancelled = false

    init(ffmpegPath: String, whisperPath: String) {
        self.ffmpegPath = ffmpegPath
        self.whisperPath = whisperPath
    }

    func run(videoURL: URL, language: String, model: String, initialPrompt: String = "", removeFiller: Bool = false, useGPU: Bool = false) {
        log = ""
        srtContent = ""
        txtContent = ""
        srtURL = nil
        progress = 0
        progressLabel = ""
        totalDurationSec = 0
        wasCancelled = false
        step = .converting

        Task {
            var wavToCleanup: URL?
            do {
                let wavURL = try await convertToWav(videoURL: videoURL)
                wavToCleanup = wavURL
                progress = 0
                progressLabel = ""
                step = .transcribing
                let srt = try await transcribe(wavURL: wavURL, language: language, model: model, initialPrompt: initialPrompt, useGPU: useGPU)
                srtContent = srt
                txtContent = srtToPlainText(srt, removeFiller: removeFiller)
                progress = 1.0
                step = .done
            } catch {
                if !wasCancelled {
                    step = .failed(error.localizedDescription)
                    appendLog("Error: \(error.localizedDescription)")
                }
            }
            if let wav = wavToCleanup {
                try? FileManager.default.removeItem(at: wav)
            }
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

    private func convertToWav(videoURL: URL) async throws -> URL {
        let wavURL = videoURL.deletingPathExtension().appendingPathExtension("wav")
        try? FileManager.default.removeItem(at: wavURL)

        appendLog("Converting video to WAV...\n")
        appendLog("ffmpeg -i \(videoURL.lastPathComponent) -vn -ac 1 -ar 16000 -af \"highpass=f=100,loudnorm\" -c:a pcm_s16le \(wavURL.lastPathComponent)\n\n")

        try await runProcess(
            launchPath: ffmpegPath,
            arguments: ["-i", videoURL.path, "-vn", "-ac", "1", "-ar", "16000",
                        "-af", "highpass=f=100,loudnorm", "-c:a", "pcm_s16le", wavURL.path, "-y"]
        )
        return wavURL
    }

    // MARK: – Transcription

    private func transcribe(wavURL: URL, language: String, model: String, initialPrompt: String, useGPU: Bool) async throws -> String {
        let outputDir = wavURL.deletingLastPathComponent()

        let device = useGPU ? "mps" : "cpu"
        let fp16 = useGPU ? "True" : "False"

        appendLog("\nTranscribing with Whisper...\n")
        appendLog("whisper \(wavURL.lastPathComponent) --language \(language) --model \(model) --device \(device) --fp16 \(fp16) --temperature 0 --condition_on_previous_text False --output_format srt\n\n")

        var args = [wavURL.path, "--language", language, "--model", model,
                    "--device", device, "--fp16", fp16, "--temperature", "0",
                    "--condition_on_previous_text", "False",
                    "--output_format", "srt", "--output_dir", outputDir.path]
        if !initialPrompt.trimmingCharacters(in: .whitespaces).isEmpty {
            args += ["--initial_prompt", initialPrompt]
        }
        try await runProcess(launchPath: whisperPath, arguments: args)

        let srtURL = outputDir
            .appendingPathComponent(wavURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("srt")
        self.srtURL = srtURL

        guard FileManager.default.fileExists(atPath: srtURL.path),
              let content = try? String(contentsOf: srtURL, encoding: .utf8) else {
            throw TranscribeError.srtNotFound(srtURL.path)
        }
        return content
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

    func srtToPlainText(_ srt: String, removeFiller: Bool = false) -> String {
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

        guard !parsed.isEmpty else { return "" }

        // Remove consecutive duplicate segments (Whisper hallucination loops)
        var deduped: [(start: Double, end: Double, text: String)] = []
        for segment in parsed {
            let normalised = segment.text.trimmingCharacters(in: .punctuationCharacters)
                .lowercased()
            let prevNormalised = deduped.last?.text
                .trimmingCharacters(in: .punctuationCharacters)
                .lowercased()
            if normalised != prevNormalised {
                deduped.append(segment)
            }
        }

        var result = ""
        for i in deduped.indices {
            var text = deduped[i].text
            if removeFiller { text = stripFillerWords(text) }
            result += text
            if i < deduped.count - 1 {
                result += deduped[i + 1].start - deduped[i].end > 2.0 ? "\n\n" : " "
            }
        }
        return result
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
