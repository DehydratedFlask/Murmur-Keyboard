import Cocoa

func generateIcon(size: Int, outputPath: String) {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        fputs("Failed to create graphics context for size \(size).\n", stderr)
        image.unlockFocus()
        return
    }

    // Pure black background
    ctx.setFillColor(CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0))
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

    // Draw sound/voice bars in the center — like an audio waveform equalizer
    // 5 bars of varying heights, centered, white, with rounded caps
    let barCount = 5
    let barWidth = s * 0.08
    let barSpacing = s * 0.04
    let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
    let startX = (s - totalWidth) / 2
    let centerY = s / 2

    // Bar heights as proportions of icon size (middle tallest, edges shortest)
    let barHeights: [CGFloat] = [0.20, 0.35, 0.50, 0.35, 0.20]

    ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))

    for i in 0..<barCount {
        let x = startX + CGFloat(i) * (barWidth + barSpacing)
        let height = s * barHeights[i]
        let y = centerY - height / 2
        let rect = CGRect(x: x, y: y, width: barWidth, height: height)
        let path = CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()
    }

    image.unlockFocus()

    guard let tiffData = image.tiffRepresentation,
          let bitmapRep = NSBitmapImageRep(data: tiffData),
          let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
        print("Failed to create PNG for size \(size)")
        return
    }

    do {
        try pngData.write(to: URL(fileURLWithPath: outputPath))
        print("Generated \(size)x\(size) icon at \(outputPath)")
    } catch {
        fputs("Failed to write PNG for size \(size): \(error)\n", stderr)
    }
}

let iconDir = "/Users/jarvis/Desktop/Murmur/Sources/Murmur/Assets.xcassets/AppIcon.appiconset"

// Generate all required sizes
generateIcon(size: 1024, outputPath: "\(iconDir)/icon-1024.png")
generateIcon(size: 180, outputPath: "\(iconDir)/icon-180.png")
generateIcon(size: 167, outputPath: "\(iconDir)/icon-167.png")
generateIcon(size: 152, outputPath: "\(iconDir)/icon-152.png")
generateIcon(size: 120, outputPath: "\(iconDir)/icon-120.png")
generateIcon(size: 76, outputPath: "\(iconDir)/icon-76.png")
