import SwiftUI

@main
struct TimemarkApp: App {
    @StateObject private var library = LibraryModel()

    var body: some Scene {
        Window("Timemark", id: "main") {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 900, minHeight: 420)
        }
        .defaultSize(width: 1440, height: 640)
        .commands {
            SidebarCommands()
            InspectorCommands()
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { library.chooseFolder() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Playback") { Group {
                // Space toggles playback when the player has focus (AVPlayerView's own shortcut),
                // so this item has no plain-Space equivalent that would swallow spaces in text fields.
                Button(library.isPlaying ? "Pause" : "Play") { library.togglePlayback() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Divider()
                Button("Skip Back 10 Seconds") { library.skip(by: -10) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Skip Forward 10 Seconds") { library.skip(by: 10) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Divider()
                Button("Previous Video") { library.openAdjacent(-1) }
                    .keyboardShortcut("[")
                    .disabled(!library.hasPrevious)
                Button("Next Video") { library.openAdjacent(1) }
                    .keyboardShortcut("]")
                    .disabled(!library.hasNext)
            }
            .disabled(library.current == nil) }
            CommandMenu("Notes") {
                Button("Add Note at Current Time") { library.composeRequest += 1 }
                    .keyboardShortcut("n")
                    .disabled(library.current == nil)
            }
        }
    }
}
