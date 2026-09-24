// Draws the chargnr brand from code: wordmark, app icon and menu bar glyph.
//
// The wordmark is Didot Bold reshaped after the lyffe mark: foot serifs removed,
// flag serifs cut to a slant, a tall h, letters set tight enough to touch.
// The c's terminal is an amber ball, the MagSafe charging light.
//
// The icon is the same c drawn as a charge gauge: it runs 80% of the way round
// and stops at the amber ball, the charge limit. The faint track is the 20% held
// back to save the battery.
//
//   swiftc -O docs/brand/make-brand.swift -o /tmp/make-brand && /tmp/make-brand docs/brand
//   cp docs/brand/AppIcon.appiconset/* App/Resources/Assets.xcassets/AppIcon.appiconset/
import AppKit

// ---- geometry helpers ----
let font = CTFontCreateWithName("Didot-Bold" as CFString, 1000, nil)
func glyph(_ ch: Character) -> (CGPath, CGFloat) {
  var u = Array(String(ch).utf16), g = [CGGlyph](repeating: 0, count: 1)
  CTFontGetGlyphsForCharacters(font, &u, &g, 1)
  var adv = CGSize.zero; CTFontGetAdvancesForGlyphs(font, .horizontal, g, &adv, 1)
  return (CTFontCreatePathForGlyph(font, g[0], nil)!, adv.width)
}
func rect(_ x0: CGFloat,_ y0: CGFloat,_ x1: CGFloat,_ y1: CGFloat) -> CGPath { CGPath(rect: CGRect(x: x0, y: y0, width: x1-x0, height: y1-y0), transform: nil) }
func poly(_ p: [CGPoint]) -> CGPath { let m = CGMutablePath(); m.addLines(between: p); m.closeSubpath(); return m }
func P(_ x: CGFloat,_ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
func moved(_ p: CGPath, _ dx: CGFloat, _ dy: CGFloat = 0) -> CGPath { var t = CGAffineTransform(translationX: dx, y: dy); return p.copy(using: &t)! }
func ball(_ c: CGPoint, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x-r, y: c.y-r, width: 2*r, height: 2*r), transform: nil) }
func cubicPts(_ a: CGPoint,_ b: CGPoint,_ c: CGPoint,_ d: CGPoint, n: Int = 160) -> [CGPoint] {
  (0...n).map { i in let u = CGFloat(i)/CGFloat(n), v = 1-u
    return P(v*v*v*a.x+3*v*v*u*b.x+3*v*u*u*c.x+u*u*u*d.x, v*v*v*a.y+3*v*v*u*b.y+3*v*u*u*c.y+u*u*u*d.y) }
}
// broad-nib stroke, vertical stress
func pen(_ p: [CGPoint], thick: CGFloat, thin: CGFloat, power: CGFloat = 2.4) -> CGPath {
  var L: [CGPoint] = [], R: [CGPoint] = []
  for i in p.indices {
    let a = p[max(i-1,0)], b = p[min(i+1,p.count-1)]
    var dx = b.x-a.x, dy = b.y-a.y; let m = max(hypot(dx,dy), 1e-6); dx/=m; dy/=m
    let w = thin + (thick-thin) * pow(abs(dy), power)
    L.append(P(p[i].x - dy*w/2, p[i].y + dx*w/2)); R.append(P(p[i].x + dy*w/2, p[i].y - dx*w/2))
  }
  return poly(L + R.reversed()).normalized()
}
func union(_ ps: [CGPath]) -> CGPath { ps.dropFirst().reduce(ps[0].normalized()) { $0.union($1) } }

func renderPNG(_ file: String, px: CGSize, layers: [(CGPath, NSColor)], bg: NSColor?, pad: CGFloat, box: CGRect? = nil) {
  let W = Int(px.width), H = Int(px.height)
  let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  if let bg { ctx.setFillColor(bg.cgColor); ctx.fill(CGRect(origin: .zero, size: px)) }
  let b = box ?? layers.reduce(CGRect.null) { $0.union($1.0.boundingBoxOfPath) }
  let s = min((px.width-2*pad)/b.width, (px.height-2*pad)/b.height)
  ctx.translateBy(x: (px.width-b.width*s)/2 - b.minX*s, y: (px.height-b.height*s)/2 - b.minY*s); ctx.scaleBy(x: s, y: s)
  for (p, c) in layers { ctx.setFillColor(c.cgColor); ctx.addPath(p); ctx.fillPath() }
  try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: file))
}

// ---- wordmark ----
// stems measured from Didot-Bold at 1000 units
let footH: CGFloat = 26
func dropFootSerifs(_ p: CGPath, stems: [(CGFloat, CGFloat)], width: CGFloat) -> CGPath {
  var cut = [CGPath](); var x0: CGFloat = -100
  for (a, b) in stems { cut.append(rect(x0, -2, a, footH)); x0 = b }
  cut.append(rect(x0, -2, width + 100, footH))
  return p.subtracting(union(cut))
}
func slantTop(_ p: CGPath, stem: (CGFloat, CGFloat), top: CGFloat, drop: CGFloat, extendTo: CGFloat? = nil) -> CGPath {
  var q = p.subtracting(rect(stem.0 - 120, top - 60, stem.0, top + 10))                   // flag serif
  if let e = extendTo { q = q.union(rect(stem.0, top - 40, stem.1, e)); }
  let t = extendTo ?? top
  q = q.subtracting(poly([P(stem.0 - 5, t - drop), P(stem.1 + 1, t), P(stem.1 + 1, t + 50), P(stem.0 - 5, t + 50)]))
  return q
}
func ballC(_ p: CGPath) -> (CGPath, CGPath) {
  // swap Didot's teardrop for a round "charge light"
  let body = p.subtracting(rect(322, 250, 470, 418))
  return (body, ball(P(388, 340), 63))
}

var parts: [CGPath] = []; var accent: CGPath! ; var x: CGFloat = 0
func place(_ p: CGPath, adv: CGFloat, kern: CGFloat) { parts.append(moved(p, x)); x += adv + kern }

do { let (g, a) = glyph("c"); let (b, l) = ballC(g); parts.append(b); accent = l; x += a - 60 }
do { var (g, a) = glyph("h"); g = dropFootSerifs(g, stems: [(103,225.1),(409,531.1)], width: a)
     g = slantTop(g, stem: (103,225.1), top: 721, drop: 70, extendTo: 900); place(g, adv: a, kern: -128) }
do { let (g, a) = glyph("a"); place(g, adv: a, kern: -74) }
do { var (g, a) = glyph("r"); g = dropFootSerifs(g, stems: [(106,228.1)], width: a)
     g = slantTop(g, stem: (106,228.1), top: 438, drop: 44); place(g, adv: a, kern: -92) }
do { let (g, a) = glyph("g"); place(g, adv: a, kern: -84) }
do { var (g, a) = glyph("n"); g = dropFootSerifs(g, stems: [(108,230.1),(414,536.1)], width: a)
     g = slantTop(g, stem: (108,230.1), top: 438, drop: 44); place(g, adv: a, kern: -128) }
do { var (g, a) = glyph("r"); g = dropFootSerifs(g, stems: [(106,228.1)], width: a)
     g = slantTop(g, stem: (106,228.1), top: 438, drop: 44); place(g, adv: a, kern: 0) }

let word = union(parts)

// ---- gauge mark and app icon ----
func arcPts(_ r: CGFloat, _ a0: CGFloat, _ a1: CGFloat, n: Int = 400) -> [CGPoint] {
  (0...n).map { i in let a = (a0 + (a1-a0)*CGFloat(i)/CGFloat(n)) * .pi/180; return P(r*cos(a), r*sin(a)) }
}
// gauge c: 80% of a ring, thick on the left like a Didone c
let R: CGFloat = 300, limitDeg: CGFloat = 36   // opening = 72 deg = 20%
let gauge = pen(arcPts(R, limitDeg, 360 - limitDeg), thick: 128, thin: 50, power: 1.8)
let tip = 360 - limitDeg
let limitBall = ball(P(R*cos(limitDeg * .pi/180), R*sin(limitDeg * .pi/180)), 60)
let track = pen(arcPts(R, -limitDeg + 9, limitDeg - 9), thick: 44, thin: 44)

let navyTop = NSColor(srgbRed: 0.14, green: 0.17, blue: 0.32, alpha: 1), navyBot = NSColor(srgbRed: 0.035, green: 0.045, blue: 0.11, alpha: 1)
let cream = NSColor(srgbRed: 0.965, green: 0.945, blue: 0.91, alpha: 1)
let amber = NSColor(srgbRed: 0.98, green: 0.62, blue: 0.10, alpha: 1)
func appIcon(_ px: Int) -> CGImage {
  let S = CGFloat(px), k = S/1024
  let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  let body = CGRect(x: 100*k, y: 100*k, width: 824*k, height: 824*k)
  let shape = CGPath(roundedRect: body, cornerWidth: 185*k, cornerHeight: 185*k, transform: nil)
  ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -10*k), blur: 24*k, color: NSColor.black.withAlphaComponent(0.35).cgColor)
  ctx.addPath(shape); ctx.setFillColor(navyBot.cgColor); ctx.fillPath(); ctx.restoreGState()
  ctx.saveGState(); ctx.addPath(shape); ctx.clip()
  let grad = CGGradient(colorsSpace: nil, colors: [navyTop.cgColor, navyBot.cgColor] as CFArray, locations: [0, 1])!
  ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
  let sc = 0.74 * k
  ctx.translateBy(x: S/2, y: S/2); ctx.scaleBy(x: sc, y: sc)
  ctx.setFillColor(cream.withAlphaComponent(0.16).cgColor); ctx.addPath(track); ctx.fillPath()
  ctx.setFillColor(cream.cgColor); ctx.addPath(gauge); ctx.fillPath()
  ctx.setShadow(offset: .zero, blur: 44*k/sc, color: amber.withAlphaComponent(0.75).cgColor)
  ctx.setFillColor(amber.cgColor); ctx.addPath(limitBall); ctx.fillPath()
  ctx.restoreGState()
  return ctx.makeImage()!
}

// ---- output ----
func svgPath(_ p: CGPath) -> String {
  var d = ""
  p.applyWithBlock { e in let q = e.pointee.points
    func f(_ v: CGPoint) -> String { String(format: "%.1f %.1f", v.x, v.y) }
    switch e.pointee.type {
    case .moveToPoint: d += "M" + f(q[0])
    case .addLineToPoint: d += "L" + f(q[0])
    case .addQuadCurveToPoint: d += "Q" + f(q[0]) + " " + f(q[1])
    case .addCurveToPoint: d += "C" + f(q[0]) + " " + f(q[1]) + " " + f(q[2])
    case .closeSubpath: d += "Z"
    @unknown default: break }
  }
  return d
}
func writeSVG(_ file: String, _ layers: [(CGPath, String)], pad: CGFloat) {
  let b = layers.reduce(CGRect.null) { $0.union($1.0.boundingBoxOfPath) }.insetBy(dx: -pad, dy: -pad)
  var o = String(format: "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 %.0f %.0f\">\n", b.width.rounded(.up), b.height.rounded(.up))
  o += String(format: "<g transform=\"matrix(1 0 0 -1 %.1f %.1f)\">\n", -b.minX, b.maxY)
  for (p, fill) in layers { o += "<path fill=\"\(fill)\" d=\"\(svgPath(p))\"/>\n" }
  try! (o + "</g>\n</svg>\n").write(toFile: file, atomically: true, encoding: .utf8)
}
func save(_ img: CGImage, _ file: String) { try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: file)) }

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let navy = NSColor(srgbRed: 0.055, green: 0.07, blue: 0.16, alpha: 1)
let (NAVY, CREAM, AMBER) = ("#0E1229", "#F6F1E8", "#FA9E1A")

writeSVG("\(dir)/chargnr-wordmark.svg", [(word, NAVY), (accent, AMBER)], pad: 20)
writeSVG("\(dir)/chargnr-wordmark-dark.svg", [(word, CREAM), (accent, AMBER)], pad: 20)
renderPNG("\(dir)/chargnr-wordmark.png", px: CGSize(width: 2400, height: 1100), layers: [(word, navy), (accent, amber)], bg: nil, pad: 80)
renderPNG("\(dir)/chargnr-wordmark-dark.png", px: CGSize(width: 2400, height: 1100), layers: [(word, cream), (accent, amber)], bg: nil, pad: 80)

writeSVG("\(dir)/chargnr-mark.svg", [(track, NAVY + "33"), (gauge, NAVY), (limitBall, AMBER)], pad: 12)

save(appIcon(1024), "\(dir)/chargnr-app-icon-1024.png")
let set = "\(dir)/AppIcon.appiconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
var entries: [String] = []
for pt in [16, 32, 128, 256, 512] { for s in [1, 2] {
  let name = "icon_\(pt)x\(pt)\(s == 2 ? "@2x" : "").png"
  save(appIcon(pt * s), "\(set)/\(name)")
  entries.append("{\"size\":\"\(pt)x\(pt)\",\"idiom\":\"mac\",\"filename\":\"\(name)\",\"scale\":\"\(s)x\"}")
} }
try! "{\"images\":[\(entries.joined(separator: ","))],\"info\":{\"version\":1,\"author\":\"xcode\"}}\n".write(toFile: "\(set)/Contents.json", atomically: true, encoding: .utf8)

// menu bar: one-colour template, heavier thin strokes so it holds at 18pt
let mGauge = pen(arcPts(R, limitDeg + 30, 360 - limitDeg), thick: 150, thin: 100, power: 1.8)
let mBall = ball(P(R*cos(limitDeg * .pi/180), R*sin(limitDeg * .pi/180)), 84)
let mb = CGRect(x: -R - 90, y: -R - 90, width: 2*R + 180, height: 2*R + 180)
renderPNG("\(dir)/menubar-glyph.png", px: CGSize(width: 18, height: 18), layers: [(mGauge, .black), (mBall, .black)], bg: nil, pad: 1, box: mb)
renderPNG("\(dir)/menubar-glyph@2x.png", px: CGSize(width: 36, height: 36), layers: [(mGauge, .black), (mBall, .black)], bg: nil, pad: 2, box: mb)
writeSVG("\(dir)/menubar-glyph.svg", [(mGauge.union(mBall), "#000000")], pad: 10)
