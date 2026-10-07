import AVKit
import SwiftUI

/// The system player: play/pause, scrubber, volume, speed menu, frame stepping,
/// Picture in Picture, and full screen, the same controls as QuickTime Player.
struct PlayerView: NSViewRepresentable {
    static let cornerRadius: CGFloat = 12
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.showsFrameSteppingButtons = true
        view.allowsPictureInPicturePlayback = true
        view.speeds = AVPlaybackSpeed.systemDefaultSpeeds
        // Round the player's own layer (top corners only; the ruler finishes the card below).
        // SwiftUI clipping doesn't reliably reach this AppKit view, which made the corners flicker and look jagged.
        view.wantsLayer = true
        view.layer?.cornerRadius = PlayerView.cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// The timeline under the player, YouTube style: the bar is split into one segment per chapter, the segment
/// under the pointer grows, and a preview (thumbnail, chapter, time) floats above it. Notes hang from the bar as pins.
/// Hover a pin to read the note; click the bar or a pin to jump there.
struct MarkerStrip: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var hovered: Note?
    static let height: CGFloat = 78
    private let inset: CGFloat = 20
    private let trackY: CGFloat = 50
    private let cardHalfWidth: CGFloat = 190
    private let gap: CGFloat = 4
    private let previewWidth: CGFloat = 208
    private let previewHeight: CGFloat = 166

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width - inset * 2)
            let duration = library.duration
            let x = { (t: Double) -> CGFloat in
                inset + (duration > 0 ? CGFloat(min(max(t / duration, 0), 1)) * width : 0)
            }

            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: width, height: 40)
                    .position(x: inset + width / 2, y: trackY)
                    .onTapGesture { loc in
                        if duration > 0 { library.seek(to: Double(loc.x / width) * duration) }
                    }
                    .onContinuousHover { phase in
                        if case .active(let loc) = phase, duration > 0 {
                            library.hoverTime = min(max(Double(loc.x / width), 0), 1) * duration
                        } else {
                            library.hoverTime = nil
                        }
                    }
                    .accessibilityHidden(true)

                ForEach(ticks(for: duration), id: \.self) { t in
                    Text(t.timestamp).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                        .fixedSize()
                        .position(x: x(t), y: trackY + 17)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                ForEach(segments(duration), id: \.start) { seg in
                    segment(seg, duration: duration, x: x)
                }

                ForEach(library.notes) { note in
                    pin(note).position(x: x(note.time), y: trackY - 10)
                }

                caption(geo: geo, x: x)
            }
            // The preview floats above the timeline, over the bottom of the video.
            .overlay(alignment: .topLeading) {
                if let t = library.hoverTime, hovered == nil, !library.chapters.isEmpty {
                    preview(at: t)
                        .position(x: min(max(x(t), previewWidth / 2 + 8), geo.size.width - previewWidth / 2 - 8),
                                  y: -previewHeight / 2 - 8)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: Self.height)
    }

    // MARK: Parts

    /// The bar's segments: one per chapter, or one for the whole video when it has no chapters.
    private func segments(_ duration: Double) -> [(start: Double, end: Double)] {
        guard duration > 0 else { return [] }
        let starts = library.chapters.isEmpty ? [0] : library.chapters.map(\.start)
        return starts.enumerated().map { i, start in (start, i + 1 < starts.count ? starts[i + 1] : duration) }
    }

    private func segment(_ seg: (start: Double, end: Double), duration: Double, x: (Double) -> CGFloat) -> some View {
        let left = x(seg.start) + (seg.start > 0 ? gap / 2 : 0)
        let right = x(seg.end) - (seg.end < duration ? gap / 2 : 0)
        let width = max(0, right - left)
        let played = min(max(x(library.time) - left, 0), width)
        let isHot = library.hoverTime.map { $0 >= seg.start && $0 < seg.end } ?? false
        return ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            Capsule().fill(Color.highlighter).frame(width: played)
        }
        .frame(width: width, height: isHot ? 8 : 4)
        .animation(.snappy(duration: 0.12), value: isHot)
        .position(x: left + width / 2, y: trackY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func preview(at t: Double) -> some View {
        let chapter = library.chapter(at: t)
        return VStack(alignment: .leading, spacing: 6) {
            Group {
                if let chapter, let image = library.chapterThumbnails[chapter.start] {
                    Image(nsImage: image).resizable().aspectRatio(16 / 9, contentMode: .fill)
                } else {
                    Rectangle().fill(.black)
                }
            }
            .frame(width: previewWidth - 16, height: (previewWidth - 16) * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(chapter?.title ?? "").font(.callout.weight(.semibold)).lineLimit(1)
            Text(t.timestamp).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(width: previewWidth, height: previewHeight, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .accessibilityHidden(true)
    }

    private func pin(_ note: Note) -> some View {
        let isHovered = hovered?.id == note.id
        return VStack(spacing: 0) {
            Circle()
                .fill(Color.highlighter)
                .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                .frame(width: 11, height: 11)
            Rectangle().fill(Color.highlighter).frame(width: 2, height: 8)
        }
        .scaleEffect(isHovered ? 1.35 : 1, anchor: .bottom)
        .animation(.snappy(duration: 0.15), value: isHovered)
        .frame(width: 22, height: 26)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = note } else if hovered?.id == note.id { hovered = nil }
        }
        .onTapGesture { library.seek(to: note.time) }
        .accessibilityElement()
        .accessibilityLabel("Note at \(note.time.timestamp)")
        .accessibilityValue(note.text)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { library.seek(to: note.time) }
    }

    /// The line above the bar: the hovered note, else the note playback just passed, else the current chapter,
    /// else a hint. Without chapters, hovering the bar shows the time there.
    @ViewBuilder
    private func caption(geo: GeometryProxy, x: (Double) -> CGFloat) -> some View {
        if let note = hovered {
            card(at: note.time, geo: geo, x: x) {
                Text(note.time.timestamp).font(.callout.weight(.semibold)).monospacedDigit()
                Text(note.text).font(.noteCallout).lineLimit(1)
            }
        } else if let t = library.hoverTime, library.chapters.isEmpty {
            card(at: t, geo: geo, x: x) {
                Text(t.timestamp).font(.callout.weight(.semibold)).monospacedDigit()
            }
        } else {
            HStack(spacing: 8) {
                if let note = passedNote {
                    RoundedRectangle(cornerRadius: 1).fill(Color.highlighter).frame(width: 3, height: 16)
                    Text(note.text).font(.noteCallout).lineLimit(1)
                } else if let chapter = library.currentChapter,
                          let number = library.chapters.firstIndex(of: chapter).map({ $0 + 1 }) {
                    Text(chapter.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text("Chapter \(number) of \(library.chapters.count)").font(.caption).foregroundStyle(.secondary)
                } else if library.notes.isEmpty {
                    Text("Notes you add are pinned here. Press ⌘N to write one.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Hover a pin to read its note. Click to jump to it.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width - inset * 2, height: 24)
            .position(x: geo.size.width / 2, y: 17)
            .allowsHitTesting(false)
        }
    }

    /// A small floating card above the bar, centered on a moment and kept inside the strip.
    private func card<Content: View>(at t: Double, geo: GeometryProxy, x: (Double) -> CGFloat,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8, content: content)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
            .frame(maxWidth: cardHalfWidth * 2)
            .position(x: min(max(x(t), cardHalfWidth + 4), geo.size.width - cardHalfWidth - 4), y: 17)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The most recent note playback has passed within the last 6 seconds.
    private var passedNote: Note? {
        library.notes.last { $0.time <= library.time + 0.25 && library.time - $0.time < 6 }
    }

    /// Time labels under the bar: the smallest step that gives at most 10 labels.
    private func ticks(for duration: Double) -> [Double] {
        guard duration > 0 else { return [] }
        let step = [15.0, 30, 60, 120, 300, 600, 900, 1800].first { duration / $0 <= 10 } ?? 3600
        return Array(stride(from: 0, through: duration, by: step))
    }
}

/// Hands SwiftUI the AppKit view behind a region, so its live bounds and window can be read.
struct HostViewReader: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        host.postsFrameChangedNotifications = true
        DispatchQueue.main.async { view = host }
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {}
}
