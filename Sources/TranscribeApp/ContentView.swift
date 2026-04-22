import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var manager: TranscriptionManager

    init(ffmpegPath: String, whisperPath: String) {
        _manager = StateObject(wrappedValue: TranscriptionManager(ffmpegPath: ffmpegPath, whisperPath: whisperPath))
    }

    @State private var videoURL: URL? = nil
    @State private var language = "de"
    @State private var model = "medium"
    @State private var initialPrompt = ""
    @State private var removeFiller = false
    @State private var transcriptCopied = false
    @State private var isDropTargeted = false
    @State private var isDropZoneHovered = false
    @State private var showFilePicker = false
    @State private var showSrtSavePicker = false
    @State private var showTxtSavePicker = false
    @State private var selectedTab = 0

    private var isRunning: Bool {
        switch manager.step {
        case .converting, .transcribing: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            mainContent
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: videoContentTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                videoURL = url
            }
        }
        .fileExporter(
            isPresented: $showTxtSavePicker,
            document: PlainTextDocument(content: manager.txtContent),
            contentType: .plainText,
            defaultFilename: baseFilename + ".txt"
        ) { _ in }
        .fileExporter(
            isPresented: $showSrtSavePicker,
            document: PlainTextDocument(content: manager.srtContent),
            contentType: .plainText,
            defaultFilename: baseFilename + ".srt"
        ) { _ in }
        .onChange(of: manager.step) { newStep in
            if case .done = newStep { selectedTab = 0 }
        }
    }

    // MARK: – Header

    private var headerBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Video Transcriber")
                    .font(.headline)
                if let url = videoURL {
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Picker("Language", selection: $language) {
                Text("German").tag("de")
                Text("English").tag("en")
                Text("French").tag("fr")
                Text("Spanish").tag("es")
                Text("Italian").tag("it")
                Text("Portuguese").tag("pt")
                Text("Russian").tag("ru")
                Text("Chinese").tag("zh")
                Text("Japanese").tag("ja")
                Text("Arabic").tag("ar")
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(isRunning)

            Picker("Model", selection: $model) {
                Text("tiny").tag("tiny")
                Text("base").tag("base")
                Text("small").tag("small")
                Text("medium").tag("medium")
                Text("large").tag("large")
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(isRunning)

            if isRunning {
                Button("Cancel", role: .destructive) {
                    manager.cancel()
                }
                .buttonStyle(.bordered)
            } else {
                Button("Transcribe") {
                    guard let url = videoURL else { return }
                    manager.run(videoURL: url, language: language, model: model, initialPrompt: initialPrompt, removeFiller: removeFiller)
                }
                .buttonStyle(.borderedProminent)
                .disabled(videoURL == nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: – Main

    private var mainContent: some View {
        HSplitView {
            dropZone
                .frame(minWidth: 220, maxWidth: 300)

            TabView(selection: $selectedTab) {
                transcriptView
                    .tabItem { Label("Transcript", systemImage: "doc.text") }
                    .tag(0)
                srtView
                    .tabItem { Label("SRT", systemImage: "captions.bubble") }
                    .tag(1)
                logView
                    .tabItem { Label("Log", systemImage: "terminal") }
                    .tag(2)
            }
        }
    }

    // MARK: – Drop Zone

    private var dropZone: some View {
        VStack(spacing: 14) {
            // Video drop target
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isDropTargeted || isDropZoneHovered ? Color.accentColor : Color.secondary.opacity(0.4),
                        style: StrokeStyle(lineWidth: 2, dash: isDropTargeted ? [] : [8])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isDropTargeted ? Color.accentColor.opacity(0.08)
                                  : isDropZoneHovered ? Color.accentColor.opacity(0.04)
                                  : Color.clear)
                    )
                    .animation(.easeInOut(duration: 0.15), value: isDropZoneHovered)
                    .animation(.easeInOut(duration: 0.15), value: isDropTargeted)

                VStack(spacing: 10) {
                    Image(systemName: videoURL == nil ? "film" : "film.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(
                            videoURL != nil ? AnyShapeStyle(.tint)
                            : isDropZoneHovered || isDropTargeted ? AnyShapeStyle(Color.accentColor)
                            : AnyShapeStyle(.secondary)
                        )
                        .scaleEffect(isDropTargeted ? 1.15 : 1.0)
                        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isDropTargeted)
                    if let url = videoURL {
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 8)
                    } else {
                        Text(isDropTargeted ? "Release to load" : "Drop video here\nor click to browse")
                            .font(.caption)
                            .foregroundStyle(isDropZoneHovered || isDropTargeted ? .primary : .secondary)
                            .multilineTextAlignment(.center)
                            .animation(.easeInOut(duration: 0.1), value: isDropTargeted)
                    }
                }
                .padding()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 160)
            .contentShape(Rectangle())
            .onHover { isDropZoneHovered = $0 }
            .onTapGesture { showFilePicker = true }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }

            // Context hint
            VStack(alignment: .leading, spacing: 4) {
                Text("Context hint (optional)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("e.g. UX research interview with Anna and Tom", text: $initialPrompt)
                    .font(.caption)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isRunning)
            }

            Toggle(isOn: $removeFiller) {
                Text("Remove filler words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .disabled(isRunning)

            // Status + progress
            statusBadge
            if isRunning { progressBar }

            // Save buttons
            if case .done = manager.step {
                VStack(spacing: 8) {
                    Button {
                        showTxtSavePicker = true
                    } label: {
                        Label("Save Transcript (.txt)", systemImage: "doc.text")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        showSrtSavePicker = true
                    } label: {
                        Label("Save Subtitles (.srt)", systemImage: "captions.bubble")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }

            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch manager.step {
        case .idle:
            EmptyView()
        case .converting:
            StatusRow(icon: "waveform", label: "Step 1 of 2 — Extracting audio from video", color: .blue, spinning: false)
        case .transcribing:
            StatusRow(icon: "brain", label: "Step 2 of 2 — Recognizing speech with Whisper AI", color: .orange, spinning: false)
        case .done:
            StatusRow(icon: "checkmark.circle.fill", label: "Done!", color: .green, spinning: false)
        case .failed(let msg):
            StatusRow(icon: "xmark.circle.fill", label: msg, color: .red, spinning: false)
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        VStack(spacing: 6) {
            if manager.progress > 0 {
                ProgressView(value: manager.progress)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .scaleEffect(0.75)
                    .frame(maxWidth: .infinity)
            }
            HStack {
                Text(progressDetailLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if manager.progress > 0 {
                    if !manager.progressLabel.isEmpty {
                        Text(manager.progressLabel)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(Int(manager.progress * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 2)
        .animation(.easeInOut(duration: 0.2), value: manager.progress)
    }

    private var progressDetailLabel: String {
        switch manager.step {
        case .converting:
            return manager.progress > 0 ? "Extracting audio…" : "Starting FFmpeg…"
        case .transcribing:
            return manager.progress > 0 ? "Transcribing audio…" : "Loading Whisper model, please wait…"
        default:
            return ""
        }
    }

    // MARK: – Transcript View

    private var transcriptView: some View {
        Group {
            if manager.txtContent.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: isRunning ? "waveform" : "doc.text")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(isRunning ? "Transcription in progress…" : "Transcript will appear here")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(manager.txtContent, forType: .string)
                            transcriptCopied = true
                            Task {
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                transcriptCopied = false
                            }
                        } label: {
                            Label(transcriptCopied ? "Copied!" : "Copy", systemImage: transcriptCopied ? "checkmark" : "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(transcriptCopied ? .green : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .animation(.easeInOut(duration: 0.15), value: transcriptCopied)
                    }
                    Divider()
                    ScrollView {
                        Text(manager.txtContent)
                            .font(.body)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .textSelection(.enabled)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
        }
    }

    // MARK: – SRT View

    private var srtView: some View {
        Group {
            if manager.srtContent.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("SRT subtitles will appear here")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(manager.srtContent)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    // MARK: – Log View

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(manager.log.isEmpty ? "Output will appear here…" : manager.log)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(manager.log.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .id("logBottom")
            }
            .onChange(of: manager.log) { _ in
                proxy.scrollTo("logBottom", anchor: .bottom)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: – Helpers

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async { videoURL = url }
        }
        return true
    }

    private var videoContentTypes: [UTType] {
        [.movie, .video, .mpeg4Movie, .quickTimeMovie,
         UTType(filenameExtension: "mkv") ?? .movie,
         UTType(filenameExtension: "webm") ?? .movie]
    }

    private var baseFilename: String {
        videoURL?.deletingPathExtension().lastPathComponent ?? "transcript"
    }
}

// MARK: – Subviews

struct StatusRow: View {
    let icon: String
    let label: String
    let color: Color
    let spinning: Bool

    var body: some View {
        HStack(spacing: 8) {
            if spinning {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: icon)
                    .foregroundStyle(color)
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: – File Document

struct PlainTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var content: String

    init(content: String) { self.content = content }
    init(configuration: ReadConfiguration) throws {
        content = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let data = content.data(using: .utf8) else {
            throw NSError(domain: "FileWriteError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode content as UTF-8"])
        }
        return FileWrapper(regularFileWithContents: data)
    }
}
