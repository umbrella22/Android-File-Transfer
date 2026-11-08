#!/usr/bin/env swift
import AppKit

// Run from the repository root after updating AppBundle/DMG/artwork.png.
let assets = URL(fileURLWithPath: "AppBundle/DMG", isDirectory: true)
let layoutData = try Data(contentsOf: assets.appendingPathComponent("layout.json"))
let layout = try JSONSerialization.jsonObject(with: layoutData) as! [String: Any]
let width = layout["width"] as! Int
let height = layout["height"] as! Int
let locations = layout["icon_locations"] as! [String: [Int]]
let artwork = NSImage(contentsOf: assets.appendingPathComponent("artwork.png"))!

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    bitmap.size = NSSize(width: width, height: height)
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    artwork.draw(in: NSRect(x: 0, y: 0, width: width, height: height))

    func text(_ value: String, top: CGFloat, size: CGFloat, weight: NSFont.Weight, ink: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        (value as NSString).draw(
            in: NSRect(x: 40, y: CGFloat(height) - top - size * 1.6,
                       width: CGFloat(width) - 80, height: size * 1.6),
            withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                             .foregroundColor: ink, .paragraphStyle: paragraph]
        )
    }

    text("Android File Transfer", top: 58, size: 30, weight: .semibold,
         ink: color(25, 43, 70))
    text("Drag the app to Applications", top: 110, size: 15, weight: .medium,
         ink: color(72, 91, 119))
    text("将应用拖入右侧的「应用程序」文件夹", top: 138, size: 13, weight: .regular,
         ink: color(101, 119, 145))

    for position in locations.values {
        let center = NSPoint(x: position[0], y: height - position[1])
        let guide = NSBezierPath(ovalIn: NSRect(x: center.x - 72, y: center.y - 72,
                                              width: 144, height: 144))
        color(255, 255, 255, alpha: 0.6).setFill()
        guide.fill()
        color(211, 226, 246, alpha: 0.75).setStroke()
        guide.lineWidth = 1
        guide.stroke()
    }

    let centerY = CGFloat(height - locations["Applications"]![1])
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 355, y: centerY))
    arrow.line(to: NSPoint(x: 413, y: centerY))
    arrow.move(to: NSPoint(x: 402, y: centerY + 11))
    arrow.line(to: NSPoint(x: 413, y: centerY))
    arrow.line(to: NSPoint(x: 402, y: centerY - 11))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    color(55, 117, 218).setStroke()
    arrow.stroke()

    text("Once copied, open the app from Applications.", top: 370, size: 11.5,
         weight: .regular, ink: color(82, 103, 135))
    text("复制完成后，从「应用程序」打开应用，即可推出此磁盘。", top: 393, size: 11,
         weight: .regular, ink: color(100, 119, 147))
    NSGraphicsContext.restoreGraphicsState()

    let name = scale == 1 ? "background.png" : "background@2x.png"
    try bitmap.representation(using: .png, properties: [:])!
        .write(to: assets.appendingPathComponent(name))
}
