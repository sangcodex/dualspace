import AppKit
let target = CommandLine.arguments[1]
let canvas = NSImage(size: NSSize(width: 512, height: 512))
canvas.lockFocus()
NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.095, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 16, y: 16, width: 480, height: 480), xRadius: 110, yRadius: 110).fill()
NSColor(calibratedRed: 0.49, green: 0.80, blue: 0.70, alpha: 0.23).setFill()
NSBezierPath(roundedRect: NSRect(x: 96, y: 170, width: 228, height: 228), xRadius: 50, yRadius: 50).fill()
let rear = NSBezierPath(roundedRect: NSRect(x: 96, y: 170, width: 228, height: 228), xRadius: 50, yRadius: 50)
rear.lineWidth = 14
NSColor(calibratedRed: 0.49, green: 0.80, blue: 0.70, alpha: 0.65).setStroke()
rear.stroke()
NSColor(calibratedRed: 0.49, green: 0.80, blue: 0.70, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 188, y: 82, width: 228, height: 228), xRadius: 50, yRadius: 50).fill()
canvas.unlockFocus()
let bitmap = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: target))
