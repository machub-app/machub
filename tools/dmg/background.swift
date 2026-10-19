// Draws the MacHub disk image background (660×400 pt, 1x and 2x): light (Finder writes icon labels in black), with an arrow from the app to Applications.
// Run: swift tools/dmg/background.swift <out-dir>   (writes background.png and background@2x.png; then
// tiffutil -cathidpicheck background.png background@2x.png -out background.tiff, the file make-dmg.sh uses)
import AppKit

func draw(scale: CGFloat, to url: URL) {
    let size = CGSize(width: 660 * scale, height: 400 * scale)
    let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    let colors = [CGColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1), CGColor(red: 0.90, green: 0.90, blue: 0.92, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 400), end: CGPoint(x: 0, y: 0), options: [])
    // Arrow between the two icons (icons sit at x 170 and 490, y 190 from the top in Finder coordinates).
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.35))
    ctx.setLineWidth(3); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    let y: CGFloat = 400 - 190
    ctx.move(to: CGPoint(x: 268, y: y)); ctx.addLine(to: CGPoint(x: 392, y: y))
    ctx.move(to: CGPoint(x: 376, y: y + 14)); ctx.addLine(to: CGPoint(x: 392, y: y)); ctx.addLine(to: CGPoint(x: 376, y: y - 14))
    ctx.strokePath()
    let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.current = nsctx
    let style = NSMutableParagraphStyle(); style.alignment = .center
    let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                                                .foregroundColor: NSColor(white: 0, alpha: 0.8), .paragraphStyle: style]
    ("Drag MacHub to Applications" as NSString).draw(in: CGRect(x: 0, y: 62, width: 660, height: 22), withAttributes: title)
    let sub: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 0, alpha: 0.45), .paragraphStyle: style]
    ("Glisse MacHub dans Applications" as NSString).draw(in: CGRect(x: 0, y: 42, width: 660, height: 18), withAttributes: sub)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = CGSize(width: 660, height: 400)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
draw(scale: 1, to: out.appending(path: "background.png"))
draw(scale: 2, to: out.appending(path: "background@2x.png"))
