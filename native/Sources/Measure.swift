import Foundation
import CoreText
import CoreGraphics

// 알파 전용 비트맵. 메모리 0번 줄이 이미지 맨 위 → 웹판(캔버스, y 아래 방향) 알고리즘을 그대로 쓴다.
final class Bitmap {
    let w: Int, h: Int
    let buf: UnsafeMutablePointer<UInt8>
    let ctx: CGContext
    init(_ w: Int, _ h: Int) {
        self.w = w; self.h = h
        buf = .allocate(capacity: w * h)
        buf.initialize(repeating: 0, count: w * h)
        ctx = CGContext(data: buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: nil as CGColorSpace?, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.alphaOnly.rawValue))!
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldSmoothFonts(false)
        ctx.setTextDrawingMode(.fill)
    }
    deinit { buf.deallocate() }
    func clear() { buf.update(repeating: 0, count: w * h) }
    @inline(__always) func at(_ x: Int, _ y: Int) -> UInt8 { buf[y * w + x] }
    /// 글자를 그리고 타이포그래픽 폭을 돌려준다. baseline 은 '위에서부터' 거리.
    @discardableResult
    func draw(_ text: String, _ font: CTFont, x: CGFloat, baseline: CGFloat) -> CGFloat {
        let attr = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: x, y: CGFloat(h) - baseline)
        CTLineDraw(line, ctx)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

struct GlyphBox { let x0, y0, x1, y1, n: Int }

enum Measure {
    static let A: UInt8 = 120
    static let GW = 320, GH = 160, GS: CGFloat = 96
    static let SW = 760, SH = 128, SS: CGFloat = 64, AS: UInt8 = 60

    static func has(_ font: CTFont, _ s: String) -> Bool {
        let u = Array(s.utf16)
        var g = [CGGlyph](repeating: 0, count: u.count)
        return CTFontGetGlyphsForCharacters(font, u, &g, u.count)
    }
    static func advance(_ font: CTFont, _ ch: Character) -> CGFloat {
        let u = Array(String(ch).utf16)
        var g = [CGGlyph](repeating: 0, count: u.count)
        CTFontGetGlyphsForCharacters(font, u, &g, u.count)
        return CTFontGetAdvancesForGlyphs(font, .horizontal, g, nil, 1)
    }

    static func glyph(_ bm: Bitmap, _ font: CTFont, _ ch: String) -> GlyphBox? {
        bm.clear()
        bm.draw(ch, font, x: 16, baseline: 120)
        var x0 = bm.w, y0 = bm.h, x1 = -1, y1 = -1, n = 0
        for y in 0..<bm.h { for x in 0..<bm.w where bm.at(x, y) > A { n += 1; if x < x0 { x0 = x }; if x > x1 { x1 = x }; if y < y0 { y0 = y }; if y > y1 { y1 = y } } }
        return n > 0 ? GlyphBox(x0: x0, y0: y0, x1: x1, y1: y1, n: n) : nil
    }
    static func rowRuns(_ bm: Bitmap, _ g: GlyphBox, _ y: Int) -> [Int] {
        var r: [Int] = [], c = 0
        for x in g.x0...g.x1 { if bm.at(x, y) > A { c += 1 } else if c > 0 { r.append(c); c = 0 } }
        if c > 0 { r.append(c) }
        return r
    }
    static func rowInk(_ bm: Bitmap, _ g: GlyphBox, _ y: Int) -> Int { var n = 0; for x in g.x0...g.x1 where bm.at(x, y) > A { n += 1 }; return n }
    static func centroid(_ bm: Bitmap, _ g: GlyphBox, _ ya: Int, _ yb: Int) -> Double? {
        var s = 0, n = 0
        for y in ya...yb { for x in g.x0...g.x1 where bm.at(x, y) > A { s += x; n += 1 } }
        return n > 0 ? Double(s) / Double(n) : nil
    }
    struct Stem { let stem: Int; let foot: Double; let slant: Double; let outline: Int }
    static func stemStats(_ bm: Bitmap, _ g: GlyphBox) -> Stem {
        let h = g.y1 - g.y0 + 1, ym = g.y0 + h / 2
        let runs = rowRuns(bm, g, ym), stem = max(1, runs.max() ?? 1)
        let band = max(2, Int((Double(h) * 0.08).rounded()))
        var endMax = 0
        for y in g.y0..<min(g.y1 + 1, g.y0 + band) { endMax = max(endMax, rowInk(bm, g, y)) }
        for y in max(g.y0, g.y1 - band + 1)...g.y1 { endMax = max(endMax, rowInk(bm, g, y)) }
        let q = max(2, Int((Double(h) * 0.2).rounded()))
        let cT = centroid(bm, g, g.y0, min(g.y1, g.y0 + q)), cB = centroid(bm, g, max(g.y0, g.y1 - q), g.y1)
        let slant = (cT != nil && cB != nil && h - q > 0) ? (cT! - cB!) / Double(h - q) : 0
        return Stem(stem: stem, foot: Double(endMax) / Double(stem), slant: slant, outline: runs.count >= 2 ? 1 : 0)
    }
    static func cornerFill(_ bm: Bitmap, _ g: GlyphBox) -> Double {
        let t = g.y1 - g.y0 + 1, r = max(2, Int((Double(t) / 4).rounded()))
        var n = 0, tot = 0
        for (cx, cy) in [(g.x0, g.y0), (g.x1 - r + 1, g.y0), (g.x0, g.y1 - r + 1), (g.x1 - r + 1, g.y1 - r + 1)] {
            for y in cy..<(cy + r) { for x in cx..<(cx + r) {
                guard x >= 0, y >= 0, x < bm.w, y < bm.h else { continue }
                tot += 1; if bm.at(x, y) > A { n += 1 }
            } }
        }
        return tot > 0 ? Double(n) / Double(tot) : 1
    }
    /// 직선 비율(s)과 잉크 밀도(d)
    static func strokeStats(_ bm: Bitmap, _ font: CTFont, _ text: String) -> (s: Double, d: Double)? {
        bm.clear()
        let w = bm.draw(text, font, x: 8, baseline: 96)
        let W = bm.w, H = bm.h
        var onp = [UInt8](repeating: 0, count: W * H), ink = 0
        for i in 0..<(W * H) where bm.buf[i] > AS { onp[i] = 1; ink += 1 }
        if ink == 0 { return nil }
        let L = Int((SS * 0.28).rounded())
        var mark = [UInt8](repeating: 0, count: W * H)
        for y in 0..<H {
            var s = -1
            for x in 0...W {
                let v = x < W && onp[y * W + x] == 1
                if v && s < 0 { s = x }
                if !v && s >= 0 { if x - s >= L { for k in s..<x { mark[y * W + k] = 1 } }; s = -1 }
            }
        }
        for x in 0..<W {
            var s = -1
            for y in 0...H {
                let v = y < H && onp[y * W + x] == 1
                if v && s < 0 { s = y }
                if !v && s >= 0 { if y - s >= L { for k in s..<y { mark[k * W + x] = 1 } }; s = -1 }
            }
        }
        var m = 0
        for i in 0..<(W * H) { m += Int(mark[i]) }
        return (Double(m) / Double(ink), Double(ink) / (Double(min(w, CGFloat(W - 8))) * Double(SS)))
    }
    static func irregularity(_ bm: Bitmap, _ font: CTFont, _ chars: [String]) -> Double? {
        var tops: [Double] = [], bots: [Double] = []
        for ch in chars { if let g = glyph(bm, font, ch) { tops.append(Double(g.y0)); bots.append(Double(g.y1)) } }
        if tops.count < 4 { return nil }
        func sd(_ a: [Double]) -> Double { let m = a.reduce(0, +) / Double(a.count); return (a.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(a.count)).squareRoot() }
        return ((sd(tops) + sd(bots)) / 2) / Double(GS)
    }

    /// 폰트 한 벌 분석 (백그라운드 스레드에서 호출)
    static func analyze(_ item: FontItem, gbm: Bitmap, sbm: Bitmap) -> Profile {
        var p = Profile()
        let f96 = item.ctFont(GS)
        // 요청한 폰트가 아닌 대체 폰트가 왔으면 '못 찾음'
        if item.source != .folder, let got = CTFontCopyPostScriptName(f96) as String?, got != item.ps, !got.isEmpty { p.err = 1; return p }
        let f64 = item.ctFont(SS)
        p.ko = has(f96, "한글") ? 1 : 0
        p.la = has(f96, "Hamburg") ? 1 : 0
        p.ja = has(f96, "あア") ? 1 : 0
        p.hj = has(f96, "漢字") ? 1 : 0
        let vch: String? = (p.ko == 1 && has(f96, "ㅣ")) ? "ㅣ" : (p.la == 1 ? "l" : nil)
        let hch: String? = (p.ko == 1 && has(f96, "ㅡ")) ? "ㅡ" : (p.la == 1 ? "-" : nil)
        if let v = vch, let g = glyph(gbm, f96, v) {
            let s = stemStats(gbm, g)
            p.stem = (Double(s.stem) / Double(GS) * 1000).rounded() / 1000
            p.foot = (s.foot * 100).rounded() / 100
            p.slant = (s.slant * 1000).rounded() / 1000
            p.outline = s.outline
        }
        if let hc = hch, let g = glyph(gbm, f96, hc) {
            p.bar = (Double(g.y1 - g.y0 + 1) / Double(GS) * 1000).rounded() / 1000
            p.corner = (cornerFill(gbm, g) * 100).rounded() / 100
        }
        if let st = p.stem, let b = p.bar, b > 0 { p.contrast = (st / b * 100).rounded() / 100 }
        if let a = (p.ko == 1 ? "한" : p.la == 1 ? "H" : nil), let g = glyph(gbm, f96, a) {
            p.aspect = (Double(g.x1 - g.x0 + 1) / Double(g.y1 - g.y0 + 1) * 100).rounded() / 100
        }
        if let sample = (p.ko == 1 ? "다람쥐 헌 쳇바퀴" : p.la == 1 ? "Hamburgefons" : nil), let r = strokeStats(sbm, f64, sample) {
            p.straight = (r.s * 100).rounded() / 100
            p.density = (r.d * 1000).rounded() / 1000
        }
        if let ich = (p.ko == 1 ? ["가", "나", "다", "라", "마", "바", "사", "아", "자", "하"] : p.la == 1 ? ["n", "m", "u", "r", "v", "w", "x", "z"] : nil), let r = irregularity(gbm, f96, ich) {
            p.irr = (r * 1000).rounded() / 1000
        }
        if p.la == 1 {
            let wi = advance(f96, "i"), wm = advance(f96, "m"), ww = advance(f96, "W")
            p.mono = (wm > 0 && abs(wi - wm) < wm * 0.03 && abs(ww - wm) < wm * 0.03) ? 1 : 0
        }
        return p
    }
}
