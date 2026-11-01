import Foundation
import AppKit
import SwiftUI
import WebKit
import Compression

// 눈누(noonnu.cc) 무료 한글 폰트 — jsDelivr 웹폰트(woff/woff2)로 설치 없이 미리보기.
//   woff  → 앱이 직접 풀어(zlib) sfnt 로 복원 → CoreText 라이브 미리보기 (Google 폰트와 같은 길)
//   woff2 → CoreText 가 못 읽으므로 숨은 WKWebView 캔버스에 그려 PNG 로 (글자는 진짜 폰트, 이미지라 드래그 선택만 안 됨)
// 목록·상세 수집 = native/build_noonnu.py (번들 noonnu.json). 앱의 「눈누 새로고침」은 목록만 다시 받아 새 폰트를 추가한다.

// MARK: - 데이터

struct NoonnuFile: Codable, Hashable { let family: String; let url: String }
struct NoonnuItem: Codable {
    let id: String            // "nn:<페이지 id>"
    let page: String
    let name: String
    let family: String        // @font-face 패밀리 토큰 (대표 굵기)
    let webfont: String       // 대표 웹폰트 URL
    let thumb: String?
    let maker: String?
    let variants: String?
    let files: [NoonnuFile]?
    let download: String?
    let uses: [String: String]?
    let license: String?
    let format: String?
}
struct NoonnuDB: Codable { var version: Int; var fetched: String; var count: Int; var items: [NoonnuItem] }

enum NoonnuStore {
    static let FILE = CONF_DIR.appendingPathComponent("noonnu.json")
    static func load() -> NoonnuDB? {
        for u in [FILE, Bundle.main.url(forResource: "noonnu", withExtension: "json")].compactMap({ $0 }) {
            if let d = try? Data(contentsOf: u), let db = try? JSONDecoder().decode(NoonnuDB.self, from: d), !db.items.isEmpty { return db }
        }
        return nil
    }
    static func save(_ db: NoonnuDB) {
        try? FileManager.default.createDirectory(at: CONF_DIR, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        if let d = try? enc.encode(db) { try? d.write(to: FILE, options: .atomic) }
    }
}

// MARK: - 눈누 목록 새로고침 (앱 안에서 — 상세는 안 긁고 목록 카드만, 기존 상세는 유지)

enum NoonnuFetcher {
    static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    static func page(_ n: Int) async throws -> String {
        var req = URLRequest(url: URL(string: "https://noonnu.cc/index?sort=recent&page=\(n)")!)
        req.setValue(ua, forHTTPHeaderField: "User-Agent"); req.setValue("ko", forHTTPHeaderField: "Accept-Language"); req.timeoutInterval = 30
        let (d, _) = try await URLSession.shared.data(for: req)
        return String(decoding: d, as: UTF8.self)
    }
    static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.dotMatchesLineSeparators]) }
    static func first(_ r: NSRegularExpression, _ s: String, _ g: Int = 1) -> String? {
        guard let m = r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let rr = Range(m.range(at: g), in: s) else { return nil }
        return String(s[rr])
    }
    static let rxHref = rx(#"href="/font_page/(\d+)""#), rxFace = rx(#"font-family:\s*'([^']+)';\s*src:\s*url\('([^']+)'\)"#)
    static let rxAlt = rx(#"<img[^>]+alt="([^"]*)""#), rxThumb = rx(#"<img[^>]+src="([^"]+)""#), rxVar = rx(#"(\d+가지 굵기)"#)
    static let rxTag = rx(#"<[^>]+>"#), rxStyle = rx(#"<style>.*?</style>"#), rxSvg = rx(#"<svg.*?</svg>"#)

    /// 전체 목록을 받아 (id → 카드 정보). 빈 페이지가 나오면 끝.
    static func fetchAll(progress: @escaping @MainActor (Int) -> Void) async throws -> [NoonnuItem] {
        var out: [NoonnuItem] = []; var seen = Set<String>()
        for n in 1...90 {
            let html = try await page(n)
            let cards = html.components(separatedBy: "<div class=\"min-w-[300px] h-[300px]").dropFirst()
            if cards.isEmpty { break }
            for c in cards {
                guard let pid = first(rxHref, c), seen.insert(pid).inserted else { continue }
                guard let m = rxFace.firstMatch(in: c, range: NSRange(c.startIndex..., in: c)),
                      let fr = Range(m.range(at: 1), in: c), let ur = Range(m.range(at: 2), in: c) else { continue }
                var plain = rxStyle.stringByReplacingMatches(in: c, range: NSRange(c.startIndex..., in: c), withTemplate: "")
                plain = rxSvg.stringByReplacingMatches(in: plain, range: NSRange(plain.startIndex..., in: plain), withTemplate: "")
                plain = rxTag.stringByReplacingMatches(in: plain, range: NSRange(plain.startIndex..., in: plain), withTemplate: "|")
                let parts = plain.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                let name = (first(rxAlt, c) ?? String(c[fr])).replacingOccurrences(of: "&amp;", with: "&")
                let url = String(c[ur])
                out.append(NoonnuItem(id: "nn:" + pid, page: "https://noonnu.cc/font_page/\(pid)", name: name, family: String(c[fr]), webfont: url,
                                      thumb: first(rxThumb, c), maker: parts.count > 1 ? parts[1] : nil, variants: first(rxVar, c), files: nil, download: nil, uses: nil, license: nil,
                                      format: url.hasSuffix(".woff2") ? "woff2" : url.hasSuffix(".woff") ? "woff" : (url as NSString).pathExtension))
            }
            await progress(out.count)
        }
        return out
    }
}

// MARK: - WOFF(1) → sfnt

enum WOFF {
    static func decode(_ d: Data) -> Data? {
        guard d.count > 44, d[d.startIndex] == 0x77, d[d.startIndex + 1] == 0x4F, d[d.startIndex + 2] == 0x46, d[d.startIndex + 3] == 0x46 else { return nil } // "wOFF"
        func u32(_ o: Int) -> UInt32 { let b = d.startIndex + o; return UInt32(d[b]) << 24 | UInt32(d[b + 1]) << 16 | UInt32(d[b + 2]) << 8 | UInt32(d[b + 3]) }
        func u16(_ o: Int) -> UInt16 { let b = d.startIndex + o; return UInt16(d[b]) << 8 | UInt16(d[b + 1]) }
        let flavor = u32(4), numTables = Int(u16(12))
        guard numTables > 0, numTables < 64, d.count >= 44 + numTables * 20 else { return nil }
        struct E { let tag: UInt32, off: Int, comp: Int, orig: Int, chk: UInt32 }
        var es: [E] = []
        for i in 0..<numTables { let b = 44 + i * 20; es.append(E(tag: u32(b), off: Int(u32(b + 4)), comp: Int(u32(b + 8)), orig: Int(u32(b + 12)), chk: u32(b + 16))) }
        var maxPow2 = 1, log2 = 0; while maxPow2 * 2 <= numTables { maxPow2 *= 2; log2 += 1 }
        var out = Data(); func be32(_ v: UInt32) { out.append(contentsOf: [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]) }
        func be16(_ v: Int) { out.append(contentsOf: [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]) }
        be32(flavor); be16(numTables); be16(maxPow2 * 16); be16(log2); be16(numTables * 16 - maxPow2 * 16)
        var tables = Data(); var dir = Data()
        let base = 12 + 16 * numTables
        for e in es {
            guard e.off + e.comp <= d.count else { return nil }
            let raw = d.subdata(in: (d.startIndex + e.off)..<(d.startIndex + e.off + e.comp))
            let t: Data
            if e.comp < e.orig { guard let x = inflate(raw, e.orig) else { return nil }; t = x } else { t = raw }
            func dbe32(_ v: UInt32) { dir.append(contentsOf: [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]) }
            dbe32(e.tag); dbe32(e.chk); dbe32(UInt32(base + tables.count)); dbe32(UInt32(e.orig))
            tables.append(t)
            while tables.count % 4 != 0 { tables.append(0) }
        }
        out.append(dir); out.append(tables)
        return out
    }
    /// zlib 스트림(2바이트 헤더 + deflate + adler32) → 원본. Compression 의 ZLIB 는 raw deflate 라 헤더를 건너뛴다.
    static func inflate(_ z: Data, _ expected: Int) -> Data? {
        guard z.count > 2, expected > 0 else { return nil }
        var dst = [UInt8](repeating: 0, count: expected)
        let n = z.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            compression_decode_buffer(&dst, expected, src.baseAddress!.advanced(by: 2).assumingMemoryBound(to: UInt8.self), z.count - 2, nil, COMPRESSION_ZLIB)
        }
        return n == expected ? Data(dst) : nil
    }
}

// MARK: - 웹폰트 캔버스 렌더러 (woff2 용) — 숨은 WKWebView 하나, 작업은 직렬

@MainActor
final class WebFontRenderer: NSObject, WKNavigationDelegate {
    static let shared = WebFontRenderer()
    private let web: WKWebView
    private var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var busy = false
    private override init() {
        let cfg = WKWebViewConfiguration()
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1600, height: 800), configuration: cfg)
        super.init()
        web.navigationDelegate = self
        // 원점이 null 이면 일부 CDN 이 CORS 를 거절할 수 있어 눈누 주소를 베이스로 둔다 (폰트 fetch 의 Origin 헤더용)
        web.loadHTMLString("<!doctype html><html><head><meta charset=utf-8></head><body style='margin:0;background:transparent'><canvas id=c></canvas></body></html>", baseURL: URL(string: "https://noonnu.cc/"))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; waiters.forEach { $0.resume() }; waiters = [] }
    private func waitReady() async { if ready { return }; await withCheckedContinuation { waiters.append($0) } }

    private static let js = """
    const fam = family, url = fontURL;
    // document.fonts.check() 는 모르는 패밀리에 true 를 돌려주므로(로드할 게 없다는 뜻) 직접 기록한다
    window.__loaded = window.__loaded || new Set();
    if (!window.__loaded.has(url)) {
      const f = new FontFace(fam, `url(${JSON.stringify(url)})`);
      await f.load(); document.fonts.add(f); window.__loaded.add(url);
    }
    if (!document.fonts.check(`20px "${fam}"`)) throw new Error('font not available: ' + fam);
    const c = document.getElementById('c'); const ctx = c.getContext('2d');
    const px = size * scale, maxW = maxWidth * scale;
    ctx.font = `${px}px "${fam}"`;
    const words = text.split(' '); const lines = []; let cur = '';
    for (const w of words) { const t = cur ? cur + ' ' + w : w; if (ctx.measureText(t).width > maxW && cur) { lines.push(cur); cur = w; } else { cur = t; } }
    if (cur) lines.push(cur);
    const lh = px * 1.28;
    c.width = Math.ceil(maxW); c.height = Math.ceil(lines.length * lh + px * 0.35);
    ctx.font = `${px}px "${fam}"`; ctx.fillStyle = color; ctx.textBaseline = 'alphabetic';
    lines.forEach((l, i) => ctx.fillText(l, 0, px * 0.98 + i * lh));
    return c.toDataURL('image/png');
    """

    /// 문구를 그 웹폰트로 그린 PNG (포인트 크기 = 픽셀/scale). 실패하면 nil.
    func render(fontURL: String, family: String, text: String, size: CGFloat, color: NSColor, maxWidth: CGFloat, scale: CGFloat = 2) async -> NSImage? {
        await waitReady()
        while busy { try? await Task.sleep(nanoseconds: 25_000_000) }
        busy = true; defer { busy = false }
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let css = String(format: "rgb(%d,%d,%d)", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
        let args: [String: Any] = ["family": family, "fontURL": fontURL, "text": text, "size": size, "scale": scale, "maxWidth": maxWidth, "color": css]
        let result: Any? = await withCheckedContinuation { cont in
            web.callAsyncJavaScript(WebFontRenderer.js, arguments: args, in: nil, in: .page) { r in
                switch r { case .success(let v): cont.resume(returning: v); case .failure: cont.resume(returning: nil) }
            }
        }
        guard let s = result as? String, let comma = s.firstIndex(of: ","), let data = Data(base64Encoded: String(s[s.index(after: comma)...])),
              let rep = NSBitmapImageRep(data: data) else { return nil }
        let img = NSImage(size: NSSize(width: CGFloat(rep.pixelsWide) / scale, height: CGFloat(rep.pixelsHigh) / scale))
        img.addRepresentation(rep)
        return img
    }
}
