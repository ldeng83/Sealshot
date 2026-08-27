// Renders the DMG window background art (content area only — Finder draws the
// app/Applications icons and their labels on top, at positions set by the
// install AppleScript). Writes background.png (1x) and background@2x.png (2x)
// to the directory given as argv[1].
//
//   swift render-background.swift <output-dir>
//
// Drawing happens in AppKit's native bottom-left origin — NO coordinate flip,
// because a y-flip mirrors text glyphs. Layout is expressed "from the top" and
// converted with fromTop(), so it still reads top-down while text stays upright.
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let W: CGFloat = 660, H: CGFloat = 400

// Icon centres Finder will place items at, measured from the TOP of the window
// (Finder's own origin). Kept in sync with make-dmg.sh's LEFT_X/RIGHT_X/ICON_Y.
let leftX: CGFloat = 175, rightX: CGFloat = 485, iconTopY: CGFloat = 190

// Convert a "distance from the top" into the bottom-left-origin y we draw in.
func fromTop(_ y: CGFloat) -> CGFloat { H - y }
let iconY = fromTop(iconTopY)

func c(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
}

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(W*scale), pixelsHigh: Int(H*scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    let rect = CGRect(x: 0, y: 0, width: W, height: H)
    // angle 90 fills bottom→top: peach settles at the top, warmer orange below.
    NSGradient(colors: [c(255,214,170), c(255,243,232)])!.draw(in: rect, angle: 90)

    // Subtle hexagon weave — the editor's visual language.
    cg.saveGState(); cg.clip(to: rect)
    let hexR: CGFloat = 30, dx = hexR * sqrt(3), dy = hexR * 1.5
    c(255,122,51,0.07).setStroke()
    var row = 0, y = -dy
    while y < H + dy {
        let xoff: CGFloat = (row % 2 == 0) ? 0 : dx/2
        var x = -dx
        while x < W + dx {
            let p = NSBezierPath()
            for i in 0..<6 {
                let a = CGFloat.pi/180 * (60*CGFloat(i) - 90)
                let pt = CGPoint(x: x + xoff + hexR*cos(a), y: y + hexR*sin(a))
                i == 0 ? p.move(to: pt) : p.line(to: pt)
            }
            p.close(); p.lineWidth = 1.5; p.stroke()
            x += dx
        }
        y += dy; row += 1
    }
    cg.restoreGState()

    // Viewfinder corner brackets (icon motif). Corner point at (x,y); arms run
    // sx*len horizontally and sy*len vertically toward the window interior.
    func bracket(_ x: CGFloat, _ y: CGFloat, _ sx: CGFloat, _ sy: CGFloat) {
        let len: CGFloat = 26, p = NSBezierPath()
        p.move(to: CGPoint(x: x, y: y + sy*len)); p.line(to: CGPoint(x: x, y: y))
        p.line(to: CGPoint(x: x + sx*len, y: y))
        c(255,106,43,0.55).setStroke(); p.lineWidth = 4; p.lineCapStyle = .round; p.stroke()
    }
    let ins: CGFloat = 22
    bracket(ins, H-ins, 1, -1); bracket(W-ins, H-ins, -1, -1)   // top corners
    bracket(ins, ins, 1, 1);    bracket(W-ins, ins, -1, 1)       // bottom corners

    let center = NSMutableParagraphStyle(); center.alignment = .center
    ("Drag Sealshot to Applications" as NSString).draw(
        in: CGRect(x: 0, y: fromTop(60), width: W, height: 26),
        withAttributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                         .foregroundColor: c(40,30,20), .paragraphStyle: center])

    // Arrow from the app slot toward the Applications slot, on the icon centre line.
    let a = NSBezierPath()
    a.move(to: CGPoint(x: leftX + 75, y: iconY)); a.line(to: CGPoint(x: rightX - 89, y: iconY))
    c(110,110,115,0.9).setStroke(); a.lineWidth = 4; a.lineCapStyle = .round; a.stroke()
    let head = NSBezierPath()
    head.move(to: CGPoint(x: rightX - 77, y: iconY)); head.line(to: CGPoint(x: rightX - 95, y: iconY-9))
    head.line(to: CGPoint(x: rightX - 95, y: iconY+9)); head.close()
    c(110,110,115,0.9).setFill(); head.fill()

    ("S E A L S H O T" as NSString).draw(
        in: CGRect(x: 0, y: 12, width: W, height: 20),
        withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold),
                         .foregroundColor: c(255,106,43,0.85), .paragraphStyle: center])

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: URL(fileURLWithPath: "\(outDir)/background.png"))
try! render(scale: 2).write(to: URL(fileURLWithPath: "\(outDir)/background@2x.png"))
print("wrote background.png + background@2x.png to \(outDir)")
