import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct BatchItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var status: Status = .pending
    var transcript: String = ""
    var srt: String = ""

    enum Status: Equatable {
        case pending
        case processing
        case done
        case failed(String)
    }
}

struct ContentView: View {
    @StateObject private var manager: TranscriptionManager

    init(ffmpegPath: String, whisperCppPath: String, fasterWhisperPath: String) {
        _manager = StateObject(wrappedValue: TranscriptionManager(ffmpegPath: ffmpegPath, whisperCppPath: whisperCppPath, fasterWhisperPath: fasterWhisperPath))
    }

    @State private var queue: [BatchItem] = []
    @State private var currentItemID: UUID? = nil
    @State private var batchFolder: URL? = nil
    @State private var isBatchMode: Bool = false
    @State private var batchComplete: Bool = false
    @State private var combinedTranscript: String = ""
    @State private var viewingItemID: UUID? = nil

    @AppStorage("language") private var language = "de"
    @AppStorage("model") private var model = "large"
    @AppStorage("initialPrompt") private var initialPrompt = ""
    @AppStorage("removeFiller") private var removeFiller = false
    @AppStorage("useGPU") private var useGPU = true
    @AppStorage("autoSave") private var autoSave = false
    @AppStorage("trimSilence") private var trimSilence = false
    @AppStorage("recentFiles") private var recentFilesRaw = ""
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false
    @State private var transcriptCopied = false
    @State private var isDropTargeted = false
    @State private var isWindowDropTargeted = false
    @State private var isDropZoneHovered = false
    @State private var showFilePicker = false
    @State private var showSrtSavePicker = false
    @State private var showMdSavePicker = false
    @State private var selectedTab = 0

    private var recentFiles: [URL] {
        recentFilesRaw.split(separator: "\n").compactMap { URL(string: String($0)) }
    }

    private var isRunning: Bool {
        switch manager.step {
        case .converting, .transcribing: return true
        default: return false
        }
    }

    private var currentItem: BatchItem? {
        guard let id = currentItemID else { return nil }
        return queue.first(where: { $0.id == id })
    }

    private var pendingCount: Int {
        queue.filter { $0.status == .pending }.count
    }

    private var isBatchRunning: Bool {
        isRunning && currentItemID != nil
    }

    private var currentItemIndex: Int? {
        guard let id = currentItemID else { return nil }
        return queue.firstIndex(where: { $0.id == id })
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            mainContent
        }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .strokeBorder(Color.accentColor, lineWidth: 4)
                .opacity(isWindowDropTargeted ? 1 : 0)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.15), value: isWindowDropTargeted)
        )
        .onDrop(of: [.fileURL], isTargeted: $isWindowDropTargeted) { providers in
            handleDrop(providers)
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: videoContentTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                enqueue(urls)
            }
        }
        .fileExporter(
            isPresented: $showMdSavePicker,
            document: PlainTextDocument(content: manager.markdownContent),
            contentType: UTType(filenameExtension: "md") ?? .plainText,
            defaultFilename: baseFilename + ".md"
        ) { _ in }
        .fileExporter(
            isPresented: $showSrtSavePicker,
            document: PlainTextDocument(content: manager.srtContent),
            contentType: UTType(filenameExtension: "srt") ?? .plainText,
            defaultFilename: baseFilename + ".srt"
        ) { _ in }
        .onChange(of: manager.step) { newStep in
            handleStepChange(newStep)
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(onDismiss: {
                hasSeenOnboarding = true
                showOnboarding = false
            })
        }
        .onAppear {
            if !hasSeenOnboarding { showOnboarding = true }
        }
    }

    // MARK: – Header

    private var headerBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Video Transcriber")
                    .font(.headline)
                if let sub = headerSubtitle {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Button {
                showOnboarding = true
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .help("How it works")

            if !recentFiles.isEmpty {
                Menu {
                    ForEach(recentFiles, id: \.self) { url in
                        Button(url.lastPathComponent) { enqueue([url]) }
                    }
                    Divider()
                    Button("Clear Recent") { recentFilesRaw = "" }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Recent videos")
                .disabled(isRunning)
            }

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
                Text("tiny — fastest, lowest quality").tag("tiny")
                Text("base — fast").tag("base")
                Text("small — balanced").tag("small")
                Text("medium — recommended").tag("medium")
                Text("large — best, slowest").tag("large")
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(isRunning)
            .help("Larger models are more accurate but slower and use more memory. Downloads on first use.")

            if isRunning {
                Button("Cancel", role: .destructive) {
                    cancelBatch()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            } else {
                Button(transcribeButtonLabel) {
                    startBatch()
                }
                .buttonStyle(.borderedProminent)
                .disabled(pendingCount == 0)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            // Hidden ⌘O shortcut for opening the file picker
            Button("") { if !isRunning { showFilePicker = true } }
                .keyboardShortcut("o", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }

    private var headerSubtitle: String? {
        if let item = currentItem, let idx = currentItemIndex {
            return "\(item.url.lastPathComponent)  (\(idx + 1) of \(queue.count))"
        }
        if queue.count == 1 {
            return queue[0].url.lastPathComponent
        }
        if queue.count > 1 {
            return "\(queue.count) videos queued"
        }
        return nil
    }

    private var transcribeButtonLabel: String {
        pendingCount > 1 ? "Transcribe (\(pendingCount))" : "Transcribe"
    }

    // MARK: – Main

    private var mainContent: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 240, maxWidth: 320)

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

    // MARK: – Sidebar

    private var sidebar: some View {
        VStack(spacing: 14) {
            dropZone

            if !queue.isEmpty {
                queueList
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

            VStack(alignment: .leading, spacing: 10) {
                Text("Advanced")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                explainedToggle(
                    isOn: $removeFiller,
                    title: "Remove filler words",
                    subtitle: "Strips \"um\", \"uh\", \"like\", \"you know\" from the transcript."
                )
                explainedToggle(
                    isOn: $useGPU,
                    title: "Use GPU (Apple Silicon)",
                    subtitle: "Recommended with Large model on M-series Macs. Medium CPU often matches or beats Medium GPU."
                )
                explainedToggle(
                    isOn: $trimSilence,
                    title: "Trim silence",
                    subtitle: "Removes quiet gaps before transcribing — faster and fewer hallucinations. Note: SRT timestamps won't match the original video."
                )
                explainedToggle(
                    isOn: $autoSave,
                    title: "Auto-save next to video",
                    subtitle: "Single-video mode: writes .md and .srt alongside the source. Batch mode always saves a combined .md into a new folder."
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Status + progress
            statusBadge
            if isRunning { progressBar }

            // Save buttons (apply to most-recent completed item)
            if case .done = manager.step, !isBatchMode {
                VStack(spacing: 8) {
                    Button {
                        showMdSavePicker = true
                    } label: {
                        Label("Save Markdown (.md)", systemImage: "doc.text")
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

            if isBatchMode, let folder = batchFolder, case .done = manager.step, currentItemID == nil {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                } label: {
                    Label("Reveal output folder", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
        .padding(16)
    }

    // MARK: – Drop Zone

    private var dropZone: some View {
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
                Image(systemName: queue.isEmpty ? "film" : "film.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(
                        !queue.isEmpty ? AnyShapeStyle(.tint)
                        : isDropZoneHovered || isDropTargeted ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(.secondary)
                    )
                    .scaleEffect(isDropTargeted ? 1.15 : 1.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isDropTargeted)

                Text(isDropTargeted ? "Release to load"
                     : queue.isEmpty ? "Drop videos here\nor click to browse"
                     : "Drop more videos\nor click to add")
                    .font(.caption)
                    .foregroundStyle(isDropZoneHovered || isDropTargeted ? .primary : .secondary)
                    .multilineTextAlignment(.center)
                    .animation(.easeInOut(duration: 0.1), value: isDropTargeted)
            }
            .padding()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .contentShape(Rectangle())
        .onHover { isDropZoneHovered = $0 }
        .onTapGesture { showFilePicker = true }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: – Queue list

    private var queueList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Queue (\(queue.count))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if !isRunning && queue.contains(where: { $0.status != .processing }) {
                    Button("Clear") { clearFinishedAndPending() }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(queue) { item in
                        queueRow(item)
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    @ViewBuilder
    private func queueRow(_ item: BatchItem) -> some View {
        let viewable = item.status == .processing || item.status == .done
        HStack(spacing: 8) {
            statusIcon(for: item.status)
                .frame(width: 14)
            Text(item.url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if case .failed(let msg) = item.status {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .help(msg)
            }
            if item.status != .processing {
                Button {
                    removeFromQueue(item.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            rowBackground(for: item),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard viewable else { return }
            viewingItemID = (viewingItemID == item.id) ? nil : item.id
            selectedTab = 0
        }
        .help(viewable ? "Click to view this transcript" : "")
    }

    private func rowBackground(for item: BatchItem) -> Color {
        if item.id == viewingItemID { return Color.accentColor.opacity(0.18) }
        if item.id == currentItemID { return Color.accentColor.opacity(0.08) }
        return Color.clear
    }

    @ViewBuilder
    private func statusIcon(for status: BatchItem.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .processing:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 14, height: 14)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
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
            StatusRow(icon: "checkmark.circle.fill", label: batchDoneLabel, color: .green, spinning: false)
        case .failed(let msg):
            StatusRow(icon: "xmark.circle.fill", label: msg, color: .red, spinning: false)
        }
    }

    private var batchDoneLabel: String {
        guard isBatchMode else { return "Done!" }
        let done = queue.filter { $0.status == .done }.count
        let failed = queue.filter { if case .failed = $0.status { return true } else { return false } }.count
        if failed > 0 { return "Batch complete — \(done) done, \(failed) failed" }
        return "Batch complete — \(done) videos"
    }

    @ViewBuilder
    private var progressBar: some View {
        VStack(spacing: 6) {
            if manager.isDownloadingModel {
                ProgressView(value: Double(manager.modelDownloadPercent) / 100)
                    .progressViewStyle(.linear)
            } else if manager.progress > 0 {
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
                if manager.isDownloadingModel {
                    Text("\(manager.modelDownloadPercent)%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if manager.progress > 0 {
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
        if manager.isDownloadingModel {
            return "Downloading \(model) model (one-time)…"
        }
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

    private var viewingItem: BatchItem? {
        guard let id = viewingItemID else { return nil }
        return queue.first(where: { $0.id == id })
    }

    private var displayedTranscript: String {
        if let item = viewingItem {
            if item.id == currentItemID { return manager.markdownContent }
            return item.transcript
        }
        if isBatchMode {
            var text = combinedTranscript
            if let item = currentItem, !manager.markdownContent.isEmpty {
                let base = item.url.deletingPathExtension().lastPathComponent
                text += "## \(base)\n\n\(manager.markdownContent)"
            }
            return text
        }
        return manager.markdownContent
    }

    private var displayedSrt: String {
        if let item = viewingItem {
            if item.id == currentItemID { return manager.srtContent }
            return item.srt
        }
        return manager.srtContent
    }

    private var transcriptView: some View {
        Group {
            if displayedTranscript.isEmpty {
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
                            NSPasteboard.general.setString(displayedTranscript, forType: .string)
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
                        Text(displayedTranscript)
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
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("SRT includes timecodes — import into VLC, Premiere, or Final Cut as subtitles. Note: timecodes won't match if Trim Silence was enabled.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.07))
            Divider()
            Group {
                if displayedSrt.isEmpty {
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
                        Text(displayedSrt)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .textSelection(.enabled)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
        }
    }

    // MARK: – Log View

    private var logView: some View {
        VStack(spacing: 0) {
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
            if !manager.log.isEmpty {
                Divider()
                HStack {
                    Spacer()
                    Button("Copy Log") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(manager.log, forType: .string)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: – Queue management

    private func enqueue(_ urls: [URL]) {
        for url in urls {
            if queue.contains(where: { $0.url == url }) { continue }
            queue.append(BatchItem(url: url))
            addRecent(url)
        }
    }

    private func removeFromQueue(_ id: UUID) {
        queue.removeAll { $0.id == id && $0.status != .processing }
    }

    private func clearFinishedAndPending() {
        queue.removeAll { $0.status != .processing }
        if queue.isEmpty {
            batchFolder = nil
            isBatchMode = false
        }
    }

    // MARK: – Orchestrator

    private func startBatch() {
        guard !isRunning else { return }
        guard let firstPending = queue.firstIndex(where: { $0.status == .pending }) else { return }

        let pending = queue.filter { $0.status == .pending }.count
        let resumingExistingBatch = batchFolder != nil && !batchComplete
        isBatchMode = pending > 1 || resumingExistingBatch

        if isBatchMode && (batchFolder == nil || batchComplete) {
            batchFolder = createBatchFolder(near: queue[firstPending].url)
            combinedTranscript = ""
            batchComplete = false
        }

        runItem(at: firstPending)
    }

    private func runItem(at index: Int) {
        guard queue.indices.contains(index) else { return }
        queue[index].status = .processing
        currentItemID = queue[index].id
        manager.run(
            videoURL: queue[index].url,
            language: language,
            model: model,
            initialPrompt: initialPrompt,
            removeFiller: removeFiller,
            useGPU: useGPU,
            trimSilence: trimSilence
        )
    }

    private func handleStepChange(_ step: TranscriptionStep) {
        switch step {
        case .done:
            selectedTab = 0
            if let id = currentItemID, let idx = queue.firstIndex(where: { $0.id == id }) {
                queue[idx].status = .done
                queue[idx].transcript = manager.markdownContent
                queue[idx].srt = manager.srtContent
                let item = queue[idx]
                if isBatchMode {
                    saveItemOutputs(item: item)
                } else if autoSave {
                    writeOutputs(next: item.url)
                }
            }
            advance()
        case .failed(let msg):
            if let id = currentItemID, let idx = queue.firstIndex(where: { $0.id == id }) {
                queue[idx].status = .failed(msg)
            }
            advance()
        default:
            break
        }
    }

    private func advance() {
        currentItemID = nil
        if let nextIdx = queue.firstIndex(where: { $0.status == .pending }) {
            runItem(at: nextIdx)
        } else if isBatchMode, let folder = batchFolder {
            batchComplete = true
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    private func cancelBatch() {
        manager.cancel()
        if let id = currentItemID, let idx = queue.firstIndex(where: { $0.id == id }) {
            queue[idx].status = .pending
        }
        currentItemID = nil
        // Keep batchFolder and isBatchMode so user can resume into the same folder
    }

    private func createBatchFolder(near url: URL) -> URL? {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = df.string(from: Date())
        let folder = url.deletingLastPathComponent().appendingPathComponent("Transcripts-\(stamp)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            return nil
        }
    }

    private func saveItemOutputs(item: BatchItem) {
        guard let folder = batchFolder else { return }
        let base = item.url.deletingPathExtension().lastPathComponent
        let srtURL = folder.appendingPathComponent("\(base).srt")
        try? item.srt.write(to: srtURL, atomically: true, encoding: .utf8)
        combinedTranscript += markdownSection(for: item)
        let combinedURL = folder.appendingPathComponent("combined-transcript.md")
        try? combinedTranscript.write(to: combinedURL, atomically: true, encoding: .utf8)
    }

    private func markdownSection(for item: BatchItem) -> String {
        let base = item.url.deletingPathExtension().lastPathComponent
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let date = df.string(from: Date())
        var header = "## \(base)\n"
        header += "- Date: \(date)\n"
        if manager.mediaDurationSec > 0 {
            header += "- Duration: \(formatSeconds(manager.mediaDurationSec))\n"
        }
        header += "\n"
        return header + item.transcript + "\n\n---\n\n"
    }

    private func formatSeconds(_ s: Double) -> String {
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    // MARK: – Helpers

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        var collected: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.lock()
                    collected.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            enqueue(collected)
        }
        return true
    }

    private var videoContentTypes: [UTType] {
        [.movie, .video, .mpeg4Movie, .quickTimeMovie,
         UTType(filenameExtension: "mkv") ?? .movie,
         UTType(filenameExtension: "webm") ?? .movie]
    }

    private var baseFilename: String {
        currentItem?.url.deletingPathExtension().lastPathComponent
            ?? queue.last?.url.deletingPathExtension().lastPathComponent
            ?? "transcript"
    }

    @ViewBuilder
    private func explainedToggle(isOn: Binding<Bool>, title: String, subtitle: String) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(isRunning)
    }

    private func addRecent(_ url: URL) {
        var list = recentFiles.filter { $0 != url }
        list.insert(url, at: 0)
        if list.count > 5 { list = Array(list.prefix(5)) }
        recentFilesRaw = list.map(\.absoluteString).joined(separator: "\n")
    }

    private func writeOutputs(next url: URL) {
        let base = url.deletingPathExtension()
        let md = base.appendingPathExtension("md")
        let srt = base.appendingPathExtension("srt")
        try? manager.markdownContent.write(to: md, atomically: true, encoding: .utf8)
        try? manager.srtContent.write(to: srt, atomically: true, encoding: .utf8)
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
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: – Onboarding

struct OnboardingView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("Welcome to Video Transcriber")
                    .font(.title2).fontWeight(.semibold)
                Text("Turn videos into timestamped, LLM-ready transcripts — locally, on your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 28)
            .padding(.horizontal, 28)

            VStack(alignment: .leading, spacing: 14) {
                featureRow(
                    icon: "film.stack",
                    title: "One video or a whole batch",
                    text: "Drop a single video or several at once. Batches process sequentially and land in one output folder."
                )
                featureRow(
                    icon: "doc.text.magnifyingglass",
                    title: "Markdown built for LLMs",
                    text: "Each transcript becomes a `.md` file with `[MM:SS]` timestamps per line — paste straight into ChatGPT."
                )
                featureRow(
                    icon: "globe",
                    title: "10 languages, 5 model sizes",
                    text: "Pick the language and Whisper model size that fits your audio quality vs. speed trade-off."
                )
                featureRow(
                    icon: "cpu",
                    title: "GPU, silence trim, filler cleanup",
                    text: "Optional toggles to speed things up or clean the output. GPU auto-falls back to CPU if it stumbles."
                )
                featureRow(
                    icon: "lock.shield",
                    title: "Everything runs locally",
                    text: "Audio never leaves your Mac. Uses Whisper (OpenAI) and FFmpeg via Homebrew."
                )
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)

            Divider()

            HStack {
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Text("Get Started")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520)
    }

    @ViewBuilder
    private func featureRow(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fontWeight(.semibold)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: – File Document

struct PlainTextDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.plainText,
         UTType(filenameExtension: "md") ?? .plainText,
         UTType(filenameExtension: "srt") ?? .plainText]
    }
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
