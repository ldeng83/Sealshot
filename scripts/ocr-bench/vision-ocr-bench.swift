// Vision OCR cost benchmark — run on BOTH an Intel and an Apple Silicon Mac
// and compare, to settle how Sealshot's OCR pipeline cost is structured.
//
// The question it answers: Sealshot's `TextRecognizer` issues many small Vision
// requests per capture (tiles, plus 2 per low-confidence line in the refine
// pass, capped at 40 lines = up to 80 extra requests). On Intel this takes
// 15-37s per capture. Is that cost driven by the NUMBER of requests (a fixed
// per-request floor) or by the PIXELS being processed? And how much smaller is
// the floor on Apple Silicon's Neural Engine?
//
// Method notes (why the numbers are trustworthy):
//   * Vision is warmed up before any measurement, so model load is never timed.
//   * Every point is repeated; the MEDIAN is reported, with min/max.
//   * Trial order is shuffled with a fixed seed, so any thermal drift cannot
//     line up with a particular condition.
//   * A fixed "canary" image is re-measured throughout the run to detect
//     thermal throttling directly.
//   * Images are submitted at NATIVE resolution (no upscale), so "pixels
//     measured" is exactly "pixels Vision received".
//   * `minimumTextHeight` is RELATIVE to image height, so where crop heights
//     differ it is recomputed to hold the ABSOLUTE pixel threshold constant.
//
// Usage:  ./run.sh                 (from scripts/ocr-bench/)
//         ./run.sh path/to/img.png

import Foundation
import Darwin
import Vision
import CoreGraphics
import ImageIO

// MARK: - Machine identification

func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    guard size > 0 else { return "unknown" }
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buf, &size, nil, 0)
    return String(cString: buf)
}

func sysctlInt(_ name: String) -> Int64 {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    if sysctlbyname(name, &value, &size, nil, 0) != 0 {
        var v32: Int32 = 0
        var s32 = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &v32, &s32, nil, 0) == 0 else { return -1 }
        return Int64(v32)
    }
    return value
}

#if arch(arm64)
let builtArch = "arm64 (Apple Silicon)"
#elseif arch(x86_64)
let builtArch = "x86_64 (Intel)"
#else
let builtArch = "unknown"
#endif

// If this binary is running under Rosetta on an Apple Silicon Mac, the numbers
// are NOT representative — the whole point is to measure native performance.
let translated = sysctlInt("sysctl.proc_translated")

print("================ MACHINE ================")
print("  built for      : \(builtArch)")
print("  cpu            : \(sysctlString("machdep.cpu.brand_string"))")
print("  cores (logical): \(ProcessInfo.processInfo.activeProcessorCount)")
print("  macOS          : \(ProcessInfo.processInfo.operatingSystemVersionString)")
if translated == 1 {
    print("  *** WARNING: running under ROSETTA translation. Results are NOT")
    print("  *** native Apple Silicon numbers. Rebuild natively before trusting.")
}
print("")

// MARK: - Harness

struct LCG: RandomNumberGenerator {          // deterministic shuffle
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
var rng = LCG(state: 0xC0FFEE)

struct Settings {
    var level: VNRequestTextRecognitionLevel = .accurate
    var minimumTextHeight: Float? = 0.008
    var autoDetectLanguage = true
    var languageCorrection = false
}

@discardableResult
func recognize(_ image: CGImage, _ s: Settings = Settings()) -> Int {
    let r = VNRecognizeTextRequest()
    r.recognitionLevel = s.level
    r.usesLanguageCorrection = s.languageCorrection
    r.automaticallyDetectsLanguage = s.autoDetectLanguage
    r.recognitionLanguages = ["en-US"]
    if let m = s.minimumTextHeight { r.minimumTextHeight = m }
    guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([r])) != nil
    else { return 0 }
    return (r.results ?? []).count
}

func ms(_ block: () -> Void) -> Double {
    let t = ContinuousClock.now
    block()
    let e = ContinuousClock.now - t
    return Double(e.components.seconds) * 1000 + Double(e.components.attoseconds) / 1e15
}

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    guard !s.isEmpty else { return 0 }
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

func blank(_ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

// MARK: - Input

let defaultFixture = "../../poc/fixtures/stripe-or-billing.png"
let imagePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultFixture
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: imagePath) as CFURL, nil),
      let base = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write("cannot load image: \(imagePath)\n".data(using: .utf8)!)
    exit(1)
}
guard base.width >= 1600, base.height >= 900 else {
    FileHandle.standardError.write("image must be at least 1600x900\n".data(using: .utf8)!)
    exit(1)
}
print("fixture: \(imagePath) — \(base.width)x\(base.height)\n")

for _ in 0..<3 { recognize(base.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 200))!) }
recognize(base, Settings(level: .fast))

let canary = base.cropping(to: CGRect(x: 0, y: 0, width: 600, height: 300))!
var canaryLog: [Double] = []
func stampCanary() { canaryLog.append(ms { recognize(canary) }) }

let REPS = 5

// MARK: - EXP A — what is the fixed floor made of?

print("=== EXP A: the per-request floor (blank = nothing to recognize) ===")
print("If a BLANK image still costs real time, that time is the price of asking.")
print("If .accurate and .fast differ on a blank image, the floor is MODEL")
print("inference (Neural-Engine-accelerated), not CPU-side plumbing.\n")

var floorRows: [(String, Double, Int, Double, Int)] = []
let floorCases: [(String, CGImage)] = [
    ("blank 80x24", blank(80, 24)),
    ("blank 400x200", blank(400, 200)),
    ("blank 1600x900", blank(1600, 900)),
    ("text 80x24", base.cropping(to: CGRect(x: 0, y: 0, width: 80, height: 24))!),
    ("text 400x200", base.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 200))!),
    ("text 1600x900", base),
]
for (label, img) in floorCases {
    var acc: [Double] = [], fst: [Double] = []
    var al = 0, fl = 0
    for _ in 0..<REPS {
        acc.append(ms { al = recognize(img) })
        fst.append(ms { fl = recognize(img, Settings(level: .fast)) })
    }
    floorRows.append((label, median(acc), al, median(fst), fl))
    print("  \(pad(label, 16)) .accurate \(String(format: "%7.1fms", median(acc))) (\(al) lines)"
        + "   .fast \(String(format: "%6.1fms", median(fst))) (\(fl) lines)"
        + "   ratio \(String(format: "%5.1fx", median(acc) / max(median(fst), 0.001)))")
}
let floorBlankSmall = floorRows[0].1
let floorBlankSmallFast = floorRows[0].3

// MARK: - EXP B — THE DECISIVE ONE

print("\n=== EXP B: same pixels, same content, different REQUEST COUNT ===")
print("A 1600x800 region split into a grid. Total pixels identical in every row;")
print("only the number of Vision requests changes. Absolute min-text-height is")
print("held constant across conditions so splitting doesn't change the task.\n")

let regionW = 1600, regionH = 800
let region = base.cropping(to: CGRect(x: 0, y: 0, width: regionW, height: regionH))!
let absMinTextPx: Float = 0.008 * 900

struct Split { let cols: Int; let rows: Int }
let splits = [Split(cols: 1, rows: 1), Split(cols: 2, rows: 2),
              Split(cols: 4, rows: 2), Split(cols: 4, rows: 4)]

var trialsB: [Split] = []
for _ in 0..<REPS { trialsB.append(contentsOf: splits) }
trialsB.shuffle(using: &rng)

var accB: [String: [Double]] = [:], linesB: [String: Int] = [:]
func keyFor(_ s: Split) -> String {
    "\(s.cols * s.rows) x \(regionW / s.cols)x\(regionH / s.rows)"
}
for s in trialsB {
    let tw = regionW / s.cols, th = regionH / s.rows
    var crops: [CGImage] = []
    for r in 0..<s.rows {
        for c in 0..<s.cols {
            crops.append(region.cropping(to: CGRect(x: c * tw, y: r * th, width: tw, height: th))!)
        }
    }
    var st = Settings()
    st.minimumTextHeight = absMinTextPx / Float(th)
    var lines = 0
    let t = ms { for c in crops { lines += recognize(c, st) } }
    accB[keyFor(s), default: []].append(t)
    linesB[keyFor(s)] = lines
    stampCanary()
}
for s in splits {
    let k = keyFor(s), ts = accB[k] ?? []
    print("  \(pad(k, 18)) median \(String(format: "%8.1fms", median(ts)))"
        + "  (min \(String(format: "%.0f", ts.min() ?? 0)) max \(String(format: "%.0f", ts.max() ?? 0)))"
        + "   \(linesB[k] ?? 0) lines")
}
let oneReq = median(accB[keyFor(splits[0])] ?? [0])
let eightReq = median(accB[keyFor(splits[2])] ?? [0])
let sixteenReq = median(accB[keyFor(splits[3])] ?? [0])
// 8 -> 16 is the cleanest read: both find the same lines, so the delta is
// almost purely the cost of 8 extra requests.
let perRequest = (sixteenReq - eightReq) / 8
print("\n  16 requests vs 1, identical pixels: \(String(format: "%.2fx", sixteenReq / max(oneReq, 0.001)))")
print("  implied fixed cost per extra request (8->16 step): \(String(format: "%.0fms", perRequest))")

// MARK: - EXP C — cost vs pixels

print("\n=== EXP C: cost vs submitted pixels (native res, no upscale) ===\n")
let sizes = [(80, 24), (160, 40), (320, 80), (480, 120), (640, 200),
             (800, 300), (1100, 450), (1400, 600), (1600, 900)]
var trialsC: [Int] = []
for _ in 0..<REPS { trialsC.append(contentsOf: sizes.indices) }
trialsC.shuffle(using: &rng)
var accC: [Int: [Double]] = [:]
for i in trialsC {
    let (w, h) = sizes[i]
    let crop = base.cropping(to: CGRect(x: 0, y: 0, width: w, height: h))!
    var st = Settings()
    st.minimumTextHeight = absMinTextPx / Float(h)
    accC[i, default: []].append(ms { recognize(crop, st) })
    stampCanary()
}
for i in sizes.indices {
    let (w, h) = sizes[i], ts = accC[i] ?? []
    print("  \(pad("\(w)x\(h)", 12)) \(pad("\(w * h) px", 12)) median \(String(format: "%7.1fms", median(ts)))")
}

// MARK: - EXP D — settings sweep

print("\n=== EXP D: request settings (line count is the quality proxy) ===\n")
var variants: [(String, Settings)] = []
variants.append(("production (minH 0.008, autoLang on)", Settings()))
var d1 = Settings(); d1.minimumTextHeight = nil
variants.append(("Vision default minimumTextHeight", d1))
var d2 = Settings(); d2.autoDetectLanguage = false
variants.append(("autoDetectLanguage OFF", d2))
var d3 = Settings(); d3.level = .fast
variants.append((".fast (reference)", d3))

var trialsD: [Int] = []
for _ in 0..<REPS { trialsD.append(contentsOf: variants.indices) }
trialsD.shuffle(using: &rng)
var accD: [Int: [Double]] = [:], linesD: [Int: Int] = [:]
for i in trialsD {
    var lines = 0
    accD[i, default: []].append(ms { lines = recognize(base, variants[i].1) })
    linesD[i] = lines
    stampCanary()
}
for i in variants.indices {
    print("  \(pad(variants[i].0, 38)) median \(String(format: "%8.1fms", median(accD[i] ?? [])))"
        + "   \(linesD[i] ?? 0) lines")
}

// MARK: - EXP E — thermal drift

print("\n=== EXP E: thermal drift canary (same image, \(canaryLog.count) samples across the run) ===\n")
let q = max(1, canaryLog.count / 4)
let firstQ = median(Array(canaryLog.prefix(q))), lastQ = median(Array(canaryLog.suffix(q)))
print("  first quarter \(String(format: "%.1fms", firstQ))   last quarter \(String(format: "%.1fms", lastQ))"
    + "   drift \(String(format: "%.2fx", lastQ / max(firstQ, 0.001)))")
print("  (a drift much above ~1.15x means throttling is polluting the results)")

// MARK: - Summary

print("\n================ SUMMARY (paste this back) ================")
print("  arch                              : \(builtArch)\(translated == 1 ? "  [ROSETTA — INVALID]" : "")")
print("  cpu                               : \(sysctlString("machdep.cpu.brand_string"))")
print("  .accurate floor (blank 80x24)     : \(String(format: "%.1fms", floorBlankSmall))")
print("  .fast floor (blank 80x24)         : \(String(format: "%.1fms", floorBlankSmallFast))")
print("  floor ratio accurate/fast         : \(String(format: "%.1fx", floorBlankSmall / max(floorBlankSmallFast, 0.001)))")
print("  cost per extra request (8->16)    : \(String(format: "%.0fms", perRequest))")
print("  16 requests vs 1, same pixels     : \(String(format: "%.2fx", sixteenReq / max(oneReq, 0.001)))")
print("  full 1600x900 .accurate           : \(String(format: "%.0fms", floorRows[5].1))")
print("  thermal drift over run            : \(String(format: "%.2fx", lastQ / max(firstQ, 0.001)))")
print("")
print("  >>> Sealshot's refine pass issues up to 80 requests per capture.")
print("  >>> Projected refine-pass cost here: \(String(format: "%.1fs", perRequest * 80 / 1000))")
print("===========================================================")
