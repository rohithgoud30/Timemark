import SwiftUI

struct NotesPane: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.undoManager) private var undoManager
    @State private var selection = Set<UUID>()
    @State private var editing: UUID?
    @State private var draft = ""
    @State private var draftTime: Double?
    @State private var composing = false
    /// Chapters first: each video opens on its chapter list. ⌘N switches to Notes to write.
    @State private var tab = Tab.chapters
    @FocusState private var composerFocused: Bool

    enum Tab { case notes, chapters }

    var body: some View {
        VStack(spacing: 0) {
            header
            // A video without chapters shows its notes instead of an empty list.
            if tab == .chapters && !library.chapters.isEmpty {
                ChaptersList()
            } else {
                notesList
            }
        }
        .animation(.snappy(duration: 0.2), value: composing)
        // Next run-loop tick, so focus lands after the composer appears and the player gives up first responder.
        .onChange(of: library.composeRequest) {
            tab = .notes
            composing = true
            DispatchQueue.main.async { composerFocused = true }
        }
        .onChange(of: composerFocused) { _, focused in
            if focused && draftTime == nil {
                library.pause()
                draftTime = library.time
            }
        }
        .onChange(of: library.current) {
            tab = .chapters
            selection = []
            editing = nil
            closeComposer()
        }
    }

    @ViewBuilder private var notesList: some View {
            List(selection: $selection) {
                ForEach(library.notes) { note in
                    NoteRow(
                        note: note,
                        isCurrent: note.id == currentNote?.id,
                        isEditing: editing == note.id,
                        seek: { library.seek(to: note.time) },
                        commit: { text in
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.isEmpty {
                                library.deleteNotes([note.id], undoManager: undoManager)
                            } else {
                                library.editNote(note.id, text: trimmed, undoManager: undoManager)
                            }
                            editing = nil
                        },
                        cancel: { editing = nil }
                    )
                    .tag(note.id)
                }
            }
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: UUID.self) { ids in
                if ids.count == 1, let id = ids.first, let note = library.notes.first(where: { $0.id == id }) {
                    Button("Go to \(note.time.timestamp)") { library.seek(to: note.time) }
                    Button("Edit Note") { editing = id }
                    Divider()
                }
                if !ids.isEmpty {
                    Button(ids.count == 1 ? "Delete Note" : "Delete \(ids.count) Notes", role: .destructive) {
                        library.deleteNotes(ids, undoManager: undoManager)
                    }
                }
            } primaryAction: { ids in
                // Double-click or Return on a note jumps the video to it.
                if let note = library.notes.first(where: { ids.contains($0.id) }) { library.seek(to: note.time) }
            }
            .onDeleteCommand {
                library.deleteNotes(selection, undoManager: undoManager)
                selection = []
            }
            .overlay {
                if library.notes.isEmpty && library.current != nil && !composing {
                    ContentUnavailableView {
                        Label("No notes yet", systemImage: "pencil.line")
                    } description: {
                        Text("Pause anywhere and press ⌘N. Your note is pinned to that moment in the video.")
                    } actions: {
                        Button("Add Note") { library.composeRequest += 1 }
                    }
                }
            }

            if composing && library.current != nil {
                composer
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
    }

    /// The note playback most recently passed, marked with the highlighter.
    private var currentNote: Note? {
        library.notes.last { $0.time <= library.time + 0.25 }
    }

    private var header: some View {
        HStack {
            Picker("Show", selection: Binding(get: { library.chapters.isEmpty ? .notes : tab }, set: { tab = $0 })) {
                Text(library.chapters.isEmpty ? "Chapters" : "Chapters (\(library.chapters.count))").tag(Tab.chapters)
                Text(library.notes.isEmpty ? "Notes" : "Notes (\(library.notes.count))").tag(Tab.notes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Note at \((draftTime ?? library.time).timestamp)")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Spacer()
                Text("Video paused").font(.caption).foregroundStyle(.secondary)
            }
            TextField("What do you want to remember here?", text: $draft, axis: .vertical)
                .font(.note)
                .textFieldStyle(.plain)
                .lineLimit(3...8)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(composerFocused ? Color.highlighter : Color(nsColor: .separatorColor),
                                      lineWidth: composerFocused ? 2 : 1)
                )
                .focused($composerFocused)
                .onSubmit(addNote)
            HStack {
                Text("Return adds it. Option-Return starts a new line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: closeComposer)
                    .keyboardShortcut(.cancelAction)
                Button("Add Note", action: addNote)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func addNote() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        library.addNote(text, at: draftTime ?? library.time, undoManager: undoManager)
        closeComposer()
    }

    private func closeComposer() {
        draft = ""
        draftTime = nil
        composerFocused = false
        composing = false
    }
}

/// The video's chapters with a thumbnail and start time, like YouTube's chapter list.
/// The chapter playing now is highlighted and kept in view; click one to jump there.
struct ChaptersList: View {
    @EnvironmentObject private var library: LibraryModel
    /// The chapter whose related links popover is open.
    @State private var linksFor: Double?

    var body: some View {
        ScrollViewReader { proxy in
            List(library.chapters) { chapter in
                let isCurrent = chapter == library.currentChapter
                HStack(spacing: 10) {
                    Group {
                        if let image = library.chapterThumbnails[chapter.start] {
                            Image(nsImage: image).resizable().aspectRatio(16 / 9, contentMode: .fill)
                        } else {
                            Rectangle().fill(.quaternary)
                        }
                    }
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isCurrent ? Color.highlighter : .clear, lineWidth: 2))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(chapter.title)
                            .font(.callout.weight(isCurrent ? .semibold : .regular))
                            .lineLimit(2)
                        HStack(spacing: 8) {
                            Text(chapter.start.timestamp)
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            if !chapter.links.isEmpty { linksToggle(chapter) }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                // The row seeks on click; the link icon inside it has its own button and popover.
                .onTapGesture { library.seek(to: chapter.start) }
                .accessibilityAddTraits(.isButton)
                .padding(.vertical, 2)
                .listRowBackground(isCurrent ? Color.highlighter.opacity(0.14) : Color.clear)
                .id(chapter.id)
                .accessibilityLabel("\(chapter.title), at \(chapter.start.timestamp)")
            }
            .scrollContentBackground(.hidden)
            .onChange(of: library.current) { linksFor = nil }
            .onChange(of: library.currentChapter) { _, chapter in
                if let chapter { withAnimation { proxy.scrollTo(chapter.id, anchor: .center) } }
            }
            .overlay {
                if library.chapters.isEmpty && library.current != nil {
                    ContentUnavailableView("No chapters", systemImage: "list.bullet",
                                           description: Text("This video has no chapters."))
                }
            }
        }
    }
}

extension ChaptersList {
    /// A small link icon with a count. Click it for a popover with the chapter's related links,
    /// floating over the list so nothing moves; click a link to open it in the browser.
    fileprivate func linksToggle(_ chapter: Chapter) -> some View {
        let open = linksFor == chapter.start
        return Button {
            linksFor = open ? nil : chapter.start
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "link")
                Text("\(chapter.links.count)").monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(open ? Color.accentColor : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(open ? 1 : 0.6), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Related links")
        .accessibilityLabel("\(chapter.links.count) related links")
        .popover(isPresented: Binding(get: { linksFor == chapter.start },
                                      set: { if !$0, linksFor == chapter.start { linksFor = nil } }),
                 arrowEdge: .trailing) {
            linksPanel(chapter)
        }
    }

    fileprivate func linksPanel(_ chapter: Chapter) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Related links").font(.caption).foregroundStyle(.secondary)
            ForEach(chapter.links, id: \.self) { link in
                Link(destination: link.url) {
                    Label(link.label, systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.link)
                .help(link.url.absoluteString)
            }
        }
        .padding(14)
        .frame(minWidth: 220, maxWidth: 360, alignment: .leading)
    }
}

struct NoteRow: View {
    let note: Note
    let isCurrent: Bool
    let isEditing: Bool
    let seek: () -> Void
    let commit: (String) -> Void
    let cancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // The margin rule: highlighter yellow on the note playback is at.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isCurrent ? Color.highlighter : Color(nsColor: .separatorColor))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Button(action: seek) {
                    Text(note.time.timestamp)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .help("Go to \(note.time.timestamp)")
                .accessibilityLabel("Go to \(note.time.timestamp)")

                if isEditing {
                    TextField("Note", text: $text, axis: .vertical)
                        .font(.note)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit { commit(text) }
                        .onExitCommand(perform: cancel)
                        .onAppear {
                            text = note.text
                            focused = true
                        }
                } else {
                    Text(note.text)
                        .font(.note)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 6)
        .animation(.easeOut(duration: 0.2), value: isCurrent)
    }
}
