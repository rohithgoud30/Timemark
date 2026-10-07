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

/// The timeline ruler under the player. Each note hangs from it as a pin.
/// Hover a pin to read the note, click it to jump there. When playback passes a note, its text shows on the ruler.
struct MarkerStrip: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var hovered: Note?
    static let height: CGFloat = 78
    private let inset: CGFloat = 20
    private let trackY: CGFloat = 50
    private let cardHalfWidth: CGFloat = 190

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width - inset * 2)
            let duration = library.duration
            let x = { (t: Double) -> CGFloat in
                inset + (duration > 0 ? CGFloat(min(max(t / duration, 0), 1)) * width : 0)
            }
            let played = x(library.time) - inset

            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: width, height: 40)
                    .position(x: inset + width / 2, y: trackY)
                    .onTapGesture { loc in
                        if duration > 0 { library.seek(to: Double(loc.x / width) * duration) }
                    }
                    .accessibilityHidden(true)

                ForEach(ticks(for: duration), id: \.self) { t in
                    VStack(spacing: 3) {
                        Rectangle().fill(.tertiary).frame(width: 1, height: 5)
                        Text(t.timestamp).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                    }
                    .fixedSize()
                    .position(x: x(t), y: trackY + 13)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }

                Capsule().fill(.quaternary)
                    .frame(width: width, height: 3)
                    .position(x: inset + width / 2, y: trackY)
                    .allowsHitTesting(false)
                Capsule().fill(Color.highlighter)
                    .frame(width: max(0, played), height: 3)
                    .position(x: inset + max(0, played) / 2, y: trackY)
                    .allowsHitTesting(false)

                ForEach(library.notes) { note in
                    pin(note).position(x: x(note.time), y: trackY - 9)
                }

                caption(geo: geo, x: x)
            }
        }
        .frame(height: Self.height)
        .background(.bar)
    }

    // MARK: Parts

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

    /// The line above the ruler: the hovered note, else the note playback just passed, else a hint.
    @ViewBuilder
    private func caption(geo: GeometryProxy, x: (Double) -> CGFloat) -> some View {
        if let note = hovered {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(note.time.timestamp).font(.callout.weight(.semibold)).monospacedDigit()
                Text(note.text).font(.noteCallout).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
            .frame(maxWidth: cardHalfWidth * 2)
            .position(x: min(max(x(note.time), cardHalfWidth + 4), geo.size.width - cardHalfWidth - 4), y: 17)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else {
            HStack(spacing: 8) {
                if let note = passedNote {
                    RoundedRectangle(cornerRadius: 1).fill(Color.highlighter).frame(width: 3, height: 16)
                    Text(note.text).font(.noteCallout).lineLimit(1)
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

    /// The most recent note playback has passed within the last 6 seconds.
    private var passedNote: Note? {
        library.notes.last { $0.time <= library.time + 0.25 && library.time - $0.time < 6 }
    }

    /// Ruler ticks: the smallest step that gives at most 10 labels.
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
