import SwiftUI

extension Color {
    /// The one accent: a highlighter yellow, the same yellow the lesson videos use for "what's being said now".
    /// Darker in light mode so it holds up on white.
    static let highlighter = Color(nsColor: NSColor(name: "highlighter") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.949, green: 0.788, blue: 0.298, alpha: 1)   // #F2C94C
            : NSColor(srgbRed: 0.859, green: 0.620, blue: 0.051, alpha: 1)   // #DB9E0D
    })
}

extension Font {
    /// Notes are the user's own words, set in the system serif (New York) like writing in a margin.
    static let note = Font.system(.body, design: .serif)
    static let noteCallout = Font.system(.callout, design: .serif)
}
