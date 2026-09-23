// Draws the chargnr wordmark, app icon and menu bar glyph from code, so the
// brand has no font dependency. The amber ball is the MagSafe charge light.
//
//   swiftc -O docs/brand/make-brand.swift -o /tmp/make-brand && /tmp/make-brand /tmp/brand
//   cp -R /tmp/brand/AppIcon.appiconset App/Resources/Assets.xcassets/
import AppKit

// ---- pen: broad-nib stroke with vertical stress ----
let T: CGFloat = 26, t: CGFloat = 3.6
struct Stroke { var pts: [CGPoint]; var thick = T; var thin = t }
func cubic(_ a: CGPoint,_ b: CGPoint,_ c: CGPoint,_ d: CGPoint, n: Int = 120) -> [CGPoint] {
  (0...n).map { i in let u = CGFloat(i)/CGFloat(n), v = 1-u
    return CGPoint(x: v*v*v*a.x+3*v*v*u*b.x+3*v*u*u*c.x+u*u*u*d.x, y: v*v*v*a.y+3*v*v*u*b.y+3*v*u*u*c.y+u*u*u*d.y) }
}
func arc(_ c: CGPoint, rx: CGFloat, ry: CGFloat, from a0: CGFloat, to a1: CGFloat, n: Int = 180) -> [CGPoint] {
  (0...n).map { i in let a = (a0 + (a1-a0)*CGFloat(i)/CGFloat(n)) * .pi/180
    return CGPoint(x: c.x + rx*cos(a), y: c.y + ry*sin(a)) }
}
func line(_ a: CGPoint,_ b: CGPoint, n: Int = 20) -> [CGPoint] {
  (0...n).map { i in let u = CGFloat(i)/CGFloat(n); return CGPoint(x: a.x+(b.x-a.x)*u, y: a.y+(b.y-a.y)*u) }
}
func outline(_ s: Stroke) -> CGPath {
  let p = s.pts; var L: [CGPoint] = [], R: [CGPoint] = []
  for i in p.indices {
    let a = p[max(i-1,0)], b = p[min(i+1,p.count-1)]
    var dx = b.x-a.x, dy = b.y-a.y; let m = max(hypot(dx,dy), 1e-6); dx/=m; dy/=m
    let w = s.thin + (s.thick - s.thin) * pow(abs(dy), 3.0)
    L.append(CGPoint(x: p[i].x - dy*w/2, y: p[i].y + dx*w/2))
    R.append(CGPoint(x: p[i].x + dy*w/2, y: p[i].y - dx*w/2))
  }
  let path = CGMutablePath(); path.addLines(between: L + R.reversed()); path.closeSubpath(); return path
}
func ball(_ c: CGPoint, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x-r, y: c.y-r, width: 2*r, height: 2*r), transform: nil) }
func poly(_ p: [CGPoint]) -> CGPath { let m = CGMutablePath(); m.addLines(between: p); m.closeSubpath(); return m }

// ---- letters (baseline 0, x-height 100) ----
var shapes: [CGPath] = []
var accent: [CGPath] = []          // the "charge LED" ball
func add(_ s: Stroke) { shapes.append(outline(s)) }

let X: CGFloat = 100, ASC: CGFloat = 200
func stem(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat, cut: CGFloat = 12) {
  shapes.append(poly([CGPoint(x:x,y:y0), CGPoint(x:x+T,y:y0), CGPoint(x:x+T,y:y1), CGPoint(x:x,y:y1-cut)]))
}
func bowl(_ cx: CGFloat, rx: CGFloat = 40, stemX sx: CGFloat) {
  // hairline from the stem over the top, thick down the left, hairline back into the stem
  let c = CGPoint(x: cx, y: X/2), top = X+1
  var p = cubic(CGPoint(x:sx+4,y:X-6), CGPoint(x:sx-10,y:top), CGPoint(x:cx+14,y:top), CGPoint(x:cx,y:top), n: 60)
  p += arc(c, rx: rx, ry: X/2+1, from: 90, to: 270, n: 200).dropFirst()
  p += cubic(CGPoint(x:cx,y:-1), CGPoint(x:cx+14,y:-1), CGPoint(x:sx-10,y:-1), CGPoint(x:sx+4,y:6), n: 60).dropFirst()
  add(Stroke(pts: p, thick: 24))
}
func archDown(from x: CGFloat, to x2: CGFloat, bottom: CGFloat = 0) {
  // filled shoulder: hairline off the stem, swelling into the right stem
  let l = x+T
  var p = cubic(CGPoint(x:l,y:76), CGPoint(x:l+10,y:X+3), CGPoint(x:x2+T,y:X+6), CGPoint(x:x2+T,y:54))
  p += [CGPoint(x:x2+T,y:bottom), CGPoint(x:x2,y:bottom)]
  p += cubic(CGPoint(x:x2,y:54), CGPoint(x:x2,y:X-6), CGPoint(x:l+8,y:X-1), CGPoint(x:l,y:66))
  shapes.append(poly(p))
}

var x: CGFloat = 0
// c
do {
  let c = CGPoint(x: x+42, y: X/2)
  add(Stroke(pts: arc(c, rx: 42, ry: X/2+1, from: 42, to: 318), thick: 23))
  shapes.append(ball(CGPoint(x: c.x+27, y: 76), 12.5))
  x += 80
}
// h
do { stem(x, 0, ASC, cut: 16); archDown(from: x, to: x+52); x += 52+T+6 }
// a (single storey, bowl kisses the h)
do { let sx = x+76; bowl(x+42, rx: 40, stemX: sx); stem(sx, 0, X+1, cut: 0); x = sx+T+4 }
// r
do {
  stem(x, 0, X+2, cut: 8)
  add(Stroke(pts: cubic(CGPoint(x:x+T-1,y:72), CGPoint(x:x+T+8,y:X+2), CGPoint(x:x+T+28,y:X+6), CGPoint(x:x+T+38,y:92))))
  shapes.append(ball(CGPoint(x: x+T+30, y: 86), 12))
  x += T+34
}
// g (single storey, tail sweeps back under the word like the lyffe y)
let gTail: CGFloat
do {
  bowl(x+44, rx: 40, stemX: x+78); let sx = x+78+T/2
  var p = line(CGPoint(x:sx,y:X+1), CGPoint(x:sx,y:-40))
  p += cubic(CGPoint(x:sx,y:-40), CGPoint(x:sx,y:-118), CGPoint(x:sx-150,y:-132), CGPoint(x:sx-250,y:-104), n: 200).dropFirst()
  add(Stroke(pts: p))
  gTail = sx-262
  accent.append(ball(CGPoint(x: sx-262, y: -98), 14))
  x = sx+T/2+4
}
// n
do { stem(x, 0, X+2, cut: 8); archDown(from: x, to: x+52); x += 52+T+6 }
// r
do {
  stem(x, 0, X+2, cut: 8)
  add(Stroke(pts: cubic(CGPoint(x:x+T-1,y:72), CGPoint(x:x+T+8,y:X+2), CGPoint(x:x+T+28,y:X+6), CGPoint(x:x+T+38,y:92))))
  shapes.append(ball(CGPoint(x: x+T+30, y: 86), 12))
  x += T+44
}
let wordWidth = x

// ---- render ----
func bounds(_ ps: [CGPath]) -> CGRect { ps.reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) } }
func render(_ file: String, size: CGSize, bg: NSColor?, ink: NSColor, led: NSColor, paths: [CGPath], leds: [CGPath], box: CGRect, pad: CGFloat, corner: CGFloat = 0) {
  let W = Int(size.width), H = Int(size.height)
  let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  if let bg { ctx.setFillColor(bg.cgColor)
    if corner > 0 { ctx.addPath(CGPath(roundedRect: CGRect(x:0,y:0,width:size.width,height:size.height), cornerWidth: corner, cornerHeight: corner, transform: nil)); ctx.fillPath() }
    else { ctx.fill(CGRect(origin: .zero, size: size)) } }
  let s = min((size.width-2*pad)/box.width, (size.height-2*pad)/box.height)
  ctx.translateBy(x: (size.width - box.width*s)/2 - box.minX*s, y: (size.height - box.height*s)/2 - box.minY*s)
  ctx.scaleBy(x: s, y: s)
  ctx.setFillColor(ink.cgColor); for p in paths { ctx.addPath(p); ctx.fillPath() }
  ctx.setFillColor(led.cgColor); for p in leds { ctx.addPath(p); ctx.fillPath() }
  let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: file))
}
let wordShapes = shapes, wordAccent = accent

// ---- icon glyph: a single-storey g whose tail hooks back under the bowl ----
func buildG(thin: CGFloat) -> ([CGPath], [CGPath]) {
  shapes = []; accent = []
  let sx: CGFloat = 78
  bowl(44, rx: 40, stemX: sx); let c = sx+T/2
  var p = line(CGPoint(x:c,y:X+1), CGPoint(x:c,y:-30))
  p += cubic(CGPoint(x:c,y:-30), CGPoint(x:c,y:-92), CGPoint(x:c-70,y:-108), CGPoint(x:c-118,y:-88), n: 160).dropFirst()
  shapes.append(outline(Stroke(pts: p, thick: T, thin: thin)))
  accent.append(ball(CGPoint(x: c-116, y: -86), 14))
  if thin > t { // menu-bar weight: thicken bowl hairlines too
    shapes.removeFirst()
    let cc = CGPoint(x: 44, y: X/2)
    var b = cubic(CGPoint(x:sx+4,y:X-6), CGPoint(x:sx-10,y:X+1), CGPoint(x:58,y:X+1), CGPoint(x:44,y:X+1), n: 60)
    b += arc(cc, rx: 40, ry: X/2+1, from: 90, to: 270, n: 200).dropFirst()
    b += cubic(CGPoint(x:44,y:-1), CGPoint(x:58,y:-1), CGPoint(x:sx-10,y:-1), CGPoint(x:sx+4,y:6), n: 60).dropFirst()
    shapes.insert(outline(Stroke(pts: b, thick: 26, thin: thin)), at: 0)
  }
  stem(sx, 0, X+1, cut: 0)
  return (shapes, accent)
}

func svgPath(_ p: CGPath) -> String {
  var d = ""
  p.applyWithBlock { e in let pts = e.pointee.points
    func f(_ q: CGPoint) -> String { String(format: "%.2f %.2f", q.x, q.y) }
    switch e.pointee.type {
    case .moveToPoint: d += "M" + f(pts[0])
    case .addLineToPoint: d += "L" + f(pts[0])
    case .addQuadCurveToPoint: d += "Q" + f(pts[0]) + " " + f(pts[1])
    case .addCurveToPoint: d += "C" + f(pts[0]) + " " + f(pts[1]) + " " + f(pts[2])
    case .closeSubpath: d += "Z"
    @unknown default: break }
  }
  return d
}
func writeSVG(_ file: String, ink: String, led: String, bg: String?, paths: [CGPath], leds: [CGPath], pad: CGFloat) {
  let b = bounds(paths + leds).insetBy(dx: -pad, dy: -pad)
  var o = String(format: "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 %.1f %.1f\">\n", b.width, b.height)
  if let bg { o += "<rect width=\"100%\" height=\"100%\" fill=\"\(bg)\"/>\n" }
  o += String(format: "<g transform=\"matrix(1 0 0 -1 %.2f %.2f)\">\n", -b.minX, b.maxY)
  o += "<g fill=\"\(ink)\">\n" + paths.map { "<path d=\"\(svgPath($0))\"/>\n" }.joined() + "</g>\n"
  if !leds.isEmpty { o += "<g fill=\"\(led)\">\n" + leds.map { "<path d=\"\(svgPath($0))\"/>\n" }.joined() + "</g>\n" }
  o += "</g>\n</svg>\n"
  try! o.write(toFile: file, atomically: true, encoding: .utf8)
}

let navy = NSColor(srgbRed: 0.055, green: 0.07, blue: 0.16, alpha: 1)
let amber = NSColor(srgbRed: 0.98, green: 0.62, blue: 0.10, alpha: 1)
let cream = NSColor(srgbRed: 0.965, green: 0.945, blue: 0.91, alpha: 1)
let box = bounds(wordShapes + wordAccent)
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
render("\(out)/chargnr-wordmark.png", size: CGSize(width: 2400, height: 1200), bg: nil, ink: navy, led: amber, paths: wordShapes, leds: wordAccent, box: box, pad: 160)
render("\(out)/chargnr-wordmark-dark.png", size: CGSize(width: 2400, height: 1200), bg: nil, ink: cream, led: amber, paths: wordShapes, leds: wordAccent, box: box, pad: 160)
render("\(out)/preview-wordmark.png", size: CGSize(width: 2400, height: 1200), bg: .white, ink: navy, led: amber, paths: wordShapes, leds: wordAccent, box: box, pad: 260)
writeSVG("\(out)/chargnr-wordmark.svg", ink: "#0E1229", led: "#FA9E1A", bg: nil, paths: wordShapes, leds: wordAccent, pad: 8)
writeSVG("\(out)/chargnr-wordmark-dark.svg", ink: "#F6F1E8", led: "#FA9E1A", bg: nil, paths: wordShapes, leds: wordAccent, pad: 8)

// app icon: macOS grid, 824pt squircle body inside 1024 canvas
let (g, gl) = buildG(thin: t)
func appIcon(_ px: Int) -> CGImage {
  let S = CGFloat(px), k = S/1024
  let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  let body = CGRect(x: 100*k, y: 100*k, width: 824*k, height: 824*k)
  let shape = CGPath(roundedRect: body, cornerWidth: 185*k, cornerHeight: 185*k, transform: nil)
  ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -10*k), blur: 24*k, color: NSColor.black.withAlphaComponent(0.3).cgColor)
  ctx.addPath(shape); ctx.setFillColor(navy.cgColor); ctx.fillPath(); ctx.restoreGState()
  ctx.saveGState(); ctx.addPath(shape); ctx.clip()
  let grad = CGGradient(colorsSpace: nil, colors: [NSColor(srgbRed: 0.13, green: 0.16, blue: 0.30, alpha: 1).cgColor, NSColor(srgbRed: 0.04, green: 0.05, blue: 0.12, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
  ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
  let gb = bounds(g + gl), sc = 520*k / gb.height
  ctx.translateBy(x: S/2 - gb.midX*sc, y: S/2 - gb.midY*sc); ctx.scaleBy(x: sc, y: sc)
  ctx.setFillColor(cream.cgColor); for p in g { ctx.addPath(p); ctx.fillPath() }
  ctx.setShadow(offset: .zero, blur: 22*k/sc, color: amber.withAlphaComponent(0.8).cgColor)
  ctx.setFillColor(amber.cgColor); for p in gl { ctx.addPath(p) }; ctx.fillPath()
  ctx.restoreGState()
  return ctx.makeImage()!
}
func save(_ img: CGImage, _ file: String) { try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: file)) }
save(appIcon(1024), "\(out)/chargnr-app-icon-1024.png")
let set = "\(out)/AppIcon.appiconset"; try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
var images: [String] = []
for pt in [16, 32, 128, 256, 512] { for sc in [1, 2] {
  let name = "icon_\(pt)x\(pt)\(sc == 2 ? "@2x" : "").png"; save(appIcon(pt*sc), "\(set)/\(name)")
  images.append("{\"size\":\"\(pt)x\(pt)\",\"idiom\":\"mac\",\"filename\":\"\(name)\",\"scale\":\"\(sc)x\"}") } }
try! "{\"images\":[\(images.joined(separator: ","))],\"info\":{\"version\":1,\"author\":\"xcode\"}}\n".write(toFile: "\(set)/Contents.json", atomically: true, encoding: .utf8)
writeSVG("\(out)/chargnr-mark.svg", ink: "#0E1229", led: "#FA9E1A", bg: nil, paths: g, leds: gl, pad: 6)

// menu bar template glyph: one colour, heavier hairlines so it survives 18pt
let (m, ml) = buildG(thin: 11)
let mb = bounds(m + ml)
for (sz, suf) in [(18, ""), (36, "@2x")] {
  render("\(out)/menubar-glyph\(suf).png", size: CGSize(width: sz, height: sz), bg: nil, ink: .black, led: .black, paths: m, leds: ml, box: mb, pad: CGFloat(sz)/18)
}
writeSVG("\(out)/menubar-glyph.svg", ink: "#000000", led: "#000000", bg: nil, paths: m, leds: ml, pad: 4)
