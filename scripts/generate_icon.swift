#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO

let outputPath = CommandLine.arguments.dropFirst().first ?? "dist/AppIcon.icns"
let outputURL = URL(fileURLWithPath: outputPath)
let tempRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("backbuffer-icon-\(UUID().uuidString)", isDirectory: true)
let iconsetURL = tempRoot.appendingPathComponent("AppIcon.iconset", isDirectory: true)

try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: tempRoot)
}

struct IconEntry {
    let filename: String
    let pixels: Int
}

let entries: [IconEntry] = [
    IconEntry(filename: "icon_16x16.png", pixels: 16),
    IconEntry(filename: "icon_16x16@2x.png", pixels: 32),
    IconEntry(filename: "icon_32x32.png", pixels: 32),
    IconEntry(filename: "icon_32x32@2x.png", pixels: 64),
    IconEntry(filename: "icon_128x128.png", pixels: 128),
    IconEntry(filename: "icon_128x128@2x.png", pixels: 256),
    IconEntry(filename: "icon_256x256.png", pixels: 256),
    IconEntry(filename: "icon_256x256@2x.png", pixels: 512),
    IconEntry(filename: "icon_512x512.png", pixels: 512),
    IconEntry(filename: "icon_512x512@2x.png", pixels: 1024)
]

func makeColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0, in space: CGColorSpace) -> CGColor {
    CGColor(colorSpace: space, components: [r / 255.0, g / 255.0, b / 255.0, a])!
}

func renderIconImage(pixelSize: Int) -> CGImage? {
    let size = CGFloat(pixelSize)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    // macOS icon tile inset (~9% margin, ~22% corner radius)
    let inset = size * 0.09
    let tileRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let cornerRadius = tileRect.width * 0.225
    let tilePath = CGPath(roundedRect: tileRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Soft drop shadow beneath dark graphite tile
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.018),
        blur: size * 0.04,
        color: makeColor(0, 0, 0, 0.55, in: colorSpace)
    )
    ctx.addPath(tilePath)
    ctx.setFillColor(makeColor(13, 15, 20, 1.0, in: colorSpace))
    ctx.fillPath()
    ctx.restoreGState()

    // Graphite base gradient inside squircle
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()

    let bgColors = [
        makeColor(30, 36, 50, 1.0, in: colorSpace),
        makeColor(18, 22, 30, 1.0, in: colorSpace),
        makeColor(11, 13, 18, 1.0, in: colorSpace)
    ] as CFArray
    if let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.55, 1.0]) {
        ctx.drawLinearGradient(
            bgGradient,
            start: CGPoint(x: tileRect.midX, y: tileRect.maxY),
            end: CGPoint(x: tileRect.midX, y: tileRect.minY),
            options: []
        )
    }

    // Subtle top-amber radial ambient glow
    let glowColors = [
        makeColor(245, 166, 35, 0.16, in: colorSpace),
        makeColor(245, 166, 35, 0.0, in: colorSpace)
    ] as CFArray
    if let glowGradient = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            glowGradient,
            startCenter: CGPoint(x: tileRect.midX, y: tileRect.midY + tileRect.height * 0.12),
            startRadius: 0,
            endCenter: CGPoint(x: tileRect.midX, y: tileRect.midY + tileRect.height * 0.12),
            endRadius: tileRect.width * 0.55,
            options: []
        )
    }
    ctx.restoreGState()

    // Crisp 1px-proportional inner glass rim
    let rimInset = max(1.0, size * 0.004)
    let rimRect = tileRect.insetBy(dx: rimInset, dy: rimInset)
    let rimPath = CGPath(roundedRect: rimRect, cornerWidth: cornerRadius - rimInset, cornerHeight: cornerRadius - rimInset, transform: nil)
    ctx.addPath(rimPath)
    ctx.setStrokeColor(makeColor(255, 255, 255, 0.14, in: colorSpace))
    ctx.setLineWidth(max(1.0, size * 0.008))
    ctx.strokePath()

    // Center dark circular housing for replay ring
    let center = CGPoint(x: size * 0.5, y: size * 0.5)
    let trackRadius = tileRect.width * 0.305
    let trackWidth = max(2.0, tileRect.width * 0.085)

    // Subtle dark groove beneath amber arc
    ctx.saveGState()
    ctx.setStrokeColor(makeColor(7, 9, 13, 0.85, in: colorSpace))
    ctx.setLineWidth(trackWidth * 1.18)
    ctx.addArc(center: center, radius: trackRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()

    // Medal-amber replay arc (270 degrees, sweeping counter-clockwise from bottom-left/bottom to left)
    let startAngle = -CGFloat.pi * 0.52
    let endAngle = CGFloat.pi * 0.98

    let arcPath = CGMutablePath()
    arcPath.addArc(center: center, radius: trackRadius, startAngle: startAngle, endAngle: endAngle, clockwise: false)

    let strokedArc = arcPath.copy(
        strokingWithWidth: trackWidth,
        lineCap: .round,
        lineJoin: .round,
        miterLimit: 4
    )

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.006),
        blur: size * 0.03,
        color: makeColor(245, 166, 35, 0.42, in: colorSpace)
    )
    ctx.addPath(strokedArc)
    ctx.clip()

    let amberColors = [
        makeColor(255, 209, 102, 1.0, in: colorSpace),
        makeColor(245, 166, 35, 1.0, in: colorSpace),
        makeColor(217, 119, 6, 1.0, in: colorSpace)
    ] as CFArray
    if let amberGradient = CGGradient(colorsSpace: colorSpace, colors: amberColors, locations: [0.0, 0.5, 1.0]) {
        ctx.drawLinearGradient(
            amberGradient,
            start: CGPoint(x: tileRect.minX, y: tileRect.maxY),
            end: CGPoint(x: tileRect.maxX, y: tileRect.minY),
            options: []
        )
    }
    ctx.restoreGState()

    // Counter-clockwise arrowhead at endAngle (increasing angle in CG y-up coords -> tangent is endAngle + pi/2)
    let tipCenter = CGPoint(
        x: center.x + cos(endAngle) * trackRadius,
        y: center.y + sin(endAngle) * trackRadius
    )
    let tangentAngle = endAngle + CGFloat.pi * 0.5
    let arrowLength = trackWidth * 1.75
    let arrowHalfWidth = trackWidth * 1.05

    let pTip = CGPoint(
        x: tipCenter.x + cos(tangentAngle) * (arrowLength * 0.62),
        y: tipCenter.y + sin(tangentAngle) * (arrowLength * 0.62)
    )
    let pBackCenter = CGPoint(
        x: tipCenter.x - cos(tangentAngle) * (arrowLength * 0.42),
        y: tipCenter.y - sin(tangentAngle) * (arrowLength * 0.42)
    )
    let perpAngle = tangentAngle + CGFloat.pi * 0.5
    let pLeft = CGPoint(
        x: pBackCenter.x + cos(perpAngle) * arrowHalfWidth,
        y: pBackCenter.y + sin(perpAngle) * arrowHalfWidth
    )
    let pRight = CGPoint(
        x: pBackCenter.x - cos(perpAngle) * arrowHalfWidth,
        y: pBackCenter.y - sin(perpAngle) * arrowHalfWidth
    )

    ctx.saveGState()
    ctx.setFillColor(makeColor(255, 201, 79, 1.0, in: colorSpace))
    ctx.move(to: pTip)
    ctx.addLine(to: pLeft)
    ctx.addLine(to: pRight)
    ctx.closePath()
    ctx.fillPath()
    ctx.restoreGState()

    // Inner dark lens + crisp amber capture core (play / buffer dot)
    let coreRadius = trackRadius * 0.48
    let coreRect = CGRect(
        x: center.x - coreRadius,
        y: center.y - coreRadius,
        width: coreRadius * 2,
        height: coreRadius * 2
    )
    ctx.saveGState()
    ctx.setFillColor(makeColor(21, 25, 34, 1.0, in: colorSpace))
    ctx.fillEllipse(in: coreRect)
    ctx.setStrokeColor(makeColor(255, 255, 255, 0.12, in: colorSpace))
    ctx.setLineWidth(max(1.0, size * 0.007))
    ctx.strokeEllipse(in: coreRect)
    ctx.restoreGState()

    // Crisp amber play/clip triangle slightly shifted right for visual optical centering
    let triSize = coreRadius * 0.66
    let triOffsetX = triSize * 0.10
    let triCenter = CGPoint(x: center.x + triOffsetX, y: center.y)
    ctx.saveGState()
    ctx.setFillColor(makeColor(245, 166, 35, 1.0, in: colorSpace))
    ctx.move(to: CGPoint(x: triCenter.x + triSize * 0.72, y: triCenter.y))
    ctx.addLine(to: CGPoint(x: triCenter.x - triSize * 0.52, y: triCenter.y + triSize * 0.68))
    ctx.addLine(to: CGPoint(x: triCenter.x - triSize * 0.52, y: triCenter.y - triSize * 0.68))
    ctx.closePath()
    ctx.fillPath()
    ctx.restoreGState()

    return ctx.makeImage()
}

for entry in entries {
    guard let image = renderIconImage(pixelSize: entry.pixels) else {
        fputs("Failed to render \(entry.filename)\n", stderr)
        exit(1)
    }
    let fileURL = iconsetURL.appendingPathComponent(entry.filename)
    guard let dest = CGImageDestinationCreateWithURL(
        fileURL as CFURL,
        "public.png" as CFString,
        1,
        nil
    ) else {
        fputs("Failed to create PNG destination for \(entry.filename)\n", stderr)
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        fputs("Failed to write PNG \(entry.filename)\n", stderr)
        exit(1)
    }
}

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
if FileManager.default.fileExists(atPath: outputURL.path) {
    try FileManager.default.removeItem(at: outputURL)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    fputs("iconutil failed with exit status \(process.terminationStatus)\n", stderr)
    exit(process.terminationStatus)
}

print("Generated AppIcon.icns at \(outputURL.path)")
