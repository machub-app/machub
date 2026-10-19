// Draws docs/brand/social-preview.png (1280×640), the image GitHub shows when the repository link is shared.
// Run: swift tools/brand/social.swift docs/brand/icon.png docs/brand/social-preview.png
import AppKit
let args = CommandLine.arguments
let icon = NSImage(contentsOfFile: args[1])!
let ctx = CGContext(data: nil, width: 1280, height: 640, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let colors = [CGColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1), CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)] as CFArray
ctx.drawRadialGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!,
                       startCenter: CGPoint(x: 330, y: 320), startRadius: 0, endCenter: CGPoint(x: 330, y: 320), endRadius: 900, options: [])
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
icon.draw(in: CGRect(x: 90, y: 140, width: 360, height: 360))
let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 104, weight: .bold), .foregroundColor: NSColor.white]
("MacHub" as NSString).draw(at: CGPoint(x: 500, y: 330), withAttributes: title)
let sub: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 34, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.75)]
("Play your Windows games on a Mac" as NSString).draw(at: CGPoint(x: 506, y: 270), withAttributes: sub)
("with Apple silicon." as NSString).draw(at: CGPoint(x: 506, y: 226), withAttributes: sub)
let tag: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor(white: 1, alpha: 0.45)]
("Wine · DXMT · DXVK · Steam · Mods  —  free and open source" as NSString).draw(at: CGPoint(x: 506, y: 168), withAttributes: tag)
try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
