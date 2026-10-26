// Places each raw window capture on a 2880 x 1800 background with a caption.
// Usage: swift scripts/compose-screenshots.swift <raw dir> <output dir>
import AppKit

let canvas = NSSize(width: 2880, height: 1800)

let captions: [String: (String, String)] = [
    "devices": ("Only SD cards can be selected",
                "Internal disks, boot disks and disk images are never erasable."),
    "confirm": ("Type the card's size and name to confirm",
                "Nothing is erased until it matches exactly."),
    "erasing": ("Every pass is read back and checked",
                "Random data, with an optional second pass of zeros."),
    "result": ("A signed erase report",
               "Export it as PDF or JSON, signed with Ed25519."),
]

struct Theme {
    let top: NSColor, bottom: NSColor, title: NSColor, subtitle: NSColor, edge: NSColor, shadow: NSColor
}

func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

let themes: [String: Theme] = [
    "light": Theme(top: hex(0xEEF2F8), bottom: hex(0xD5DEEC), title: hex(0x111827), subtitle: hex(0x4B5563),
                   edge: hex(0x000000, 0.12), shadow: hex(0x0F172A, 0.28)),
    "dark": Theme(top: hex(0x1C2436), bottom: hex(0x090C13), title: hex(0xFFFFFF), subtitle: hex(0xA3AEC2),
                  edge: hex(0xFFFFFF, 0.14), shadow: hex(0x000000, 0.65)),
]

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: compose-screenshots.swift <raw dir> <output dir>\n".data(using: .utf8)!)
    exit(2)
}
let rawDir = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let files = try FileManager.default.contentsOfDirectory(at: rawDir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "png" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

for file in files {
    // Names look like "1-devices-light.png".
    let parts = file.deletingPathExtension().lastPathComponent.split(separator: "-").map(String.init)
    guard parts.count == 3, let caption = captions[parts[1]], let theme = themes[parts[2]],
          let window = NSImage(contentsOf: file),
          let windowRep = window.representations.first else { continue }

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width), pixelsHigh: Int(canvas.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = canvas
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Background
    NSGradient(starting: theme.top, ending: theme.bottom)!.draw(in: NSRect(origin: .zero, size: canvas), angle: -90)

    // Caption
    let center = NSMutableParagraphStyle()
    center.alignment = .center
    let title = NSAttributedString(string: caption.0, attributes: [
        .font: NSFont.systemFont(ofSize: 104, weight: .bold), .foregroundColor: theme.title, .paragraphStyle: center,
        .kern: -1.5,
    ])
    let subtitle = NSAttributedString(string: caption.1, attributes: [
        .font: NSFont.systemFont(ofSize: 52, weight: .regular), .foregroundColor: theme.subtitle, .paragraphStyle: center,
    ])
    title.draw(in: NSRect(x: 0, y: canvas.height - 260, width: canvas.width, height: 140))
    subtitle.draw(in: NSRect(x: 0, y: canvas.height - 360, width: canvas.width, height: 80))

    // Window, scaled to fit under the caption, never enlarged.
    let pixelSize = NSSize(width: windowRep.pixelsWide, height: windowRep.pixelsHigh)
    let top: CGFloat = 450, bottom: CGFloat = 90
    let scale = min(1, (canvas.height - top - bottom) / pixelSize.height, (canvas.width - 400) / pixelSize.width)
    let size = NSSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
    let frame = NSRect(x: (canvas.width - size.width) / 2, y: canvas.height - top - size.height,
                       width: size.width, height: size.height)
    let radius = 26 * scale
    let outline = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = theme.shadow
    shadow.shadowBlurRadius = 90
    shadow.shadowOffset = NSSize(width: 0, height: -36)
    shadow.set()
    theme.top.setFill()
    outline.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    outline.addClip()
    window.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    theme.edge.setStroke()
    outline.lineWidth = 2
    outline.stroke()

    NSGraphicsContext.restoreGraphicsState()
    let out = outDir.appendingPathComponent(file.lastPathComponent)
    try rep.representation(using: .png, properties: [:])!.write(to: out)
    print("wrote \(out.path)")
}
