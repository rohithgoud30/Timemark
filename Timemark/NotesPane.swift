import SwiftUI

struct NotesPane: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.undoManager) private var undoManager
    @State private var selection = Set<UUID>()
    @State private var editing: UUID?
    @State private var draft = ""
    @State private var draftTime: Double?
    @State private var composing = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
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
        .animation(.snappy(duration: 0.2), value: composing)
        // Next run-loop tick, so focus lands after the composer appears and the player gives up first responder.
        .onChange(of: library.composeRequest) {
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
            selection = []
            editing = nil
            closeComposer()
        }
    }

    /// The note playback most recently passed, marked with the highlighter.
    private var currentNote: Note? {
        library.notes.last { $0.time <= library.time + 0.25 }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Notes").font(.title3.weight(.semibold))
            Spacer()
            if !library.notes.isEmpty {
                Text(library.notes.count == 1 ? "1 note" : "\(library.notes.count) notes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
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
