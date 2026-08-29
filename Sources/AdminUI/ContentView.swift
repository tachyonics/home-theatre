import AppKit
import HomeTheatreCore
import SwiftUI

@MainActor
struct ContentView: View {
    @State private var libraryPath: URL?
    @State private var output = ""
    @State private var isScanning = false
    @State private var summary: String?
    @State private var modeSelection: ModeSelection = .auto

    /// Detection is right nearly always, so it stays the default. The override is
    /// here for the case it cannot call — a series folder with unconventional
    /// season names reads as a library, and nothing in the tree says otherwise.
    enum ModeSelection: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case library = "Library"
        case series = "Series"

        var id: String { rawValue }

        var forced: ScanMode? {
            switch self {
            case .auto: nil
            case .library: .library
            case .series: .singleSeries
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            outputView
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button("Choose Library Folder…", action: chooseFolder)
                .disabled(isScanning)

            Picker("Read as", selection: $modeSelection) {
                ForEach(ModeSelection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(libraryPath == nil || isScanning)
            .onChange(of: modeSelection) { if let libraryPath { scan(libraryPath) } }
            .help("Auto detects whether the folder is a library root or one series. Override if it guesses wrong.")

            Button("Rescan") { if let libraryPath { scan(libraryPath) } }
                .disabled(libraryPath == nil || isScanning)

            if let libraryPath {
                Text(libraryPath.path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
            } else {
                Text("No library selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isScanning {
                ProgressView().controlSize(.small)
            } else if let summary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }

            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(output, forType: .string)
            }
            .disabled(output.isEmpty)
        }
        .padding(12)
    }

    private var outputView: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(output.isEmpty ? "Choose a TV library root, or a single series folder — either is detected.\n\nThe scan reproduces how Emby interprets the tree: episodes, extras and their parents, and the display sequence a client would render." : output)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Select a TV library root, or a single series folder — either is detected."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        libraryPath = url
        // A new folder gets a fresh detection rather than inheriting the last override.
        modeSelection = .auto
        scan(url)
    }

    private func scan(_ url: URL) {
        isScanning = true
        summary = nil
        output = ""
        let forced = modeSelection.forced

        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, any Error> in
                do {
                    let scan = try LibraryScanner().scan(root: url, forcing: forced)
                    let text = LibraryReport().render(scan)
                    return .success(text)
                } catch {
                    return .failure(error)
                }
            }.value

            switch result {
            case .success(let text):
                output = text
                summary = "\(text.split(separator: "\n").count) lines"
            case .failure(let error):
                output = "Scan failed.\n\n\(error)"
                summary = "failed"
            }
            isScanning = false
        }
    }
}
