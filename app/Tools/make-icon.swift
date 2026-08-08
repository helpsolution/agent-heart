#!/usr/bin/env swift
import AppKit

// Рисует иконку приложения: пульс на темной подложке, цвета из dashboard.html.
// Запускается из make-app.sh, результат — AppIcon.icns.

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = URL(fileURLWithPath: outputDir).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let scale = s / 1024

    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("не создан контекст \(size)")
    }

    // Подложка с полями, как у системных иконок.
    let inset = 92 * scale
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.2237
    let plate = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                       transform: nil)

    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.106, green: 0.133, blue: 0.188, alpha: 1),   // #1B2230
        CGColor(red: 0.059, green: 0.067, blue: 0.082, alpha: 1),   // #0F1115
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY),
                           options: [])
    ctx.restoreGState()

    ctx.addPath(plate)
    ctx.setStrokeColor(CGColor(red: 0.137, green: 0.157, blue: 0.200, alpha: 1))  // #232833
    ctx.setLineWidth(6 * scale)
    ctx.strokePath()

    // Кардиограмма. Координаты нормированы внутри подложки.
    let pts: [(CGFloat, CGFloat)] = [
        (0.08, 0.50), (0.30, 0.50), (0.38, 0.32), (0.46, 0.74),
        (0.55, 0.18), (0.63, 0.50), (0.92, 0.50),
    ]
    let path = CGMutablePath()
    for (i, p) in pts.enumerated() {
        let point = CGPoint(x: rect.minX + rect.width * p.0,
                            y: rect.minY + rect.height * p.1)
        i == 0 ? path.move(to: point) : path.addLine(to: point)
    }

    ctx.setLineWidth(rect.width * 0.062)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    // Мягкое свечение под линией, чтобы иконка читалась в мелком размере.
    ctx.setStrokeColor(CGColor(red: 0.168, green: 0.424, blue: 0.690, alpha: 0.45))
    ctx.setShadow(offset: .zero, blur: 26 * scale,
                  color: CGColor(red: 0.168, green: 0.424, blue: 0.690, alpha: 0.9))
    ctx.addPath(path)
    ctx.strokePath()

    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setStrokeColor(CGColor(red: 0.561, green: 0.702, blue: 0.878, alpha: 1))  // #8FB3E0
    ctx.setLineWidth(rect.width * 0.045)
    ctx.addPath(path)
    ctx.strokePath()

    guard let image = ctx.makeImage() else { fatalError("нет изображения \(size)") }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("нет PNG \(size)")
    }
    return data
}

let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for v in variants {
    try render(size: v.size).write(to: iconset.appendingPathComponent("\(v.name).png"))
}
print("iconset: \(iconset.path)")
