// fetch-sfsymbol.swift — render real SF Symbols to white template PNGs for
// the menu bar compositor. Usage:
//   swift fetch-sfsymbol.swift <name> [<name> ...]
// Writes glyphs-system/<name>.png (white, 144px tall, natural aspect).
import AppKit

let outDir = URL(fileURLWithPath: "glyphs-system", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for name in CommandLine.arguments.dropFirst() {
    let config = NSImage.SymbolConfiguration(pointSize: 96, weight: .regular)
        .applying(.init(paletteColors: [.white]))
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
          let img = base.withSymbolConfiguration(config) else {
        print("MISSING \(name)")
        continue
    }
    let size = img.size
    let scale = 144.0 / size.height
    let px = NSSize(width: (size.width * scale).rounded(), height: 144)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width),
        pixelsHigh: Int(px.height), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(origin: .zero, size: px))
    NSGraphicsContext.restoreGraphicsState()
    let url = outDir.appendingPathComponent("\(name).png")
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("OK \(name) \(Int(px.width))x\(Int(px.height))")
}
