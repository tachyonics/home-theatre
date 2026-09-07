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
    /// A series extra picked out of the season column, which sits alongside the
    /// season selection rather than replacing it: the episode pane keeps showing
    /// the season it was showing, because an extra says nothing about which season
    /// the user was looking at.
    @State private var selectedExtra: URL?
    @State private var selectedEpisode: URL?
    @State private var showingReport = false

    /// Which column was last interacted with.
    ///
    /// This cannot be inferred from the selections: choosing a series immediately
    /// auto-selects its first season so the episode pane is not empty, which would
    /// make a "most specific selection wins" rule never resolve to the series.
    ///
    /// Nor can the selection bindings alone maintain it. `List(selection:)` writes
    /// through its binding only when the value *changes*, so clicking the row that
    /// is already selected — the series you are already inside, to look at the
    /// series — reaches no setter. Such a click does move first responder into that
    /// column, which is what `focusedColumn` is watching for.
    @State private var focus: ColumnFocus = .series

    /// Mirrored into ``focus``, never read directly: it goes nil whenever the
    /// lists give up focus altogether (clicking the toolbar, say), and the
    /// inspector should keep describing whatever it was describing.
    @FocusState private var focusedColumn: ColumnFocus?

    @State private var inspectorPresented = true
    @State private var extrasPresented = false
    @State private var extrasHeight: CGFloat = 240
    @State private var extrasFilter: ExtrasDrawer.ExtrasFilter = .all
    @State private var capability: Capability = .details
    @State private var inspection: NFOInspection?
    @State private var inspectionError: String?

    @Environment(ChangeStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    /// A rescan the user asked for that is waiting on them to accept losing the
    /// queue. Entity ids are issued per scan, so pending changes cannot survive one.
    @State private var rescanAwaitingConfirmation: URL?

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
                SeriesColumn(
                    series: projectedSeries,
                    selection: seriesSelection,
                    focusedColumn: $focusedColumn
                )
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
            } content: {
                SeasonColumn(
                    series: currentSeries,
                    pending: pendingByDestination,
                    selection: seasonSelection,
                    focusedColumn: $focusedColumn,
                    fileAsSeriesExtra: { fileAsExtra(episodeID: $0, folder: $1, under: .series) }
                )
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            } detail: {
                EpisodeColumn(
                    series: currentSeries,
                    season: currentSeason,
                    pending: pendingByDestination,
                    selection: episodeSelection,
                    focusedColumn: $focusedColumn,
                    restoreToSeason: restoreToSeason
                )
            }
            .navigationSplitViewStyle(.balanced)
            .frame(maxHeight: .infinity)

            if extrasPresented {
                ExtrasResizeHandle(height: $extrasHeight)
                ExtrasDrawer(
                    // The drawer describes an item's extras, so it stays on the
                    // item even while the details drawer describes one of them.
                    target: itemTarget,
                    selection: $extrasFilter,
                    fileAsExtra: { fileAsExtra(episodeID: $0, folder: $1, under: .season) },
                    pending: pendingByDestination
                )
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
        .confirmationDialog(
            "Discard \(store.count) pending change\(store.count == 1 ? "" : "s")?",
            isPresented: Binding(
                get: { rescanAwaitingConfirmation != nil },
                set: { if !$0 { rescanAwaitingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard and Rescan", role: .destructive) {
                guard let url = rescanAwaitingConfirmation else { return }
                rescanAwaitingConfirmation = nil
                store.removeAll()
                scan(url)
            }
            Button("Cancel", role: .cancel) { rescanAwaitingConfirmation = nil }
        } message: {
            Text("A rescan reissues every entity id, so queued changes could no longer be matched to what they were made against.")
        }
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
        .onChange(of: focusedColumn) { _, moved in
            if let moved { focus = moved }
        }
        .onChange(of: store.appliedCount) { advancePastAppliedChanges() }
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
            selectedSeason = projectedSeries
                .first { $0.series.folder == newValue }?
                .seasons.first?.number
            selectedExtra = nil
            selectedEpisode = nil
        }
    }

    private var seasonSelection: Binding<SeasonSelection?> {
        Binding {
            // An extra that has stopped existing — its filing was dropped from the
            // queue, say — leaves the column showing nothing selected rather than
            // highlighting a row that is no longer there.
            if currentSeriesExtra != nil, let selectedExtra { return .extra(selectedExtra) }
            return selectedSeason.map(SeasonSelection.season)
        } set: { newValue in
            focus = .season
            switch newValue {
            case .season(let number):
                selectedSeason = number
                selectedExtra = nil
                selectedEpisode = nil
            case .extra(let file):
                // The season stays as it was: the episode pane is not what the
                // user was changing, and emptying it would cost them their place.
                selectedExtra = file
            case nil:
                selectedExtra = nil
            }
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
        return projectedSeries.first { $0.series.folder == selectedSeries }
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

    /// The selected series extra, labelled the way a collected one is so the two
    /// describe themselves identically.
    ///
    /// Resolved against the projected series each time rather than stored, so an
    /// extra that only exists because something is queued stops being selected the
    /// moment that change is dropped.
    private var currentSeriesExtra: OwnedExtra? {
        guard let selectedExtra,
              let extra = currentSeries?.series.extras.first(where: { $0.file == selectedExtra })
        else { return nil }
        return OwnedExtra(extra: extra, ownerLabel: ExtraCollector.seriesLabel, isDirect: true)
    }

    /// The item the browsing columns have selected: follows the focused column,
    /// falling back outward when the focused level has nothing selected.
    private var itemTarget: InspectorTarget? {
        guard let currentSeries else { return nil }

        if focus == .episode, let currentEpisode {
            return .episode(currentEpisode)
        }
        // A selected series extra belongs to the series, so that is the item it
        // leaves behind for anything scoped to one.
        if focus == .season, currentSeriesExtra != nil {
            return .series(currentSeries)
        }
        if focus != .series, let currentSeason {
            let scanned = currentSeries.series.seasons.first { $0.number == currentSeason.number }
            return .season(series: currentSeries, season: currentSeason, scanned: scanned)
        }
        return .series(currentSeries)
    }

    /// What the details drawer describes: the selected extra while the season
    /// column is the one being worked in, and the item itself otherwise.
    private var inspectorTarget: InspectorTarget? {
        if focus == .season, let currentSeriesExtra {
            return .extra(currentSeriesExtra)
        }
        return itemTarget
    }

    /// Changes whenever a scan replaces the data, so the drawer re-reads from disk.
    private var payloadStamp: URL? { payload?.result.root }

    /// The queue projected onto the scan it was made against.
    ///
    /// Read from the *scanned* result, never the projected one: a filing is queued
    /// against files that are still where the scan found them, and the projection
    /// describes a disk that does not exist yet.
    ///
    /// Derived rather than stored: the queue and the scan are each the single
    /// source of their own truth, and a cached projection would be one more thing
    /// to invalidate every time either moves.
    private var pendingFilings: [PendingFiling] {
        guard let payload else { return [] }
        return store.changeSet.pendingFilings(in: payload.result)
    }

    /// Which files in the browser are there because something is queued.
    private var pendingByDestination: [URL: PendingFiling] {
        Dictionary(pendingFilings.map { ($0.destination, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// What the browser draws: the library with every queued filing already carried
    /// out. An episode dropped on an extras folder leaves its season and appears in
    /// that folder immediately, badged as pending — the change is shown as the
    /// outcome the user asked for, not as an annotation on the state they left.
    ///
    /// Display order is re-derived because a season that has lost an episode
    /// renumbers, and the ordering is the whole point of that column. It costs
    /// nothing in the ordinary case: an empty queue short-circuits to the resolved
    /// series the scan already produced.
    private var projectedSeries: [ResolvedSeries] {
        guard let payload else { return [] }
        let filings = pendingFilings
        guard !filings.isEmpty else { return payload.resolved }

        let resolver = DisplayOrderResolver()
        return payload.result.applyingPendingFilings(filings).series.map(resolver.resolve)
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
                if let libraryPath { requestScan(libraryPath) }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(libraryPath == nil || isScanning)

            Spacer()

            if isScanning {
                ProgressView().controlSize(.small)
            }

            Button {
                openWindow(id: PendingChangesWindow.id)
            } label: {
                Label("Pending Changes", systemImage: "tray.full")
            }
            .badge(store.count)
            .help("Review, apply or discard the changes queued so far.")

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
        requestScan(url)
    }

    /// Moves the scan on to the disk as it now is, once a change has been applied.
    ///
    /// Applying moves files; it does not re-read the tree. The scan behind the
    /// browser still describes where everything was, and the queue that was
    /// projecting the difference has just lost the action — so without this the
    /// change would appear to undo itself the moment it was carried out.
    ///
    /// It is the same projection the browser was already drawing, kept rather than
    /// recomputed from a preview: the extra it produces was built to equal what a
    /// rescan finds, so adopting it is exact and costs no filesystem work. A rescan
    /// would also reissue every entity id and take the rest of the queue with it,
    /// which is precisely what must not happen while other changes are still
    /// waiting to be applied.
    ///
    /// Idempotent: a filing already folded in names an episode this model no longer
    /// has, so it resolves to nothing and is skipped. Actions carrying no intent
    /// change nothing here — nothing in the browser was previewing them either.
    private func advancePastAppliedChanges() {
        guard let current = payload else { return }
        let filings = store.applied.pendingFilings(in: current.result)
        guard !filings.isEmpty else { return }

        let advanced = current.result.applyingPendingFilings(filings)
        let resolver = DisplayOrderResolver()
        payload = ScanPayload(
            result: advanced,
            resolved: advanced.series.map(resolver.resolve),
            // Regenerated with the rest: a report describing the tree before the
            // change would be a stale answer to "what is on disk".
            reportText: LibraryReport().render(advanced)
        )
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

    /// Every route to a scan comes through here, so the queue cannot be lost by
    /// whichever button the user happened to press.
    private func requestScan(_ url: URL) {
        if store.isEmpty {
            scan(url)
        } else {
            rescanAwaitingConfirmation = url
        }
    }

    // MARK: - Editing

    /// Queues the one action that turns an episode into an extra of its own season,
    /// or of the series above it.
    ///
    /// Both come from the episode, not from whatever the view is scoped to: an
    /// extras folder sits under the item's own folder, and an episode has no folder
    /// of its own, so only its own ancestors are destinations. Which of the two is
    /// the user's decision, and it is the section they dropped onto that says so.
    private func fileAsExtra(episodeID: UUID, folder: ExtrasFolder, under owner: ExtrasOwner) -> Bool {
        guard let location = payload?.result.locate(episode: episodeID) else { return false }

        let action = switch owner {
        case .series: ExtrasFiling.action(episode: location.episode, in: location.series, folder: folder)
        case .season: ExtrasFiling.action(episode: location.episode, in: location.season, folder: folder)
        }
        guard let action else { return false }

        // Filed, not added: a second filing of the same episode is the user
        // revising one decision, and the queue records what will be true rather
        // than the route they took to it.
        store.file(action, to: location.entityRef)
        return true
    }

    /// Puts a queued episode back where it came from, by forgetting the filing that
    /// took it out.
    ///
    /// Nothing has been applied, so the episode is still in its season on disk and
    /// there is nothing to move — undoing the decision is the whole of the change.
    /// An episode with no filing queued, and one whose season is not the one being
    /// shown, are both refused: the first would mean nothing, and the second would
    /// quietly do something other than what the drop said.
    private func restoreToSeason(episodeID: UUID) -> Bool {
        guard let filing = pendingFilings.first(where: { $0.episode.id == episodeID }),
              filing.series.folder == selectedSeries,
              // Where the browser will draw it once the filing is gone, which is
              // the pane it had to be dropped on for the drop to mean this.
              (filing.episode.displaySeason ?? filing.episode.season ?? 0) == selectedSeason
        else { return false }

        return store.cancelFilings(forEntityID: episodeID)
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
                selectedExtra = nil
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
