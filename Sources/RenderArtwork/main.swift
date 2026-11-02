import Foundation
import FocusPilotCore
import RaccoonRig

// Usage:
//   RenderArtwork icon <AppIcon.icon>     Icon Composer file for actool
//   RenderArtwork glyphs <directory>      menu bar glyph review images
//   RenderArtwork chrome-icons <directory> Chrome extension icons
//   RenderArtwork raccoon <Artwork/Raccoon> <directory>
//                                         raccoon layer strips and raccoon.json
//   RenderArtwork raccoon-contact-sheet <directory> <out.png>
//                                         every raccoon pose, at rest and moved

let arguments = Array(CommandLine.arguments.dropFirst())

switch (arguments.first, arguments.count) {
case ("icon", 2):
    try AppIconArtwork.writeIconComposerFile(to: URL(filePath: arguments[1]))
case ("glyphs", 2):
    try MainActor.assumeIsolated { try GlyphPreviews.write(to: URL(filePath: arguments[1])) }
case ("chrome-icons", 2):
    try MainActor.assumeIsolated { try ChromeIcons.write(to: URL(filePath: arguments[1])) }
case ("raccoon", 3):
    let output = try RaccoonArtBuilder.build(artworkDirectory: URL(filePath: arguments[1]))
    try RaccoonArtBuilder.write(output, to: URL(filePath: arguments[2]))
case ("raccoon-contact-sheet", 3):
    try MainActor.assumeIsolated {
        try RaccoonContactSheet.write(artDirectory: URL(filePath: arguments[1]), to: URL(filePath: arguments[2]))
    }
default:
    FileHandle.standardError.write(Data("usage: RenderArtwork icon <out.icon> | glyphs <directory> | chrome-icons <directory> | raccoon <sheet directory> <directory> | raccoon-contact-sheet <directory> <out.png>\n".utf8))
    exit(64)
}
