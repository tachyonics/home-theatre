import AppKit
import HomeTheatreCore
import SwiftUI

@MainActor
struct ContentView: View {
    @State private var libraryPath: URL?
    @State private var output = ""
    @State private var isScanning = false
    @State private var summary: String?

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
            Text(output.isEmpty ? "Choose a TV library folder to scan.\n\nThe scan reproduces how Emby interprets the tree: episodes, extras and their parents, and the display sequence a client would render." : output)
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
        panel.message = "Select the root of a TV library — the folder containing one directory per series."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        libraryPath = url
        scan(url)
    }

    private func scan(_ url: URL) {
        isScanning = true
        summary = nil
        output = ""

        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, any Error> in
                do {
                    let scan = try LibraryScanner().scan(root: url)
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
