import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.undoManager) private var undoManager
    @SceneStorage("showNotes") private var showNotes = true
    /// The AppKit view behind the video + ruler area; its live bounds drive window fitting.
    @State private var detailView: NSView?
    @State private var fitTask: Task<Void, Never>?
    /// True from the moment full screen starts until it has fully ended; auto-fit stays off the whole time.
    @State private var fullScreen = false
    /// True when the user has made the window fill the screen (green button, Fill, or a drag to the edges).
    /// Then the window is left alone and the video fills it on black, like full screen.
    @State private var fillsScreen = false

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            detail
                .inspector(isPresented: $showNotes) {
                    NotesPane()
                        .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
                }
                .toolbar {
                    ToolbarItemGroup {
                        Button("Add Note", systemImage: "pencil.line") { library.composeRequest += 1 }
                            .help("Pause and add a note at this moment (⌘N)")
                            .disabled(library.current == nil)
                        Button("Notes", systemImage: "sidebar.trailing") { showNotes.toggle() }
                            .help(showNotes ? "Hide notes" : "Show notes")
                    }
                }
        }
        .navigationTitle(library.current.map { library.info(for: $0).title } ?? "Timemark")
        .navigationSubtitle(subtitle)
        .onChange(of: library.current) { undoManager?.removeAllActions() }
        .onChange(of: library.composeRequest) { showNotes = true }
        .alert("Notes weren’t saved", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(library.errorMessage ?? "") Check that the video folder isn’t read-only, then try again.")
        }
    }

    /// Layout passes through in-between sizes while panels animate; fit once things have settled.
    private func scheduleFit() {
        fitTask?.cancel()
        fitTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { fitWindow() }
        }
    }

    /// Shrinks or grows the window so the area under the toolbar is exactly video + ruler, keeping the top edge in place.
    /// Measured from the live view at fit time, so stale in-between layout sizes can't throw it off.
    /// Skipped while the user is dragging, in full screen, when the user made the window fill the screen,
    /// and limited to what the screen can fit.
    private func fitWindow() {
        if let window = detailView?.window, let screen = window.screen?.visibleFrame {
            let filled = abs(window.frame.width - screen.width) < 2 && abs(window.frame.height - screen.height) < 2
            if fillsScreen != filled { fillsScreen = filled }
            if filled { return }
        }
        guard !fullScreen, let view = detailView, let window = view.window, !window.inLiveResize,
              !window.styleMask.contains(.fullScreen), view.bounds.width > 0, library.videoAspect > 0 else { return }
        let inset = Self.stageInset * 2
        let ideal = ((view.bounds.width - inset) / library.videoAspect).rounded() + MarkerStrip.height + 1 + inset
        let extra = view.bounds.height - ideal
        guard abs(extra) > 1 else { return }
        var frame = window.frame
        frame.size.height = max(window.minSize.height, frame.height - extra)
        if let screen = window.screen?.visibleFrame { frame.size.height = min(frame.height, screen.height) }
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true, animate: false)
    }

    private var subtitle: String {
        guard let url = library.current else { return "" }
        let info = library.info(for: url)
        return [info.week, info.day].compactMap { $0 }.joined(separator: ", ")
    }

    /// Space around the rounded video card, so its corners read clearly.
    private static let stageInset: CGFloat = 12

    @ViewBuilder private var detail: some View {
        if library.current != nil {
            // One rounded card: the video sized to its own shape, the ruler right under it.
            // The window's height is fitted to this (see fitWindow).
            VStack(spacing: 0) {
                PlayerView(player: library.player)
                    .aspectRatio(library.videoAspect, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(.black)
                Divider()
                MarkerStrip()
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: PlayerView.cornerRadius,
                                                      bottomTrailingRadius: PlayerView.cornerRadius,
                                                      style: .continuous))
            }
            .overlay(RoundedRectangle(cornerRadius: PlayerView.cornerRadius, style: .continuous).strokeBorder(.separator))
            .padding(Self.stageInset)
            // In full screen or a window that fills the screen, the card is centered on black;
            // otherwise the window is fitted so there is no spare height.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(fullScreen || fillsScreen ? Color.black : Color(nsColor: .underPageBackgroundColor))
            .background(HostViewReader(view: $detailView))
            .onChange(of: detailView) {
                fullScreen = detailView?.window?.styleMask.contains(.fullScreen) ?? false
                scheduleFit()
            }
            .onChange(of: library.videoAspect) { scheduleFit() }
            // Refit after panels open or close, after the user's drag ends, and after macOS restores a saved size.
            .onReceive(NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification)) { note in
                if (note.object as? NSView) === detailView { scheduleFit() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)) { note in
                if (note.object as? NSWindow) === detailView?.window { scheduleFit() }
            }
            // Full screen animates the window through many sizes; resizing during that breaks the transition.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
                if (note.object as? NSWindow) === detailView?.window {
                    fullScreen = true
                    fitTask?.cancel()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
                if (note.object as? NSWindow) === detailView?.window {
                    fullScreen = false
                    scheduleFit()
                }
            }
        } else if library.folder == nil {
            ContentUnavailableView {
                Label("Choose your lessons folder", systemImage: "folder")
            } description: {
                Text("Timemark lists every video inside it, grouped by week. Your notes are saved next to each video.")
            } actions: {
                Button("Choose Folder…") { library.chooseFolder() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        } else {
            ContentUnavailableView {
                Label("No videos in this folder", systemImage: "film")
            } description: {
                Text("Timemark looks for MP4, MOV, and M4V files, including inside subfolders.")
            } actions: {
                Button("Choose Another Folder…") { library.chooseFolder() }
            }
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        List(selection: Binding(get: { library.current }, set: { if let url = $0 { library.open(url) } })) {
            ForEach(groups, id: \.week) { group in
                Section(group.week) {
                    ForEach(group.videos, id: \.self) { url in
                        let info = library.info(for: url)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.title).lineLimit(1)
                            if let day = info.day {
                                Text(day).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                        .badge(library.noteCounts[url] ?? 0)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .toolbar {
            Button("Choose Folder", systemImage: "folder") { library.chooseFolder() }
                .help("Choose a different lessons folder (⌘O)")
        }
    }

    private var groups: [(week: String, videos: [URL])] {
        let byWeek = Dictionary(grouping: library.videos) { library.info(for: $0).week }
        return byWeek.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { ($0, byWeek[$0]!) }
    }
}
