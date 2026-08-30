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
    @State private var selectedEpisode: URL?
    @State private var showingReport = false

    /// Which column was last interacted with.
    ///
    /// This cannot be inferred from the selections: choosing a series immediately
    /// auto-selects its first season so the episode pane is not empty, which would
    /// make a "most specific selection wins" rule never resolve to the series.
    @State private var focus: Focus = .series

    enum Focus { case series, season, episode }

    @State private var inspectorPresented = true
    @State private var extrasPresented = false
    @State private var extrasHeight: CGFloat = 240
    @State private var extrasFilter: ExtrasDrawer.ExtrasFilter = .all
    @State private var capability: Capability = .details
    @State private var inspection: NFOInspection?
    @State private var inspectionError: String?

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
        // A plain stack, not a VSplitView: VSplitView negotiates widths with its
        // children and squeezed the sidebar below its stated minimum, so the
        // series column collapsed and clipped its rows.
        VStack(spacing: 0) {
            NavigationSplitView {
                SeriesColumn(series: payload?.resolved ?? [], selection: seriesSelection)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 300)
            } content: {
                SeasonColumn(series: currentSeries, selection: seasonSelection)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            } detail: {
                EpisodeColumn(series: currentSeries, season: currentSeason, selection: episodeSelection)
            }
            .navigationSplitViewStyle(.balanced)
            .frame(maxHeight: .infinity)

            if extrasPresented {
                ExtrasResizeHandle(height: $extrasHeight)
                ExtrasDrawer(target: inspectorTarget, selection: $extrasFilter)
                    .frame(height: extrasHeight)
            }
        }
        .inspector(isPresented: $inspectorPresented) {
            InspectorView(
                target: inspectorTarget,
                inspection: inspection,
                loadError: inspectionError,
                capability: $capability
            )
        }
        .toolbar { toolbarContent }
        .overlay { emptyState }
        .sheet(isPresented: $showingReport) { reportSheet }
        .onChange(of: inspectorTarget) {
            loadInspection()
            // The folder list is fixed, but a filter narrowing to an empty folder
            // reads as a bug when the selection changes underneath it.
            extrasFilter = .all
            // Capabilities differ by level, so a selection can stop existing when
            // the target does. Keep it when it still applies — stepping through
            // episodes comparing subtitles should not reset the pane every time.
            if let level = inspectorTarget?.level, !capability.applies(to: level) {
                capability = .details
            }
        }
        .task(id: payloadStamp) { loadInspection() }
        .task {
            // Development affordance: HT_LIBRARY=<path> loads a tree at launch so
            // the window can be exercised without going through the picker.
            guard libraryPath == nil,
                  let path = ProcessInfo.processInfo.environment["HT_LIBRARY"]
            else { return }
            let url = URL(fileURLWithPath: path)
            libraryPath = url
            scan(url)
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    // MARK: - Derived state

    private var seriesSelection: Binding<URL?> {
        Binding {
            selectedSeries
        } set: { newValue in
            selectedSeries = newValue
            focus = .series
            // Populate the episode pane, without claiming the user asked for it.
            selectedSeason = payload?.resolved
                .first { $0.series.folder == newValue }?
                .seasons.first?.number
            selectedEpisode = nil
        }
    }

    private var seasonSelection: Binding<Int?> {
        Binding {
            selectedSeason
        } set: { newValue in
            selectedSeason = newValue
            focus = .season
            selectedEpisode = nil
        }
    }

    private var episodeSelection: Binding<URL?> {
        Binding {
            selectedEpisode
        } set: { newValue in
            selectedEpisode = newValue
            focus = newValue == nil ? .season : .episode
        }
    }

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

    private var currentEpisode: ResolvedEpisode? {
        guard let selectedEpisode else { return nil }
        return currentSeason?.episodes.first { $0.episode.file == selectedEpisode }
    }

    /// Follows the focused column, falling back outward when the focused level has
    /// nothing selected.
    private var inspectorTarget: InspectorTarget? {
        guard let currentSeries else { return nil }

        if focus == .episode, let currentEpisode {
            return .episode(currentEpisode)
        }
        if focus != .series, let currentSeason {
            let scanned = currentSeries.series.seasons.first { $0.number == currentSeason.number }
            return .season(series: currentSeries, season: currentSeason, scanned: scanned)
        }
        return .series(currentSeries)
    }

    /// Changes whenever a scan replaces the data, so the drawer re-reads from disk.
    private var payloadStamp: URL? { payload?.result.root }

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

            Button {
                extrasPresented.toggle()
            } label: {
                Label("Extras", systemImage: "paperclip")
            }
            .help("Show the extras belonging to the selected item and everything beneath it.")

            Button {
                inspectorPresented.toggle()
            } label: {
                Label("Details", systemImage: "sidebar.right")
            }
            .help("Show the NFO behind the selected series, season or episode.")
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

    /// Read on demand rather than retained from the scan: the file is small, and
    /// re-reading means an NFO edited outside the app shows its current contents
    /// as soon as it is reselected.
    private func loadInspection() {
        inspection = nil
        inspectionError = nil
        guard let url = inspectorTarget?.nfoURL else { return }

        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<NFOInspection, any Error> in
                do { return .success(try NFOInspection.load(contentsOf: url)) }
                catch { return .failure(error) }
            }.value

            // The selection may have moved on while this was loading.
            guard inspectorTarget?.nfoURL == url else { return }

            switch outcome {
            case .success(let value): inspection = value
            case .failure(let error): inspectionError = "\(error)"
            }
        }
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
                selectedEpisode = nil
                focus = .series
            case .failure(let error):
                payload = nil
                scanError = "\(error)"
            }
            isScanning = false
        }
    }
}
