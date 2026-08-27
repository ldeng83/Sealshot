// Builds the menu-bar status-item asset from the seal source art.
//
// The source (menubar-icon-source.png) is the white seal + viewfinder brackets
// on a dark background. We key the alpha from luminance — bright seal/brackets
// become opaque, the dark background becomes transparent, and the dark eyes/
// nose fall out as natural features — then resize to the menu-bar sizes.
//
//   swift render-menubar-icon.swift <source.png> <out-dir>
import AppKit
import CoreImage

let args = CommandLine.arguments
let srcPath = args.count > 1 ? args[1] : ""
let outDir = args.count > 2 ? args[2] : "."

guard let data = FileManager.default.contents(atPath: srcPath),
      let input = CIImage(data: data) else {
    FileHandle.standardError.write(Data("cannot read \(srcPath)\n".utf8)); exit(1)
}

// alpha = clamp((luma - lo)/(hi - lo)); RGB unchanged. Drops the dark background
// and soft glow, keeps the bright seal + brackets.
let lo: CGFloat = 0.38, hi: CGFloat = 0.82, s = 1 / (hi - lo), b = -lo / (hi - lo)
let keyed = input
    .applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
        "inputAVector": CIVector(x: 0.299 * s, y: 0.587 * s, z: 0.114 * s, w: 0),
        "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: b),
    ])
    .applyingFilter("CIColorClamp")
    .cropped(to: input.extent)            // CIColorClamp returns an infinite extent
    // Respect the source's own alpha (source-in: result alpha = keyed × source).
    // The seal's baked-in DROP SHADOW is already transparent in the source, but
    // carries stored RGB the luminance key above would otherwise resurrect as a
    // faint halo — masking by the source alpha keeps the shadow (and background)
    // fully gone while leaving the seal's interior keying untouched.
    .applyingFilter("CISourceInCompositing", parameters: ["inputBackgroundImage": input])
    .cropped(to: input.extent)

let ctx = CIContext()
let keyedURL = URL(fileURLWithPath: "\(NSTemporaryDirectory())/menubar-keyed.png")
try! ctx.writePNGRepresentation(of: keyed, to: keyedURL, format: .RGBA8,
                               colorSpace: CGColorSpaceCreateDeviceRGB())
let keyedImage = NSImage(contentsOf: keyedURL)!

func resize(_ pt: Int, scale: Int) -> Data {
    let px = pt * scale
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pt, height: pt)
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
    g.imageInterpolation = .high
    keyedImage.draw(in: NSRect(x: 0, y: 0, width: pt, height: pt))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! resize(24, scale: 1).write(to: URL(fileURLWithPath: "\(outDir)/icon-mono.png"))
try! resize(24, scale: 2).write(to: URL(fileURLWithPath: "\(outDir)/icon-mono@2x.png"))
print("wrote icon-mono.png + icon-mono@2x.png to \(outDir)")
