import Cocoa

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))

image.lockFocus()

guard let context = NSGraphicsContext.current?.cgContext else {
    fputs("Failed to create graphics context.\n", stderr)
    exit(1)
}

// Background gradient - deep blue to teal
let colorSpace = CGColorSpaceCreateDeviceRGB()
let gradientColors = [
    CGColor(red: 0.15, green: 0.12, blue: 0.35, alpha: 1.0),  // Deep indigo
    CGColor(red: 0.10, green: 0.30, blue: 0.50, alpha: 1.0),  // Dark teal
    CGColor(red: 0.15, green: 0.45, blue: 0.55, alpha: 1.0),  // Teal
] as CFArray

guard let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0.0, 0.6, 1.0]) else {
    fputs("Failed to create background gradient.\n", stderr)
    exit(1)
}
context.drawLinearGradient(gradient,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: size, y: 0),
    options: [])

// Draw subtle sound wave arcs in the background
context.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.08))
context.setLineWidth(3)
let centerX = size / 2
let centerY = size / 2

for i in 1...5 {
    let radius = CGFloat(i) * 80 + 100
    let startAngle = CGFloat.pi * 0.25
    let endAngle = CGFloat.pi * 0.75
    context.addArc(center: CGPoint(x: centerX, y: centerY), radius: radius,
                   startAngle: -endAngle, endAngle: -startAngle, clockwise: false)
    context.strokePath()
    context.addArc(center: CGPoint(x: centerX, y: centerY), radius: radius,
                   startAngle: CGFloat.pi - endAngle, endAngle: CGFloat.pi - startAngle, clockwise: true)
    context.strokePath()
}

// Draw microphone body
let micWidth: CGFloat = 140
let micHeight: CGFloat = 260
let micX = centerX - micWidth / 2
let micY = centerY + 20

let micRect = CGRect(x: micX, y: micY, width: micWidth, height: micHeight)
let micPath = CGPath(roundedRect: micRect, cornerWidth: micWidth / 2, cornerHeight: micWidth / 2, transform: nil)

// Mic gradient fill
let micGradientColors = [
    CGColor(red: 0.95, green: 0.95, blue: 1.0, alpha: 1.0),
    CGColor(red: 0.75, green: 0.80, blue: 0.90, alpha: 1.0),
] as CFArray
guard let micGradient = CGGradient(colorsSpace: colorSpace, colors: micGradientColors, locations: [0.0, 1.0]) else {
    fputs("Failed to create microphone gradient.\n", stderr)
    exit(1)
}

context.saveGState()
context.addPath(micPath)
context.clip()
context.drawLinearGradient(micGradient,
    start: CGPoint(x: micX, y: micY + micHeight),
    end: CGPoint(x: micX + micWidth, y: micY),
    options: [])
context.restoreGState()

// Mic grille lines
context.setStrokeColor(CGColor(red: 0.60, green: 0.65, blue: 0.75, alpha: 0.4))
context.setLineWidth(2)
let grillSpacing: CGFloat = 22
let grillY0 = micY + micWidth / 2 + 15
let grillY1 = micY + micHeight - micWidth / 2 - 10
var gy = grillY0
while gy < grillY1 {
    let halfWidth = sqrt(max(0, pow(micWidth/2, 2) - pow(gy - (micY + micHeight/2), 2))) * 0.85
    context.move(to: CGPoint(x: centerX - halfWidth, y: gy))
    context.addLine(to: CGPoint(x: centerX + halfWidth, y: gy))
    context.strokePath()
    gy += grillSpacing
}

// Mic arc (holder)
context.setStrokeColor(CGColor(red: 0.85, green: 0.88, blue: 0.95, alpha: 0.9))
context.setLineWidth(12)
context.setLineCap(.round)
let arcRadius: CGFloat = 110
context.addArc(center: CGPoint(x: centerX, y: micY + micHeight/2 - 30),
               radius: arcRadius,
               startAngle: CGFloat.pi * 0.15,
               endAngle: CGFloat.pi * 0.85,
               clockwise: true)
context.strokePath()

// Mic stand (vertical line down from arc)
context.setLineWidth(10)
context.move(to: CGPoint(x: centerX, y: micY - 30))
context.addLine(to: CGPoint(x: centerX, y: micY - 80))
context.strokePath()

// Mic stand base (horizontal)
context.setLineWidth(12)
context.setLineCap(.round)
context.move(to: CGPoint(x: centerX - 60, y: micY - 80))
context.addLine(to: CGPoint(x: centerX + 60, y: micY - 80))
context.strokePath()

// Sound wave arcs emanating from mic (right side, more visible)
context.setLineCap(.round)
for i in 1...3 {
    let alpha = CGFloat(4 - i) * 0.15
    context.setStrokeColor(CGColor(red: 0.5, green: 0.85, blue: 0.95, alpha: alpha))
    context.setLineWidth(CGFloat(8 - i))
    let waveRadius = CGFloat(i) * 55 + 30
    context.addArc(center: CGPoint(x: centerX + micWidth/2 + 10, y: centerY + 60),
                   radius: waveRadius,
                   startAngle: -CGFloat.pi * 0.35,
                   endAngle: CGFloat.pi * 0.35,
                   clockwise: false)
    context.strokePath()
}

// Matching left side waves
for i in 1...3 {
    let alpha = CGFloat(4 - i) * 0.15
    context.setStrokeColor(CGColor(red: 0.5, green: 0.85, blue: 0.95, alpha: alpha))
    context.setLineWidth(CGFloat(8 - i))
    let waveRadius = CGFloat(i) * 55 + 30
    context.addArc(center: CGPoint(x: centerX - micWidth/2 - 10, y: centerY + 60),
                   radius: waveRadius,
                   startAngle: CGFloat.pi * 0.65,
                   endAngle: CGFloat.pi * 1.35,
                   clockwise: false)
    context.strokePath()
}

image.unlockFocus()

// Save as PNG
guard let tiffData = image.tiffRepresentation,
      let bitmapRep = NSBitmapImageRep(data: tiffData),
      let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
    print("Failed to create PNG")
    exit(1)
}

let outputURL = URL(fileURLWithPath: "/Users/jarvis/Desktop/Murmur/icon-1024.png")
do {
    try pngData.write(to: outputURL)
} catch {
    fputs("Failed to write PNG: \(error)\n", stderr)
    exit(1)
}
print("Icon saved to \(outputURL.path)")
