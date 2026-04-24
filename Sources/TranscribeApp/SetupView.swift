import SwiftUI

struct SetupView: View {
    @ObservedObject var checker: DependencyChecker

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 28) {
                    dependencyList
                    actionArea
                }
                .padding(32)
            }
        }
        .frame(minWidth: 540, minHeight: 480)
    }

    // MARK: – Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Getting Ready")
                    .font(.title2.bold())
                Text("We need a couple of free tools before you can start transcribing.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    // MARK: – Dependency List

    private var dependencyList: some View {
        VStack(spacing: 0) {
            ForEach(checker.dependencies) { dep in
                DependencyRow(dep: dep)
                if dep.id != checker.dependencies.last?.id {
                    Divider().padding(.leading, 52)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 0.5))
    }

    // MARK: – Action Area

    @ViewBuilder
    private var actionArea: some View {
        switch checker.phase {
        case .idle, .checking:
            ProgressView("Checking your system…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

        case .ready:
            EmptyView()

        case .needsHomebrew:
            HomebrewMissingPanel()

        case .needsSetup:
            VStack(spacing: 12) {
                Button {
                    Task { await checker.installMissing() }
                } label: {
                    Label("Install Missing Tools", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("This will use Homebrew to download and install the missing tools. It may take a few minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

        case .installing:
            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.8)
                    Text("Installing… this may take a few minutes")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .destructive) { checker.cancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                InstallLogView(log: checker.installLog)
            }

        case .installFailed(let message):
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if !checker.installLog.isEmpty {
                    InstallLogView(log: checker.installLog)
                }

                Button {
                    Task { await checker.installMissing() }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }
}

// MARK: – Dependency Row

private struct DependencyRow: View {
    let dep: Dependency

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: dep.isPresent ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 22))
                .foregroundStyle(dep.isPresent ? .green : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(dep.friendlyName)
                    .font(.body.weight(.medium))
                Text(dep.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let path = dep.resolvedPath {
                Text(path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if dep.isPresent == false {
                Text("Not found")
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: – Homebrew Missing Panel

private struct HomebrewMissingPanel: View {
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Homebrew is required", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text("Homebrew is a free package manager for macOS. It lets this app install FFmpeg and Whisper automatically. You only need to install it once.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Step 1 — Open Terminal (press ⌘Space and type 'Terminal'), then paste this command:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Text(DependencyChecker.homebrewInstallCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(DependencyChecker.homebrewInstallCommand, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .help("Copy to clipboard")
                }
            }

            Text("Step 2 — After Homebrew finishes installing, click the button below.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                Task { await DependencyCheckerAccess.shared?.checkDependencies() }
            } label: {
                Label("I've Installed Homebrew — Check Again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 0.5))
    }
}

// MARK: – Install Log View

private struct InstallLogView: View {
    let log: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(log.isEmpty ? "Waiting for output…" : log)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(log.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .id("bottom")
            }
            .frame(height: 160)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
            .onChange(of: log) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

// MARK: – Workaround for HomebrewMissingPanel needing checker access

// The panel is a private struct; it uses this thin wrapper to call back to the checker.
final class DependencyCheckerAccess {
    static weak var shared: DependencyChecker?
}
