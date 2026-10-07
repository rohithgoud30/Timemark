import AppKit
import AVFoundation

struct Note: Codable, Identifiable, Hashable {
    var id = UUID()
    var time: Double
    var text: String
}

extension Double {
    /// 75 -> "1:15", 3725 -> "1:02:05"
    var timestamp: String {
        let s = isFinite ? max(0, Int(self)) : 0
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

@MainActor final class LibraryModel: ObservableObject {
    @Published private(set) var folder: URL?
    @Published private(set) var videos: [URL] = []
    @Published private(set) var current: URL?
    @Published private(set) var notes: [Note] = []
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    /// Width / height of the current video, so the player has no letterbox bars.
    @Published private(set) var videoAspect: CGFloat = 16.0 / 9.0
    @Published private(set) var noteCounts: [URL: Int] = [:]
    private var infos: [URL: VideoInfo] = [:]
    /// Bumped by the Add Note command; the notes pane focuses its composer when it changes.
    @Published var composeRequest = 0
    @Published var errorMessage: String?

    let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private let defaults = UserDefaults.standard

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = t.seconds
                if let d = self.player.currentItem?.duration.seconds, d.isFinite { self.duration = d }
            }
        }
        statusObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        }
        restoreFolder()
    }

    // MARK: Folder (sandboxed: the user picks it, a security-scoped bookmark remembers it)

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder that holds your videos. Notes are saved next to each video."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: "folderBookmark")
        }
        load(folder: url)
    }

    private func restoreFolder() {
        guard let data = defaults.data(forKey: "folderBookmark") else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        load(folder: url)
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: "folderBookmark")
        }
    }

    private func load(folder url: URL) {
        folder?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        folder = url
        let all = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])?.allObjects as? [URL] ?? []
        videos = all
            .filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        infos = Dictionary(uniqueKeysWithValues: videos.map { ($0, VideoInfo(url: $0)) })
        noteCounts = Dictionary(uniqueKeysWithValues: videos.map { ($0, readNotes(for: $0).count) })
        let last = defaults.string(forKey: "lastVideo").flatMap { path in videos.first { $0.path == path } }
        if let video = last ?? videos.first { open(video) } else { current = nil; notes = [] }
    }

    // MARK: Videos

    func open(_ url: URL) {
        guard url != current else { return }
        current = url
        time = 0
        duration = 0
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        // Read length and shape from the file, so the ruler and player size are right before playback starts.
        Task {
            let asset = AVURLAsset(url: url)
            if let length = try? await asset.load(.duration).seconds, length.isFinite, self.current == url {
                self.duration = length
            }
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return }
            let shown = size.applying(transform)
            if self.current == url, shown.height != 0 { self.videoAspect = abs(shown.width / shown.height) }
        }
        defaults.set(url.path, forKey: "lastVideo")
        notes = readNotes(for: url)
    }

    func openAdjacent(_ step: Int) {
        guard let current, let i = videos.firstIndex(of: current), videos.indices.contains(i + step) else { return }
        open(videos[i + step])
    }

    var hasPrevious: Bool { current.flatMap { videos.firstIndex(of: $0) }.map { $0 > 0 } ?? false }
    var hasNext: Bool { current.flatMap { videos.firstIndex(of: $0) }.map { $0 < videos.count - 1 } ?? false }

    func info(for url: URL) -> VideoInfo { infos[url] ?? VideoInfo(url: url) }

    // MARK: Playback

    func togglePlayback() { isPlaying ? player.pause() : player.play() }
    func pause() { player.pause() }
    func skip(by seconds: Double) { seek(to: time + seconds) }

    func seek(to t: Double) {
        let clamped = min(max(0, t), duration > 0 ? duration : t)
        time = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Notes (saved as <video>.notes.json beside the video, with undo)

    func notesURL(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("notes.json")
    }

    private func readNotes(for video: URL) -> [Note] {
        (try? JSONDecoder().decode([Note].self, from: Data(contentsOf: notesURL(for: video)))) ?? []
    }

    func addNote(_ text: String, at time: Double, undoManager: UndoManager?) {
        insert(Note(time: time, text: text), undoManager)
    }

    func deleteNotes(_ ids: Set<UUID>, undoManager: UndoManager?) {
        ids.forEach { remove($0, undoManager) }
    }

    func editNote(_ id: UUID, text: String, undoManager: UndoManager?) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].text != text else { return }
        let old = notes[i].text
        notes[i].text = text
        save()
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.editNote(id, text: old, undoManager: undoManager) }
        }
        undoManager?.setActionName("Edit Note")
    }

    private func insert(_ note: Note, _ undoManager: UndoManager?) {
        notes.append(note)
        notes.sort { $0.time < $1.time }
        save()
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.remove(note.id, undoManager) }
        }
        undoManager?.setActionName("Add Note")
    }

    private func remove(_ id: UUID, _ undoManager: UndoManager?) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        notes.removeAll { $0.id == id }
        save()
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.insert(note, undoManager) }
        }
        undoManager?.setActionName("Delete Note")
    }

    private func save() {
        guard let current else { return }
        let url = notesURL(for: current)
        noteCounts[current] = notes.count
        do {
            if notes.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } else {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(notes).write(to: url, options: .atomic)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Display names for a video. "W1-basics/day-1-getting-started/day-1-getting-started.mp4"
/// becomes week "Week W1", day "Day 1", and the lesson title from a sibling script.json when one exists.
struct VideoInfo {
    let week: String
    let day: String?
    let title: String

    init(url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        let group = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        let weekCode = group.split(separator: "-").first.map(String.init) ?? group
        week = weekCode.range(of: #"^[A-Z]\d+$"#, options: .regularExpression) != nil ? "Week \(weekCode)" : group

        let parts = name.split(separator: "-", maxSplits: 2).map(String.init)
        let hasDay = parts.count == 3 && parts[0].lowercased() == "day"
        day = hasDay ? "Day \(parts[1])" : nil

        struct Script: Decodable { struct Slide: Decodable { let title: String }; let slides: [Slide] }
        let scriptURL = url.deletingLastPathComponent().appendingPathComponent("script.json")
        if let script = try? JSONDecoder().decode(Script.self, from: Data(contentsOf: scriptURL)),
           let first = script.slides.first?.title {
            title = first
        } else {
            let words = (hasDay ? parts[2] : name).replacingOccurrences(of: "-", with: " ")
            title = words.prefix(1).uppercased() + words.dropFirst()
        }
    }
}
