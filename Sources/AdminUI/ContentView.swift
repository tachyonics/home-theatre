import AppKit
import HomeTheatreCore
import SwiftUI

/// Everything one scan produced. Computed off the main actor and handed back in
/// one piece so the views never re-derive anything while rendering.
struct ScanPayload: Sendable {
    var result: LibraryScanResult
    var resolved: [ResolvedSeries]
    var reportText: String
}

@MainActor
struct ContentView: View {
    @State private var libraryPath: URL?
    @State private var payload: ScanPayload?
    @State private var isScanning = false
    @State private var scanError: String?
    @State private var modeSelection: ModeSelection = .auto

    @State private var selectedSeries: URL?
    @State private var selectedSeason: Int?
    @State private var showingReport = false

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
        NavigationSplitView {
            SeriesColumn(series: payload?.resolved ?? [], selection: $selectedSeries)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } content: {
            SeasonColumn(series: currentSeries, selection: $selectedSeason)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            EpisodeColumn(series: currentSeries, season: currentSeason)
        }
        .toolbar { toolbarContent }
        .overlay { emptyState }
        .sheet(isPresented: $showingReport) { reportSheet }
        .onChange(of: selectedSeries) { selectedSeason = defaultSeason }
        .frame(minWidth: 900, minHeight: 560)
    }

    // MARK: - Derived state

    private var currentSeries: ResolvedSeries? {
        guard let selectedSeries else { return nil }
        return payload?.resolved.first { $0.series.folder == selectedSeries }
    }

    private var currentSeason: ResolvedSeason? {
        guard let selectedSeason else { return nil }
        return currentSeries?.seasons.first { $0.number == selectedSeason }
    }

    /// Land on the first season rather than an empty pane when a series is picked.
    private var defaultSeason: Int? {
        currentSeries?.seasons.first?.number
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                chooseFolder()
            } label: {
                Label("Choose Folder", systemImage: "folder")
            }
            .disabled(isScanning)

            Picker("Read as", selection: $modeSelection) {
                ForEach(ModeSelection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(libraryPath == nil || isScanning)
            .help("Auto detects whether the folder is a library root or one series. Override if it guesses wrong.")

            Button {
                if let libraryPath { scan(libraryPath) }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(libraryPath == nil || isScanning)

            Spacer()

            if isScanning {
                ProgressView().controlSize(.small)
            }

            Button {
                showingReport = true
            } label: {
                Label("Report", systemImage: "doc.plaintext")
            }
            .disabled(payload == nil)
            .help("The full text report — copyable, and diffable between scans.")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let scanError {
            ContentUnavailableView {
                Label("Scan failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(scanError).font(.system(.caption, design: .monospaced))
            }
        } else if payload == nil && !isScanning {
            ContentUnavailableView {
                Label("No library loaded", systemImage: "tv")
            } description: {
                Text("Choose a TV library root, or a single series folder — either is detected.")
            } actions: {
                Button("Choose Folder…", action: chooseFolder)
            }
        }
    }

    private var reportSheet: some View {
        VStack(spacing: 0) {
            HStack {
                if let payload {
                    Text("\(payload.result.mode.description) · \(payload.result.series.count) series")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(payload?.reportText ?? "", forType: .string)
                }
                Button("Done") { showingReport = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)

            Divider()

            ScrollView([.vertical, .horizontal]) {
                Text(payload?.reportText ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(width: 860, height: 620)
    }

    // MARK: - Scanning

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
        scanError = nil
        let forced = modeSelection.forced

        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ScanPayload, any Error> in
                do {
                    let result = try LibraryScanner().scan(root: url, forcing: forced)
                    let resolver = DisplayOrderResolver()
                    return .success(
                        ScanPayload(
                            result: result,
                            resolved: result.series.map(resolver.resolve),
                            reportText: LibraryReport().render(result)
                        )
                    )
                } catch {
                    return .failure(error)
                }
            }.value

            switch outcome {
            case .success(let value):
                payload = value
                // Keep the current selection when rescanning the same tree.
                if selectedSeries == nil || !value.resolved.contains(where: { $0.series.folder == selectedSeries }) {
                    selectedSeries = value.resolved.first?.series.folder
                }
                selectedSeason = defaultSeason
            case .failure(let error):
                payload = nil
                scanError = "\(error)"
            }
            isScanning = false
        }
    }
}
