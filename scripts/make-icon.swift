#!/usr/bin/env swift
// アプリアイコンを生成する。
//
//   swift scripts/make-icon.swift plane out.png [size]   # 1 枚だけ書き出す
//   swift scripts/make-icon.swift plane --icns Resources/AppIcon.icns
//
// 図形だけで描くので外部素材が要らず、作り直しがいつでもできる。
import AppKit

enum Style: String {
    case plane      // 紙飛行機
    case card       // レシピカード
    case spark      // スパーク

    var background: [NSColor] {
        switch self {
        case .plane: return [NSColor(srgbRed: 0.31, green: 0.35, blue: 0.90, alpha: 1),
                             NSColor(srgbRed: 0.17, green: 0.20, blue: 0.62, alpha: 1)]
        case .card: return [NSColor(srgbRed: 0.20, green: 0.21, blue: 0.24, alpha: 1),
                            NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1)]
        case .spark: return [NSColor(srgbRed: 0.13, green: 0.55, blue: 0.95, alpha: 1),
                             NSColor(srgbRed: 0.06, green: 0.30, blue: 0.72, alpha: 1)]
        }
    }
}

/// 角丸の背景。macOS のアイコンに合わせて余白を取る。
func drawBackground(_ style: Style, size: CGFloat) {
    let inset = size * 0.09
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.addClip()
    let colors = style.background
    NSGradient(starting: colors[0], ending: colors[1])?.draw(in: rect, angle: -90)
}

func drawPlane(size: CGFloat) {
    // 中心に置いた紙飛行機。折り目を 1 本だけ入れて立体感を出す。
    let s = size
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 0.22 * s, y: 0.50 * s))
    path.line(to: NSPoint(x: 0.80 * s, y: 0.74 * s))
    path.line(to: NSPoint(x: 0.46 * s, y: 0.36 * s))
    path.line(to: NSPoint(x: 0.42 * s, y: 0.46 * s))
    path.close()
    NSColor.white.setFill()
    path.fill()

    let fold = NSBezierPath()
    fold.move(to: NSPoint(x: 0.42 * s, y: 0.46 * s))
    fold.line(to: NSPoint(x: 0.80 * s, y: 0.74 * s))
    fold.line(to: NSPoint(x: 0.42 * s, y: 0.28 * s))
    fold.close()
    NSColor.white.withAlphaComponent(0.55).setFill()
    fold.fill()
}

func drawCard(size: CGFloat) {
    // 角丸カードに 3 本のライン。Recipe の一覧を最小限で表す。
    let s = size
    let card = NSRect(x: 0.26 * s, y: 0.27 * s, width: 0.48 * s, height: 0.46 * s)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: card, xRadius: 0.06 * s, yRadius: 0.06 * s).fill()

    let widths: [CGFloat] = [0.30, 0.24, 0.18]
    for (index, width) in widths.enumerated() {
        let y = card.maxY - 0.11 * s - CGFloat(index) * 0.12 * s
        let line = NSRect(x: 0.33 * s, y: y, width: width * s, height: 0.045 * s)
        NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 1).setFill()
        NSBezierPath(roundedRect: line, xRadius: 0.022 * s, yRadius: 0.022 * s).fill()
    }
}

func drawSpark(size: CGFloat) {
    // 4 芒星ひとつ。細く絞ってスキルらしい形にする。
    let s = size
    let center = NSPoint(x: 0.5 * s, y: 0.5 * s)
    let outer = 0.30 * s
    let inner = 0.075 * s
    let path = NSBezierPath()
    for index in 0..<8 {
        let radius = index.isMultiple(of: 2) ? outer : inner
        let angle = CGFloat(index) * .pi / 4 + .pi / 2
        let point = NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        if index == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.close()
    NSColor.white.setFill()
    path.fill()
}

func render(_ style: Style, size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    drawBackground(style, size: size)
    switch style {
    case .plane: drawPlane(size: size)
    case .card: drawCard(size: size)
    case .spark: drawSpark(size: size)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to path: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try? data.write(to: URL(fileURLWithPath: path))
}

// MARK: - entry

let arguments = Array(CommandLine.arguments.dropFirst())
guard let style = arguments.first.flatMap(Style.init(rawValue:)) else {
    print("usage: make-icon.swift <plane|card|spark> <out.png|--icns out.icns> [size]")
    exit(1)
}

if arguments.count >= 3, arguments[1] == "--icns" {
    let output = arguments[2]
    let iconset = NSTemporaryDirectory() + "AgentRecipes-\(UUID().uuidString).iconset"
    try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
    // iconutil が要求する 10 種類。
    let entries: [(name: String, size: CGFloat)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for entry in entries {
        writePNG(render(style, size: entry.size), to: "\(iconset)/\(entry.name).png")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset, "-o", output]
    try? process.run()
    process.waitUntilExit()
    try? FileManager.default.removeItem(atPath: iconset)
    print("wrote \(output)")
} else {
    let output = arguments.count >= 2 ? arguments[1] : "icon.png"
    let size = arguments.count >= 3 ? CGFloat(Double(arguments[2]) ?? 512) : 512
    writePNG(render(style, size: size), to: output)
    print("wrote \(output)")
}
