import Foundation
import SwiftUI
import AppKit
import CoreText
import Security
import UniformTypeIdentifiers

// Typeface Scout — 설치 폰트를 Muse Spark(비전)로 디자이너 어휘 태깅 → 자연어 브리프로 검색.
// Meta Model API (OpenAI 호환 Chat Completions). 모델은 Standard 모드 고정 — `-contributor` 변형은 학습 제공 조건이라 쓰지 않는다.

// MARK: - API 키 (Keychain, 개발용 폴백 = 환경변수 MODEL_API_KEY)

enum ScoutKey {
    static let service = "com.haileydayz.fontviewer.scout"
    static let account = "meta_model_api_key"
    static func load() -> String? {
        if let e = ProcessInfo.processInfo.environment["MODEL_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty { return e }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }
    static func save(_ key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        var add = base; add[kSecValueData as String] = Data(k.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - 태그

struct ScoutTag: Codable, Hashable {
    var mood: [String] = []
    var style: [String] = []
    var era: String = ""
    var weightFeel: String = ""
    var bestUse: [String] = []
    var latin: Bool = true
    var korean: Bool = false
    var personality: String = ""
    var avoid: String = ""
    var model: String = ""
    var at: TimeInterval = 0

    /// 검색 카탈로그 한 줄 (프롬프트 캐시를 위해 결정적으로)
    func line(id: String, name: String) -> String {
        var s = "\(id) | \(name) | mood: \(mood.joined(separator: ", ")) | style: \(style.joined(separator: ", "))"
        if !era.isEmpty { s += " | era: \(era)" }
        if !weightFeel.isEmpty { s += " | weight: \(weightFeel)" }
        if !bestUse.isEmpty { s += " | use: \(bestUse.joined(separator: ", "))" }
        s += " | scripts: " + ((latin ? ["Latin"] : []) + (korean ? ["Korean"] : [])).joined(separator: "+")
        if !personality.isEmpty { s += " | \(personality)" }
        if !avoid.isEmpty { s += " | avoid: \(avoid)" }
        return s
    }
    /// 화면용 요약
    var summary: String {
        var parts = mood.prefix(4).map { $0 }
        if !weightFeel.isEmpty { parts.append(weightFeel) }
        parts += bestUse.prefix(2)
        return parts.joined(separator: " · ")
    }
    /// 로컬 폴백 검색용 전체 텍스트
    var haystack: String { (mood + style + bestUse + [era, weightFeel, personality]).joined(separator: " ").lowercased() }
}

/// 모델이 돌려주는 JSON (snake_case)
private struct TagReply: Codable {
    var mood: [String]
    var style: [String]
    var era: String
    var weight_feel: String
    var best_use: [String]
    var personality: String
    var avoid: String
}

struct ScoutResult: Identifiable, Hashable {
    let item: FontItem
    var score: Int
    var why: String
    var palette: String = "paper"
    var legibility: Int = 0          // 아트디렉터 2차 심사: 한눈에 읽히는 글(가격·상품명)로 쓸 때 1~5, 0 = 미심사
    var roleFit: String = ""         // headline · price · sub · body · avoid
    var note: String = ""            // 디자이너가 납득할 한 줄 (브리프 언어)
    var direction: Int = 0           // 2차 심사가 정한 소속 방향 (1-based, 0 = 없음) → 타일 배경·레이아웃 재사용
    var id: String { item.id }
}

/// 보드 타일·조합 카드에 넣는 샘플 카피 — 브리프의 장르에 맞게 Muse Spark 가 줄마다 역할·크기를 정해 짠다 (세일 POP 이면 상품·가격이 크게, 로고면 이름이 크게)
struct ScoutLine: Codable, Hashable {
    var role = "headline"      // kicker · headline · price · sub · body · title · byline · label
    var size = "l"             // xl · l · m · s
    var text = ""
    var text_en = ""           // 영문 전용 폰트용 짝
    func text(korean: Bool) -> String { (!korean && ScoutCopy.hasHangul(text) && !text_en.isEmpty) ? text_en : text }
    var pt: CGFloat { switch size { case "xl": return 46; case "l": return 30; case "m": return 16; default: return 11.5 } }
    var opacity: Double { size == "s" ? 0.75 : size == "m" ? 0.88 : 1 }
    var isSmall: Bool { size == "s" }
}
struct ScoutCopy: Codable, Hashable {
    var genre = ""
    var align = "left"         // left · center
    var lines: [ScoutLine] = []
    static func hasHangul(_ t: String) -> Bool { t.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } }
    var isEmpty: Bool { lines.isEmpty }
    var centered: Bool { align == "center" }
    static func fallback(_ brief: String) -> ScoutCopy {
        let t = String(brief.prefix(14))
        return ScoutCopy(genre: "brief", align: "left", lines: [ScoutLine(role: "headline", size: "l", text: t, text_en: t)])
    }
}

/// 조합 제안: 제목·부제·본문 폰트 3벌
struct ScoutPair: Identifiable, Hashable {
    let headline: FontItem, sub: FontItem, body: FontItem
    var price: FontItem                 // 가격·숫자 전용 슬롯 — 제목이 거칠어도 숫자는 읽히게
    let why: String
    let palette: String
    var layout: String = "overlay"      // overlay · split · band · badge · frame · poster
    var imagePrompt: String = ""
    var name: String = ""               // 방향 이름 (예: «거칠고 따뜻하게»)
    var mood: String = ""
    var id: String { headline.id + "|" + price.id + "|" + sub.id + "|" + body.id }
    init(headline: FontItem, sub: FontItem, body: FontItem, price: FontItem? = nil, why: String, palette: String) {
        self.headline = headline; self.sub = sub; self.body = body; self.price = price ?? headline; self.why = why; self.palette = palette
    }
}

/// 타일 바탕색 — 모델이 폰트·브리프 분위기에 맞춰 이름으로 고른다
enum ScoutPalette {
    static let names = ["paper", "ink-cream", "navy-gold", "kraft", "blush", "forest", "neon-dark", "sky", "mustard", "terracotta", "lavender", "mint", "sale-red", "yellow-black", "cream-red"]
    private static func c(_ r: Int, _ g: Int, _ b: Int) -> Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
    static let table: [String: (bg: Color, fg: Color)] = [
        "paper": (c(250, 247, 242), c(34, 34, 34)),
        "ink-cream": (c(27, 27, 31), c(243, 235, 221)),
        "navy-gold": (c(31, 53, 80), c(230, 198, 128)),
        "kraft": (c(201, 160, 116), c(59, 42, 26)),
        "blush": (c(246, 215, 218), c(90, 42, 51)),
        "forest": (c(31, 59, 46), c(220, 232, 213)),
        "neon-dark": (c(18, 18, 18), c(255, 79, 163)),
        "sky": (c(217, 236, 247), c(31, 53, 80)),
        "mustard": (c(242, 193, 78), c(43, 33, 24)),
        "terracotta": (c(201, 106, 74), c(255, 241, 230)),
        "lavender": (c(228, 221, 242), c(58, 46, 92)),
        "mint": (c(214, 240, 230), c(30, 77, 60)),
        "sale-red": (c(215, 38, 43), c(255, 226, 122)),
        "yellow-black": (c(255, 210, 63), c(17, 17, 17)),
        "cream-red": (c(255, 244, 224), c(200, 16, 46)),
    ]
    static func colors(_ name: String) -> (bg: Color, fg: Color) { table[name] ?? table["paper"]! }
}

struct ScoutUsage: Codable {
    var input = 0, output = 0, cached = 0, calls = 0
    var images = 0                                           // Muse Image 생성 장수 ($0.01/장)
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        input = try c.decodeIfPresent(Int.self, forKey: .input) ?? 0; output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        cached = try c.decodeIfPresent(Int.self, forKey: .cached) ?? 0; calls = try c.decodeIfPresent(Int.self, forKey: .calls) ?? 0
        images = try c.decodeIfPresent(Int.self, forKey: .images) ?? 0
    }
    /// Muse Spark 1.3 Standard: 입력 $1.25/M · 캐시 입력 $0.15/M · 출력 $4.25/M · Muse Image $0.01/장
    var usd: Double { Double(max(0, input - cached)) * 1.25e-6 + Double(cached) * 0.15e-6 + Double(output) * 4.25e-6 + Double(images) * 0.01 }
    mutating func add(_ o: ScoutUsage) { input += o.input; output += o.output; cached += o.cached; calls += o.calls; images += o.images }
}

private struct ScoutCache: Codable {
    var tags: [String: ScoutTag] = [:]
    var usage = ScoutUsage()
    var prefs: [String: Int]? = nil      // 👍 = 1 · 👎 = -1 (패밀리 대표 id 기준)
}

// MARK: - 샘플 렌더 (RGB JPEG — 비전 모델 입력)

enum ScoutRender {
    static let W = 896, H = 280
    static let latinA = "Hamburgefonstiv AaQg 0123 &?"
    static let latinB = "The quick brown fox jumps"
    static let korean = "다람쥐 헌 쳇바퀴에 타고파 가나다"

    /// 폰트에 글리프가 있는 글자만 남긴다 (대체 폰트가 섞여 들어가 엉뚱한 태그가 붙는 걸 막는다)
    static func covered(_ text: String, _ font: CTFont) -> String {
        String(text.filter { ch in ch == " " || Measure.has(font, String(ch)) })
    }

    static func jpeg(_ item: FontItem, korean ko: Bool) -> Data? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setShouldAntialias(true); ctx.setAllowsFontSmoothing(true); ctx.setShouldSmoothFonts(true)
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
        let probe = item.ctFont(40)
        var lines: [(String, CGFloat, CGFloat)] = []
        if ko {
            lines = [(covered(latinA, probe), 88, 98), (covered(korean, probe), 76, 228)]
        } else {
            lines = [(covered(latinA, probe), 104, 112), (covered(latinB, probe), 60, 228)]
        }
        var drew = false
        for (text, size, baseline) in lines where text.trimmingCharacters(in: .whitespaces).count >= 2 {
            draw(text, item, size: size, baseline: baseline, ctx: ctx); drew = true
        }
        if !drew { draw(item.full, item, size: 72, baseline: 160, ctx: ctx) }
        guard let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    /// 2차 심사용: 후보 폰트로 카피의 제목 줄 + 가격(또는 부제) 줄을 그린다
    static func copyCard(_ item: FontItem, lines: [String]) -> Data? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setShouldAntialias(true); ctx.setAllowsFontSmoothing(true); ctx.setShouldSmoothFonts(true)
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
        let ls = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(2)
        if ls.count == 2 { draw(ls[ls.startIndex], item, size: 84, baseline: 104, ctx: ctx); draw(ls[ls.startIndex + 1], item, size: 92, baseline: 232, ctx: ctx) }
        else if let one = ls.first { draw(one, item, size: 110, baseline: 170, ctx: ctx) }
        else { draw(item.full, item, size: 72, baseline: 160, ctx: ctx) }
        guard let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    private static func ctline(_ text: String, _ font: CTFont) -> CTLine {
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        return CTLineCreateWithAttributedString(attr)
    }
    private static func draw(_ text: String, _ item: FontItem, size: CGFloat, baseline: CGFloat, ctx: CGContext) {
        var sz = size
        var line = ctline(text, item.ctFont(sz))
        var w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let maxW = CGFloat(W - 56)
        if w > maxW, w > 0 { sz = max(14, sz * maxW / w); line = ctline(text, item.ctFont(sz)); w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) }
        ctx.textPosition = CGPoint(x: 28, y: CGFloat(H) - baseline)
        CTLineDraw(line, ctx)
    }
}

// MARK: - 사진 입력 (간판·포스터 → 비전 입력 JPEG)

enum ScoutPhoto {
    /// 긴 변 1024 로 줄여 JPEG — 사진 1장 ≈ 1,000 입력 토큰 안팎
    static func jpeg(_ image: NSImage, maxEdge: CGFloat = 1024) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, maxEdge / max(w, h))
        let tw = max(1, Int(w * scale)), th = max(1, Int(h * scale))
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: tw, height: th))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}

extension ScoutPhoto {
    /// 눈누 썸네일(투명 PNG, ~450×150) → 흰 배경 JPEG (비전 입력)
    static func thumbJPEG(_ png: Data) -> Data? {
        guard let img = NSImage(data: png), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}

// MARK: - Meta Model API

enum ScoutAPI {
    static let endpoint = URL(string: "https://api.meta.ai/v1/chat/completions")!
    static let model = "muse-spark-1.3"
    static let tagEffort = "low"   // 11/1 비교: minimal 은 flared serif 를 놓침, low 가 구조 판정 정확 (폰트당 ≈$0.005)
    struct Err: Error, LocalizedError { let msg: String; var errorDescription: String? { msg } }

    /// Chat Completions + JSON 스키마 출력. 429/5xx 는 지수 백오프 4회.
    /// Muse Spark 는 항상 추론 토큰을 먼저 쓰고(출력 토큰에 포함·과금) `max_tokens` 가 추론+본문 합계라, 본문이 잘리지 않게 넉넉히 준다. `reasoning_effort: "none"` 은 400.
    static func chat(key: String, system: String, user: [[String: Any]], schemaName: String, schema: [String: Any], maxTokens: Int, effort: String) async throws -> (String, ScoutUsage) {
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "max_tokens": maxTokens,
            "reasoning_effort": effort,
            "temperature": 0.2,
            "response_format": ["type": "json_schema", "json_schema": ["name": schemaName, "schema": schema]],
        ]
        var req = URLRequest(url: endpoint); req.httpMethod = "POST"; req.timeoutInterval = 180
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        var delay: UInt64 = 1_500_000_000
        for attempt in 0..<5 {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = j["choices"] as? [[String: Any]], let msg = choices.first?["message"] as? [String: Any] else { throw Err(msg: "unexpected response shape") }
                var content = ""
                if let s = msg["content"] as? String { content = s }
                else if let arr = msg["content"] as? [[String: Any]] { content = arr.compactMap { $0["text"] as? String }.joined() }
                var u = ScoutUsage(); u.calls = 1
                if let us = j["usage"] as? [String: Any] {
                    u.input = us["prompt_tokens"] as? Int ?? 0; u.output = us["completion_tokens"] as? Int ?? 0
                    if let d = us["prompt_tokens_details"] as? [String: Any] { u.cached = d["cached_tokens"] as? Int ?? 0 }
                }
                if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw Err(msg: "empty content (finish: \((choices.first?["finish_reason"] as? String) ?? "?"), \(u.output) output tokens)") }
                return (stripFences(content), u)
            }
            if (code == 429 || code >= 500), attempt < 4 { try await Task.sleep(nanoseconds: delay); delay *= 2; continue }
            let text = String(data: data, encoding: .utf8) ?? ""
            throw Err(msg: "HTTP \(code) " + String(text.prefix(240)))
        }
        throw Err(msg: "retries exhausted")
    }
    static func stripFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") { t = t.replacingOccurrences(of: #"^```[a-zA-Z]*\s*"#, with: "", options: .regularExpression); if t.hasSuffix("```") { t.removeLast(3) } }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func dataURL(_ jpeg: Data) -> String { "data:image/jpeg;base64," + jpeg.base64EncodedString() }

    // 태깅
    static let tagSystem = """
    You are Typeface Scout, a senior typographer and brand designer. You look at a rendered font sample and describe the typeface the way a designer briefs another designer.
    Rules: use plain English design vocabulary; be concrete and discriminating (prefer "chunky geometric sans with squared counters" over "modern"); never guess at the font name; judge only what is visible.
    - mood: 3 to 6 adjectives a designer would use (e.g. warm, playful, elegant, authoritative, quirky, calm, retro, techy, handmade, luxurious).
    - style: 1 to 3 structural classes from: geometric sans, humanist sans, grotesque sans, neo-grotesque, transitional serif, old-style serif, didone, slab serif, rounded, script, brush, marker, monoline handwriting, pixel, stencil, outline, display, blackletter, decorative.
    - era: the period it evokes (e.g. 1920s art deco, 1970s, Y2K, contemporary, timeless).
    - weight_feel: how heavy it reads (hairline, light, regular, medium, bold, heavy, black) plus a note on contrast if notable.
    - best_use: 2 to 4 of: logo, headline, body text, packaging, poster, UI, editorial, kids, café/bakery, luxury, tech, signage, wedding/invitation, handwriting notes, sticker/diary.
    - personality: one sentence (max 20 words) on what it would say about a brand.
    - avoid: a few words on where it would look wrong.
    """
    static let tagSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "mood": ["type": "array", "items": ["type": "string"], "minItems": 3, "maxItems": 6],
            "style": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 3],
            "era": ["type": "string"],
            "weight_feel": ["type": "string"],
            "best_use": ["type": "array", "items": ["type": "string"], "minItems": 2, "maxItems": 4],
            "personality": ["type": "string"],
            "avoid": ["type": "string"],
        ],
        "required": ["mood", "style", "era", "weight_feel", "best_use", "personality", "avoid"],
        "additionalProperties": false,
    ]
    static func tag(key: String, jpeg: Data, korean: Bool, thumbnail: Bool = false) async throws -> (ScoutTag, ScoutUsage) {
        let note = thumbnail ? "This is a small thumbnail of the font's own name set in the font (Korean, Hangul). Judge structure, weight, mood and era from these glyphs; where the sample is too short to tell, say so briefly in avoid rather than guessing."
            : korean ? "This font includes Korean (Hangul) glyphs; line 1 is Latin, line 2 is Korean." : "This font is Latin-only."
        let user: [[String: Any]] = [
            ["type": "text", "text": "Describe this typeface for a designer's font library. \(note) Return JSON only."],
            ["type": "image_url", "image_url": ["url": dataURL(jpeg)]],
        ]
        let (text, u) = try await chat(key: key, system: tagSystem, user: user, schemaName: "typeface_tags", schema: tagSchema, maxTokens: 1600, effort: tagEffort)
        let r = try JSONDecoder().decode(TagReply.self, from: Data(text.utf8))
        var t = ScoutTag(); t.mood = r.mood.map { $0.lowercased() }; t.style = r.style.map { $0.lowercased() }; t.era = r.era; t.weightFeel = r.weight_feel
        t.bestUse = r.best_use.map { $0.lowercased() }; t.personality = r.personality; t.avoid = r.avoid
        t.latin = !thumbnail; t.korean = korean; t.model = thumbnail ? model + " (thumb)" : model; t.at = Date().timeIntervalSince1970
        return (t, u)
    }

    // 검색
    static let searchSystemHead = """
    You are Typeface Scout, a font librarian for a graphic designer. Below is the catalog of fonts installed on the designer's Mac, one per line: id | name | tags.
    Lines marked "NOT INSTALLED (Noonnu, free)" are free Korean fonts the designer has not installed yet; include them when they fit clearly (at most 4 of the 12) so the designer discovers fonts worth installing — they are also valid for pairs.
    Given a brief, choose the fonts from THIS catalog that fit best. Prefer precise fits over popular choices. If the brief needs Korean (Hangul), only pick fonts whose scripts include Korean; if it needs Latin only, Latin-only fonts are fine too. Spread the picks across different styles when the brief allows, so the designer gets options.
    Return at most 12 results, best first, with score 0-100 and a "why" of at most 20 words written in the same language as the brief. Use ids exactly as written.
    If the brief is followed by a DESIGNER'S TASTE section (fonts the designer liked or disliked on earlier results), treat it as a strong signal: never return disliked fonts, avoid fonts that share their qualities, and favor the qualities of liked fonts when the brief allows.
    Also return:
    - copy: sample copy for a mock-up, in the brief's language, as 2 to 4 lines top-to-bottom. First decide the GENRE from the brief and lay the lines out the way that genre really works — this matters more than anything else:
      · sale poster / POP / flyer / price tag / promotion → lead with the PRODUCT and the OFFER, never a shop name: kicker such as "주말 한정" (s), headline = product name (l), price or discount such as "30% OFF" or "$9.99/lb" (xl, the biggest), body = conditions (s).
      · logo / shop sign / label / packaging → name (xl), tagline (m), one sentence (s).
      · book cover / poster title / editorial / magazine → title (xl), subtitle (m), byline or date (s).
      · UI / app / web → screen title (l), button or menu labels (m), helper text (s).
      · anything else → the 2–4 lines a designer would actually set in that piece.
      Each line has role (kicker|headline|price|sub|body|title|byline|label), size (xl|l|m|s; exactly one line is the biggest), text, and text_en (the same line in English, ASCII only, for Latin-only fonts). Names, products and numbers are fictional; never a real brand. align = "center" for posters, price tags, signs and covers, "left" otherwise. genre = one or two words.
    - palette: for each result, one name from [paper, ink-cream, navy-gold, kraft, blush, forest, neon-dark, sky, mustard, terracotta, lavender, mint, sale-red, yellow-black, cream-red] that suits the brief's genre and mood and that font (sale posters usually want sale-red / yellow-black / cream-red; luxury wants ink-cream / navy-gold; kids wants mustard / sky / mint). Vary palettes across the results.
    - pairs: up to 3 font combinations for a layout — headline_id (a display font from the results), sub_id (a secondary font), body_id (a readable text font; may be any id from the catalog, not only from the results; if the brief needs Korean it must include Korean) and why (at most 15 words, in the brief's language). Make the three pairs feel different from each other. For each pair also give:
      · layout: one of [overlay, split, band, badge, frame, poster] — overlay = photo full-bleed with text over a dark gradient (moody, luxury, editorial); split = solid color panel with text beside the photo (clean, editorial, tech); band = photo on top, solid color band with text below (sale POP, flyers, menus); badge = text in a solid box over the photo (price tags, promotions, events); frame = photo inset on a solid card like a label (packaging, labels, invitations); poster = centered text over a tinted photo (posters, covers). Use different layouts across the three pairs.
      · image_prompt: an English prompt (at most 40 words) for a background photo or illustration that fits this pair's mood and the brief's genre: subject, style (photo / illustration / flat graphic), lighting, colors that sit well with the palette, and where to leave empty space for the text. The image must contain no text, letters, logos or people's faces.

    CATALOG
    """
    static let searchSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "copy": ["type": "object",
                     "properties": ["genre": ["type": "string"], "align": ["type": "string"],
                                    "lines": ["type": "array", "minItems": 2, "maxItems": 4, "items": [
                                        "type": "object",
                                        "properties": ["role": ["type": "string"], "size": ["type": "string"], "text": ["type": "string"], "text_en": ["type": "string"]],
                                        "required": ["role", "size", "text", "text_en"], "additionalProperties": false]]],
                     "required": ["genre", "align", "lines"], "additionalProperties": false],
            "results": ["type": "array", "maxItems": 12, "items": [
                "type": "object",
                "properties": ["id": ["type": "string"], "score": ["type": "integer"], "why": ["type": "string"], "palette": ["type": "string"]],
                "required": ["id", "score", "why", "palette"], "additionalProperties": false,
            ]],
            "pairs": ["type": "array", "maxItems": 3, "items": [
                "type": "object",
                "properties": ["headline_id": ["type": "string"], "sub_id": ["type": "string"], "body_id": ["type": "string"], "why": ["type": "string"],
                               "layout": ["type": "string"], "image_prompt": ["type": "string"]],
                "required": ["headline_id", "sub_id", "body_id", "why", "layout", "image_prompt"], "additionalProperties": false,
            ]],
        ],
        "required": ["copy", "results", "pairs"], "additionalProperties": false,
    ]
    struct SearchReply: Codable {
        struct R: Codable { var id: String; var score: Int; var why: String; var palette: String? }
        struct P: Codable { var headline_id: String; var sub_id: String; var body_id: String; var why: String; var layout: String?; var image_prompt: String? }
        var copy: ScoutCopy?
        var results: [R]
        var pairs: [P]?
    }
    static func search(key: String, catalog: String, brief: String, taste: String = "") async throws -> (SearchReply, ScoutUsage) {
        let user: [[String: Any]] = [["type": "text", "text": "BRIEF: " + brief + (taste.isEmpty ? "" : "\n\n" + taste)]]
        let (text, u) = try await chat(key: key, system: searchSystemHead + "\n" + catalog, user: user, schemaName: "scout_results", schema: searchSchema, maxTokens: 6000, effort: "low")
        let r = try JSONDecoder().decode(SearchReply.self, from: Data(text.utf8))
        return (r, u)
    }

    // 아트디렉터 2차 심사 — 1차 후보를 실제 카피로 렌더한 이미지와 함께 다시 보고 가독성·완성도·시대감으로 재심사, 방향 2~3개 제안
    static let directSystem = """
    You are a senior art director reviewing font candidates for a designer's brief. You see the brief, the sample copy the piece will carry, and for each candidate font an image of the actual headline line and price (or sub) line set in that font. You also get a short list of neutral text fonts available for supporting roles.
    Judge like a working designer, not a keyword matcher:
    - Legibility outranks personality for anything read at a glance: product names, prices, numbers, conditions. Digits must be unambiguous ($ 9 6 0 % /). If a face is decorative, or so heavy that counters close up, it may serve only as a headline — and only if the headline still reads instantly; otherwise mark it avoid.
    - Heavy is fine; decorative is the problem. Rough, textured, brush or marker display faces are welcome for headlines when the brief is casual or retail. Avoid faces that read as 2000s free-font clichés unless the brief asks for retro.
    - Prefer Hangul with good craft (even stroke rhythm, balanced spacing, consistent weight). Check the Latin and digits in the sample too.
    - A piece needs contrast between roles: one expressive headline face + one clean heavy face for the price and numbers + one neutral text face for sub and body. Never set the price in the same decorative face as the headline unless its digits are clearly readable.
    - Propose 2 or 3 distinct DIRECTIONS a designer would actually present (e.g. rough & warm / clean & bold / premium & quiet): name (2–4 words, in the brief's language), mood (3 words), palette (from the given list), layout (from the given list), the four role fonts headline_id / price_id / sub_id / body_id (supporting roles may come from the neutral list; ids exactly as written), image_prompt (English, ≤40 words, background photo or illustration with empty space for text, no letters), and why (≤20 words, brief's language).
    - Re-rank the candidates: score 0–100 for this brief, legibility 1–5 for text set at a glance, role_fit (headline | price | sub | body | avoid), a one-line note (≤16 words, brief's language) a designer would respect, e.g. "counters close at small sizes" or "digits read from across the aisle", and direction = the 1-based index of the direction this font belongs with best (0 if none).
    - If a DESIGNER'S TASTE section is present, treat it as a strong signal: never pick disliked fonts for any role, avoid fonts that share their qualities, and lean toward the qualities of liked fonts when the brief allows.
    Palettes: paper, ink-cream, navy-gold, kraft, blush, forest, neon-dark, sky, mustard, terracotta, lavender, mint, sale-red, yellow-black, cream-red. Layouts: overlay, split, band, badge, frame, poster.
    """
    static let directSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "directions": ["type": "array", "maxItems": 3, "items": [
                "type": "object",
                "properties": ["name": ["type": "string"], "mood": ["type": "string"], "palette": ["type": "string"], "layout": ["type": "string"],
                               "headline_id": ["type": "string"], "price_id": ["type": "string"], "sub_id": ["type": "string"], "body_id": ["type": "string"],
                               "image_prompt": ["type": "string"], "why": ["type": "string"]],
                "required": ["name", "mood", "palette", "layout", "headline_id", "price_id", "sub_id", "body_id", "image_prompt", "why"], "additionalProperties": false,
            ]],
            "ranking": ["type": "array", "maxItems": 12, "items": [
                "type": "object",
                "properties": ["id": ["type": "string"], "score": ["type": "integer"], "legibility": ["type": "integer"], "role_fit": ["type": "string"], "note": ["type": "string"], "direction": ["type": "integer"]],
                "required": ["id", "score", "legibility", "role_fit", "note", "direction"], "additionalProperties": false,
            ]],
        ],
        "required": ["directions", "ranking"], "additionalProperties": false,
    ]
    struct DirectReply: Codable {
        struct D: Codable { var name: String; var mood: String; var palette: String; var layout: String; var headline_id: String; var price_id: String; var sub_id: String; var body_id: String; var image_prompt: String; var why: String }
        struct R: Codable { var id: String; var score: Int; var legibility: Int; var role_fit: String; var note: String; var direction: Int? }
        var directions: [D]; var ranking: [R]
    }
    static func direct(key: String, brief: String, copyLines: [String], neutral: String, taste: String, candidates: [(id: String, name: String, jpeg: Data)]) async throws -> (DirectReply, ScoutUsage) {
        var user: [[String: Any]] = [["type": "text", "text": "BRIEF: \(brief)\nSAMPLE COPY (top to bottom): \(copyLines.joined(separator: " / "))\nNEUTRAL TEXT FONTS available for price/sub/body (id | name):\n\(neutral)" + (taste.isEmpty ? "" : "\n\n" + taste) + "\nCANDIDATES — each image shows the headline line and the price/sub line set in that font; the id and name precede each image."]]
        for c in candidates {
            user.append(["type": "text", "text": "\(c.id) | \(c.name)"])
            user.append(["type": "image_url", "image_url": ["url": dataURL(c.jpeg)]])
        }
        let (text, u) = try await chat(key: key, system: directSystem, user: user, schemaName: "art_direction", schema: directSchema, maxTokens: 6000, effort: "low")
        let r = try JSONDecoder().decode(DirectReply.self, from: Data(text.utf8))
        return (r, u)
    }

    // Muse Image — 조합 카드 배경 (단발 생성, 장당 $0.01). 검색 도구는 끈다(속도).
    static let imageEndpoint = URL(string: "https://api.meta.ai/v1/images/generations")!
    static let imageModel = "muse-image-1.0"
    static let layouts = ["overlay", "split", "band", "badge", "frame", "poster"]
    static func image(key: String, prompt: String) async throws -> NSImage {
        let body: [String: Any] = [
            "model": imageModel, "n": 1, "size": "1536x1024", "output_format": "jpeg", "reasoning_strength": "low",
            "prompt": prompt + " No text, no letters, no typography, no logos, no watermark, no human faces.",
            "tool_enablement": ["enable_web_search": false, "enable_image_search": false, "enable_shell": false],
        ]
        var req = URLRequest(url: imageEndpoint); req.httpMethod = "POST"; req.timeoutInterval = 240
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Err(msg: "image HTTP \(code) " + String((String(data: data, encoding: .utf8) ?? "").prefix(200))) }
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any], let arr = j["data"] as? [[String: Any]],
              let b64 = arr.first?["b64_json"] as? String, let d = Data(base64Encoded: b64), let img = NSImage(data: d) else { throw Err(msg: "image: unexpected response") }
        return img
    }

    // 사진 → 브리프
    static let describeSystem = """
    You are Typeface Scout, a senior typographer. You look at a photo that contains lettering — a shop sign, a poster, a package, a book cover, handwriting — and write the brief a designer would type to find a similar typeface in their own font library.
    Rules: describe only the lettering, not the scene. Be concrete and discriminating: structure (serif / sans / script / brush / rounded / slab / blackletter…), weight and stroke contrast, letter width, shapes of counters and terminals, mood words, the era it evokes, what it would suit. Never guess a font name. If the photo has no legible lettering, say so in `notes` and still turn the overall visual mood into a brief.
    - brief: 1 to 3 sentences, at most 60 words, in the requested language. This text will be used as a search query, so put the structural words first.
    - scripts: which scripts the lettering uses, from "Latin" and "Korean" (may be both, may be empty).
    - notes: one short sentence for the designer on what you saw (e.g. "neon sign, condensed uppercase"); may be empty.
    """
    static let describeSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "brief": ["type": "string"],
            "scripts": ["type": "array", "items": ["type": "string"], "maxItems": 2],
            "notes": ["type": "string"],
        ],
        "required": ["brief", "scripts", "notes"], "additionalProperties": false,
    ]
    private struct DescribeReply: Codable { var brief: String; var scripts: [String]; var notes: String }
    static func describe(key: String, jpeg: Data, language: String) async throws -> (brief: String, scripts: [String], notes: String, usage: ScoutUsage) {
        let user: [[String: Any]] = [
            ["type": "text", "text": "Write the font brief for the lettering in this photo. Language of the brief: \(language). Return JSON only."],
            ["type": "image_url", "image_url": ["url": dataURL(jpeg)]],
        ]
        let (text, u) = try await chat(key: key, system: describeSystem, user: user, schemaName: "photo_brief", schema: describeSchema, maxTokens: 1600, effort: "low")
        let r = try JSONDecoder().decode(DescribeReply.self, from: Data(text.utf8))
        return (r.brief, r.scripts, r.notes, u)
    }
}

// MARK: - 상태

@MainActor
final class ScoutStore: ObservableObject {
    static let shared = ScoutStore()
    static let FILE = CONF_DIR.appendingPathComponent("scout_tags_v1.json")

    @Published private(set) var tags: [String: ScoutTag] = [:]
    @Published private(set) var prefs: [String: Int] = [:]    // 👍 1 · 👎 -1, 패밀리 대표 id
    @Published private(set) var catalogFonts: [String: FontItem] = [:]   // 눈누(미설치) woff → 내려받아 디코드한 가상 FontItem (id "nn:…")
    @Published var brief = ""
    @Published private(set) var results: [ScoutResult] = []
    @Published private(set) var copy = ScoutCopy()           // 보드 타일 샘플 카피
    @Published private(set) var pairs: [ScoutPair] = []      // 조합 제안
    @Published var board = true                              // 결과 보기: 보드 / 목록
    @Published var imagesOn = true { didSet { if imagesOn { fetchPairImages() } } }   // 조합 카드 배경을 Muse Image 로
    @Published private(set) var pairImages: [String: NSImage] = [:]   // pair.id → 배경
    @Published private(set) var pairImageBusy: Set<String> = []
    private var imageGeneration = 0
    @Published private(set) var searching = false
    @Published private(set) var tagging = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var usage = ScoutUsage()        // 누적(파일에 저장)
    @Published private(set) var sessionUsage = ScoutUsage() // 이번 실행
    @Published private(set) var status = ""
    @Published private(set) var lastMode = ""               // "ai" / "local"
    @Published private(set) var hasKey = ScoutKey.load() != nil
    @Published var showKeySheet = false
    @Published private(set) var photo: NSImage? = nil        // 사진으로 찾기 — 현재 사진
    @Published private(set) var photoNote = ""               // Muse Spark 가 본 것 한 줄
    @Published private(set) var describing = false
    private var tagTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    private init() {
        if let d = try? Data(contentsOf: ScoutStore.FILE), let c = try? JSONDecoder().decode(ScoutCache.self, from: d) { tags = c.tags; usage = c.usage; prefs = c.prefs ?? [:] }
    }

    // 키
    func setKey(_ k: String) { ScoutKey.save(k); hasKey = ScoutKey.load() != nil }
    var keyHint: String { hasKey ? T("API 키 저장됨", "API key saved") : T("API 키 없음", "No API key") }

    // ── 눈누(미설치) 폰트 — woff/otf/ttf 만 (CoreText 로 그릴 수 있는 것). woff2 는 추천 탭 미리보기(웹뷰)만.
    func catalogCandidates() -> [CatalogItem] {
        let s = Store.shared
        return s.catalog.filter { $0.source == "noonnu" && $0.webfont != nil && !$0.isWoff2 && !s.isInstalled($0) }
    }
    var catalogTaggedCount: Int { catalogCandidates().filter { tags[$0.id] != nil }.count }
    func catalogItem(id: String) -> CatalogItem? { Store.shared.catalog.first { $0.id == id } }
    /// 설치 폰트 또는 눈누 가상 폰트
    func font(id: String) -> FontItem? { Store.shared.item(id: id) ?? catalogFonts[id] }
    /// 눈누 woff 를 받아 디코드해 FontItem 으로 (캐시 파일 = PreviewLoader 와 공유)
    func ensureCatalogFont(_ c: CatalogItem) async -> FontItem? {
        if let f = catalogFonts[c.id] { return f }
        guard let cg = try? await PreviewLoader.font(for: c, text: ""), let ct = Optional(CTFontCreateWithGraphicsFont(cg, 12, nil, nil)) else { return nil }
        let desc = CTFontCopyFontDescriptor(ct)
        let item = FontItem(id: c.id, ps: c.webFamily ?? c.nameEN, family: c.name, familyEN: c.nameEN, style: "Regular", full: c.name,
                            path: c.webfont ?? "", file: ((c.webfont ?? "") as NSString).lastPathComponent, source: .folder, mtime: 0, folderID: nil, descriptor: desc)
        catalogFonts[c.id] = item
        return item
    }
    /// 눈누 후보를 썸네일(이름을 그 폰트로 그린 PNG)로 태깅 — 폰트 파일을 안 받아 빠르고 싸다 (개당 ≈$0.004)
    func tagCatalog(limit: Int? = nil) {
        guard !tagging else { return }
        guard let key = ScoutKey.load() else { status = T("먼저 API 키를 넣어 주세요", "Add your API key first"); showKeySheet = true; return }
        var items = catalogCandidates().filter { tags[$0.id] == nil && $0.thumb != nil }
        if let l = limit { items = Array(items.prefix(l)) }
        guard !items.isEmpty else { status = T("태깅할 눈누 폰트가 없어요", "No Noonnu fonts left to tag"); return }
        tagging = true; done = 0; total = items.count
        status = T("눈누 태깅 중 0/\(items.count)", "Tagging Noonnu 0/\(items.count)")
        tagTask = Task.detached(priority: .userInitiated) { [weak self] in
            await withTaskGroup(of: (String, ScoutTag?, ScoutUsage, String?).self) { group in
                var it = items.makeIterator(); var running = 0
                func launch(_ c: CatalogItem) {
                    group.addTask {
                        if Task.isCancelled { return (c.id, nil, ScoutUsage(), "cancelled") }
                        guard let t = c.thumb, let u = URL(string: t), let png = try? await Installer.fetch(u), let jpeg = ScoutPhoto.thumbJPEG(png) else { return (c.id, nil, ScoutUsage(), "thumb failed") }
                        do { let (tag, usage) = try await ScoutAPI.tag(key: key, jpeg: jpeg, korean: true, thumbnail: true); return (c.id, tag, usage, nil) }
                        catch { return (c.id, nil, ScoutUsage(), error.localizedDescription) }
                    }
                }
                while running < 4, let c = it.next() { launch(c); running += 1 }
                var failures = 0
                while let (id, tag, u, err) = await group.next() {
                    running -= 1
                    if err != nil { failures += 1 }
                    let fail = failures
                    await MainActor.run { self?.absorb(id: id, tag: tag, usage: u, err: err, failures: fail) }
                    if Task.isCancelled { break }
                    if let c = it.next() { launch(c); running += 1 }
                }
            }
            await MainActor.run { self?.finishTagging() }
        }
    }

    // 대상 = 설치 폰트의 패밀리 대표, 불러오기 실패 제외
    func targets() -> [FontItem] {
        let s = Store.shared
        return s.representatives(installedOnly: true).filter { s.profiles[$0.id]?.err != 1 }
    }
    var taggedCount: Int { let ids = Set(targets().map { $0.id }); return tags.keys.filter { ids.contains($0) }.count }
    func tag(for item: FontItem) -> ScoutTag? { tags[item.id] ?? tags[Store.shared.representative(of: item)?.id ?? ""] }
    /// 이 폰트에 한글이 있나 (태그 → 프로필 순)
    func hasKorean(_ item: FontItem) -> Bool { tag(for: item)?.korean ?? (Store.shared.profiles[item.id]?.isKo ?? false) }

    // 태깅
    func tagAll(onlyMissing: Bool = true) {
        guard !tagging else { return }
        guard let key = ScoutKey.load() else { status = T("먼저 API 키를 넣어 주세요", "Add your API key first"); showKeySheet = true; return }
        let profiles = Store.shared.profiles
        let items = targets().filter { !onlyMissing || tags[$0.id] == nil }
        guard !items.isEmpty else { status = T("태깅할 폰트가 없어요", "Nothing to tag"); return }
        tagging = true; done = 0; total = items.count
        status = T("태깅 중 0/\(items.count)", "Tagging 0/\(items.count)")
        let koFlags = Dictionary(uniqueKeysWithValues: items.map { ($0.id, profiles[$0.id]?.isKo ?? false) })
        tagTask = Task.detached(priority: .userInitiated) { [weak self] in
            await withTaskGroup(of: (String, ScoutTag?, ScoutUsage, String?).self) { group in
                var it = items.makeIterator()
                var running = 0
                func launch(_ f: FontItem) {
                    group.addTask {
                        if Task.isCancelled { return (f.id, nil, ScoutUsage(), "cancelled") }
                        guard let jpeg = ScoutRender.jpeg(f, korean: koFlags[f.id] ?? false) else { return (f.id, nil, ScoutUsage(), "render failed") }
                        do { let (t, u) = try await ScoutAPI.tag(key: key, jpeg: jpeg, korean: koFlags[f.id] ?? false); return (f.id, t, u, nil) }
                        catch { return (f.id, nil, ScoutUsage(), error.localizedDescription) }
                    }
                }
                while running < 4, let f = it.next() { launch(f); running += 1 }
                var failures = 0
                while let (id, tag, u, err) = await group.next() {
                    running -= 1
                    if err != nil { failures += 1 }
                    let fail = failures
                    await MainActor.run { self?.absorb(id: id, tag: tag, usage: u, err: err, failures: fail) }
                    if Task.isCancelled { break }
                    if let f = it.next() { launch(f); running += 1 }
                }
            }
            await MainActor.run { self?.finishTagging() }
        }
    }
    func cancelTagging() { tagTask?.cancel() }
    private func absorb(id: String, tag: ScoutTag?, usage u: ScoutUsage, err: String?, failures: Int) {
        if let t = tag { tags[id] = t }
        usage.add(u); sessionUsage.add(u)
        done += 1
        status = T("태깅 중 \(done)/\(total)", "Tagging \(done)/\(total)") + (failures > 0 ? T(" · 실패 \(failures)", " · \(failures) failed") : "") + (err != nil && failures <= 3 ? " · " + (err ?? "") : "")
        if done % 10 == 0 { saveSoon() }
    }
    private func finishTagging() {
        tagging = false
        status = T("태깅 완료 \(taggedCount)/\(targets().count) 패밀리 · 이번 \(fmtUSD(sessionUsage.usd))", "Tagged \(taggedCount)/\(targets().count) families · this run \(fmtUSD(sessionUsage.usd))")
        saveNow()
    }

    // 검색
    func search() {
        let b = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty, !searching else { return }
        let s = Store.shared
        let reps = targets().filter { tags[$0.id] != nil }.sorted { $0.id < $1.id }
        guard !reps.isEmpty else { status = T("먼저 「내 폰트 태깅」을 눌러 주세요", "Run “Tag my fonts” first"); return }
        guard let key = ScoutKey.load() else { localSearch(b, reps); return }
        searching = true; status = T("Muse Spark 에게 묻는 중…", "Asking Muse Spark…")
        var lines = reps.map { f in tags[f.id]!.line(id: f.id, name: f.family == f.familyEN ? f.family : "\(f.family) (\(f.familyEN))") }
        for c in catalogCandidates() where tags[c.id] != nil { lines.append(tags[c.id]!.line(id: c.id, name: c.name + " — NOT INSTALLED (Noonnu, free)")) }
        let catalog = lines.sorted().joined(separator: "\n")
        Task {
            do {
                let (reply, u) = try await ScoutAPI.search(key: key, catalog: catalog, brief: b, taste: tasteText())
                usage.add(u); sessionUsage.add(u)
                // 눈누 미설치 폰트가 뽑혔으면 woff 를 받아 가상 FontItem 을 만든다 (결과·조합에 쓰인 id 전부)
                var nnIDs = Set(reply.results.map { $0.id }.filter { $0.hasPrefix("nn:") })
                for pr in reply.pairs ?? [] { for id in [pr.headline_id, pr.sub_id, pr.body_id] where id.hasPrefix("nn:") { nnIDs.insert(id) } }
                if !nnIDs.isEmpty { status = T("눈누 폰트 \(nnIDs.count)개 받는 중…", "Fetching \(nnIDs.count) Noonnu fonts…") }
                for id in nnIDs { if let c = catalogItem(id: id) { _ = await ensureCatalogFont(c) } }
                var seen = Set<String>()
                results = reply.results.compactMap { r in
                    guard seen.insert(r.id).inserted, let f = font(id: r.id), pref(f) >= 0 else { return nil }   // 👎 는 결과에서 제외
                    return ScoutResult(item: f, score: r.score, why: r.why, palette: ScoutPalette.table[r.palette ?? ""] != nil ? r.palette! : "paper")
                }
                copy = (reply.copy?.isEmpty ?? true) ? ScoutCopy.fallback(b) : reply.copy!
                if !copy.lines.contains(where: { $0.size == "xl" || $0.size == "l" }), !copy.lines.isEmpty { copy.lines[0].size = "l" }
                let byID = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
                var seenPair = Set<String>()
                pairs = (reply.pairs ?? []).compactMap { pr in
                    guard let h = font(id: pr.headline_id), let sb = font(id: pr.sub_id), let bd = font(id: pr.body_id) else { return nil }
                    var pair = ScoutPair(headline: h, sub: sb, body: bd, why: pr.why, palette: byID[h.id]?.palette ?? "paper")
                    pair.layout = ScoutAPI.layouts.contains(pr.layout ?? "") ? pr.layout! : ScoutAPI.layouts[seenPair.count % ScoutAPI.layouts.count]
                    pair.imagePrompt = pr.image_prompt ?? ""
                    return seenPair.insert(pair.id).inserted ? pair : nil
                }
                pairImages = [:]; pairImageBusy = []; imageGeneration += 1
                lastMode = "ai"
                // 2차: 아트디렉터가 후보를 실제 카피로 보고 재심사 + 방향 제안 (실패하면 1차 결과 그대로)
                var u2 = ScoutUsage()
                if !results.isEmpty {
                    status = T("아트디렉터가 후보 \(results.count)개를 보는 중…", "Art director is reviewing \(results.count) candidates…")
                    do { u2 = try await artDirect(key: key, brief: b) } catch { status = T("2차 심사 실패(1차 결과 표시): ", "Review failed (showing first pass): ") + error.localizedDescription }
                }
                fetchPairImages()
                let tot = u.usd + u2.usd
                if results.isEmpty { status = T("맞는 폰트를 못 찾았어요 — 브리프를 조금 바꿔 보세요", "No match — try rephrasing the brief") }
                else if !status.hasPrefix(T("2차 심사 실패", "Review failed")) {
                    status = T("\(results.count)개 · 방향 \(pairs.count)개 · 검색+심사 \(fmtUSD(tot))", "\(results.count) picks · \(pairs.count) directions · search + review \(fmtUSD(tot))")
                }
                saveSoon()
            } catch {
                status = T("검색 실패: ", "Search failed: ") + error.localizedDescription
                localSearch(b, reps)
            }
            searching = false
        }
    }
    // 사진 → 브리프 → 검색
    func findFromPhoto(_ image: NSImage) {
        guard !describing, !searching else { return }
        guard let key = ScoutKey.load() else { status = T("사진으로 찾으려면 API 키가 필요해요", "Finding from a photo needs an API key"); showKeySheet = true; return }
        guard let jpeg = ScoutPhoto.jpeg(image) else { status = T("이미지를 읽지 못했어요", "Couldn't read that image"); return }
        photo = image; photoNote = ""; describing = true
        status = T("Muse Spark 가 사진 속 글자를 보는 중…", "Muse Spark is looking at the lettering…")
        let language = UILang.current == .ko ? "Korean" : "English"
        Task {
            do {
                let r = try await ScoutAPI.describe(key: key, jpeg: jpeg, language: language)
                usage.add(r.usage); sessionUsage.add(r.usage)
                var b = r.brief.trimmingCharacters(in: .whitespacesAndNewlines)
                let ko = r.scripts.contains { $0.lowercased().hasPrefix("kor") }
                if ko, !b.contains("한글"), !b.lowercased().contains("korean"), !b.lowercased().contains("hangul") { b += T(" 한글 필요.", " Needs Korean.") }
                brief = b; photoNote = r.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                describing = false
                search()
            } catch {
                describing = false
                status = T("사진 읽기 실패: ", "Couldn't read the photo: ") + error.localizedDescription
            }
        }
    }
    func clearPhoto() { photo = nil; photoNote = "" }
    /// 클립보드의 이미지(또는 이미지 파일 경로)로 찾기 — 웹에서 간판 사진을 복사해 바로 붙여넣는 경로
    func pasteImage() {
        let pb = NSPasteboard.general
        if let img = NSImage(pasteboard: pb) { findFromPhoto(img); return }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let u = urls.first, let img = NSImage(contentsOf: u) { findFromPhoto(img); return }
        status = T("클립보드에 이미지가 없어요 — 사진을 복사한 뒤 다시 눌러 주세요", "No image on the clipboard — copy a photo first")
    }
    func openPhotoPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]; p.allowsMultipleSelection = false; p.canChooseDirectories = false
        p.message = T("글자가 보이는 사진을 고르세요 — 간판·포스터·패키지·책 표지", "Pick a photo with lettering — a sign, poster, package, book cover")
        if p.runModal() == .OK, let u = p.url, let img = NSImage(contentsOf: u) { findFromPhoto(img) }
        else if p.url != nil { status = T("이미지를 읽지 못했어요", "Couldn't read that image") }
    }
    /// 드롭된 항목(파일 URL 또는 이미지)을 사진으로 받는다
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || $0.canLoadObject(ofClass: NSImage.self) }) else { return false }
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL? = nil
                if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) } else if let u = item as? URL { url = u }
                guard let u = url, let img = NSImage(contentsOf: u) else { Task { @MainActor in self.status = T("이미지 파일이 아니에요", "That's not an image file") }; return }
                Task { @MainActor in self.findFromPhoto(img) }
            }
            return true
        }
        p.loadObject(ofClass: NSImage.self) { obj, _ in if let img = obj as? NSImage { Task { @MainActor in self.findFromPhoto(img) } } }
        return true
    }

    /// 결과 미리보기 문구 — 한글 폰트인데 샘플에 한글이 없으면(영문 샘플만 쳤을 때) 한글 기본 문구를 앞에 붙인다
    func previewText(_ item: FontItem, korean: Bool) -> String {
        let s = Store.shared
        let base = s.sample.isEmpty ? item.full : s.sample
        guard korean else { return s.latinOnly(base, strip: true) }
        let hasHangul = base.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
        return hasHangul ? base : "다람쥐 헌 쳇바퀴에 타고파  " + base
    }

    /// 아트디렉터 2차 심사: 후보 12개를 실제 카피로 렌더해 보여주고 재순위·가독성·방향 2~3개를 받는다
    private func artDirect(key: String, brief: String) async throws -> ScoutUsage {
        let s = Store.shared
        let cands = results
        let cp = copy
        // 그릴 줄: 제목(xl/l, price 아닌 것) + 가격(role price) 또는 부제
        func linesFor(_ item: FontItem) -> [String] {
            let ko = hasKorean(item)
            let head = cp.lines.first { ($0.size == "xl" || $0.size == "l") && $0.role != "price" } ?? cp.lines.first
            let second = cp.lines.first { $0.role == "price" } ?? cp.lines.first { $0.size == "m" } ?? cp.lines.dropFirst().first
            return [head, second].compactMap { $0?.text(korean: ko) }
        }
        let needKo = cp.lines.contains { ScoutCopy.hasHangul($0.text) }
        let neutral = targets().filter { f in
            guard let t = tags[f.id] else { return false }
            let sans = t.style.contains { $0.contains("sans") || $0 == "rounded" }
            let text = t.bestUse.contains { $0.contains("body") || $0.contains("ui") || $0.contains("headline") }
            return sans && text && (!needKo || t.korean)
        }.prefix(40).map { "\($0.id) | \($0.family)" }.joined(separator: "\n")
        let jobs: [(FontItem, [String])] = cands.map { ($0.item, linesFor($0.item)) }   // 메인에서 미리 계산 (detached 안에서 actor 호출 금지)
        let rendered: [(id: String, name: String, jpeg: Data)] = await Task.detached(priority: .userInitiated) {
            jobs.compactMap { (item, lines) in ScoutRender.copyCard(item, lines: lines).map { (item.id, item.family, $0) } }
        }.value
        guard !rendered.isEmpty else { return ScoutUsage() }
        let (reply, u) = try await ScoutAPI.direct(key: key, brief: brief, copyLines: cp.lines.map { $0.text }, neutral: neutral, taste: tasteText(), candidates: rendered)
        usage.add(u); sessionUsage.add(u)
        // 재순위
        var byID = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        var ordered: [ScoutResult] = []
        for r in reply.ranking {
            guard var res = byID.removeValue(forKey: r.id) else { continue }
            res.score = max(0, min(100, r.score)); res.legibility = max(0, min(5, r.legibility)); res.roleFit = r.role_fit.lowercased()
            if !r.note.trimmingCharacters(in: .whitespaces).isEmpty { res.note = r.note }
            res.direction = r.direction ?? 0
            ordered.append(res)
        }
        ordered.sort { ($0.roleFit == "avoid" ? 0 : 1, $0.score) > ($1.roleFit == "avoid" ? 0 : 1, $1.score) }
        results = ordered + results.filter { byID[$0.id] != nil }
        // 방향 → 조합 카드
        for d in reply.directions { for id in [d.headline_id, d.price_id, d.sub_id, d.body_id] where id.hasPrefix("nn:") && catalogFonts[id] == nil { if let c = catalogItem(id: id) { _ = await ensureCatalogFont(c) } } }
        var seen = Set<String>()
        let dirs: [ScoutPair] = reply.directions.compactMap { d in
            guard let h = font(id: d.headline_id), let pr = font(id: d.price_id), let sb = font(id: d.sub_id), let bd = font(id: d.body_id) else { return nil }
            var pair = ScoutPair(headline: h, sub: sb, body: bd, price: pr, why: d.why, palette: ScoutPalette.table[d.palette] != nil ? d.palette : (byID[h.id]?.palette ?? results.first?.palette ?? "paper"))
            pair.layout = ScoutAPI.layouts.contains(d.layout) ? d.layout : ScoutAPI.layouts[seen.count % ScoutAPI.layouts.count]
            pair.imagePrompt = d.image_prompt; pair.name = d.name; pair.mood = d.mood
            return seen.insert(pair.id).inserted ? pair : nil
        }
        if !dirs.isEmpty { pairs = dirs }
        results = results.map { var r = $0; if r.direction > dirs.count { r.direction = 0 }; return r }
        return u
    }

    /// 조합 카드 배경 이미지 — 쌍마다 Muse Image 1장(병렬), 도착하는 대로 표시
    func fetchPairImages() {
        guard imagesOn, let key = ScoutKey.load() else { return }
        let gen = imageGeneration
        for pr in pairs where !pr.imagePrompt.isEmpty && pairImages[pr.id] == nil && !pairImageBusy.contains(pr.id) {
            pairImageBusy.insert(pr.id)
            Task { [weak self] in
                do {
                    let img = try await ScoutAPI.image(key: key, prompt: pr.imagePrompt)
                    guard let self, self.imageGeneration == gen else { return }
                    self.pairImages[pr.id] = img
                    var u = ScoutUsage(); u.images = 1; self.usage.add(u); self.sessionUsage.add(u); self.saveSoon()
                } catch {
                    guard let self, self.imageGeneration == gen else { return }
                    self.status = T("배경 이미지 실패: ", "Background image failed: ") + error.localizedDescription
                }
                self?.pairImageBusy.remove(pr.id)
            }
        }
    }

    /// 키가 없거나 호출이 실패했을 때: 태그 키워드 겹침으로 대충 고른다
    private func localSearch(_ brief: String, _ reps: [FontItem]) {
        let words = Set(brief.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
        var scored: [(FontItem, Int)] = []
        for f in reps { let hay = tags[f.id]!.haystack; let n = words.filter { hay.contains($0) }.count; if n > 0 { scored.append((f, n)) } }
        scored.sort { $0.1 > $1.1 }
        results = scored.prefix(12).enumerated().map { (i, e) in ScoutResult(item: e.0, score: min(100, e.1 * 25), why: T("키워드 \(e.1)개 일치 (로컬)", "\(e.1) keyword matches (local)"), palette: ScoutPalette.names[i % ScoutPalette.names.count]) }
        copy = ScoutCopy.fallback(brief)
        pairs = []; pairImages = [:]; pairImageBusy = []
        lastMode = "local"
        if status.isEmpty || !status.hasPrefix(T("검색 실패", "Search failed")) { status = T("API 키 없이 로컬 키워드 매칭으로 \(results.count)개", "\(results.count) by local keyword match (no API key)") }
    }

    // 저장
    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in try? await Task.sleep(nanoseconds: 500_000_000); guard !Task.isCancelled else { return }; self?.saveNow() }
    }
    func saveNow() {
        try? FileManager.default.createDirectory(at: CONF_DIR, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        if let d = try? enc.encode(ScoutCache(tags: tags, usage: usage, prefs: prefs)) { try? d.write(to: ScoutStore.FILE, options: .atomic) }
    }
    func clearTags() { tags = [:]; results = []; saveNow(); status = T("태그를 지웠어요", "Tags cleared") }

    // 👍/👎 — 패밀리 대표 id 로 저장, 같은 걸 다시 누르면 해제
    private func prefKey(_ item: FontItem) -> String { Store.shared.representative(of: item)?.id ?? item.id }
    func pref(_ item: FontItem) -> Int { prefs[prefKey(item)] ?? 0 }
    func setPref(_ item: FontItem, _ v: Int) {
        let k = prefKey(item)
        if prefs[k] == v { prefs[k] = nil } else { prefs[k] = v }
        saveSoon()
        let likes = prefs.values.filter { $0 > 0 }.count, dislikes = prefs.values.filter { $0 < 0 }.count
        status = v > 0 && prefs[k] != nil ? T("👍 기억했어요 — 다음 검색부터 이 결의 폰트를 더 봐요 (👍\(likes) · 👎\(dislikes))", "👍 Noted — future searches lean this way (👍\(likes) · 👎\(dislikes))")
            : v < 0 && prefs[k] != nil ? T("👎 기억했어요 — 다음 검색부터 이 폰트는 빼고, 비슷한 결도 피해요 (👍\(likes) · 👎\(dislikes))", "👎 Noted — excluded from future searches, and similar looks avoided (👍\(likes) · 👎\(dislikes))")
            : T("표시를 지웠어요", "Mark cleared")
    }
    func clearPrefs() { prefs = [:]; saveNow(); status = T("👍/👎 기록을 지웠어요", "Thumbs cleared") }
    var likeCount: Int { prefs.values.filter { $0 > 0 }.count }
    var dislikeCount: Int { prefs.values.filter { $0 < 0 }.count }
    /// 프롬프트용 취향 섹션 — 좋아한/거른 폰트를 태그 요약과 함께 (모델이 «결»을 일반화하게)
    func tasteText() -> String {
        let s = Store.shared
        func lines(_ v: Int) -> [String] {
            prefs.filter { $0.value == v }.keys.sorted().prefix(30).compactMap { id in
                guard let f = font(id: id) ?? catalogItem(id: id).map({ c in FontItem(id: c.id, ps: c.nameEN, family: c.name, familyEN: c.nameEN, style: "", full: c.name, path: "", file: "", source: .folder, mtime: 0, folderID: nil, descriptor: CTFontDescriptorCreateWithAttributes([:] as CFDictionary)) }) else { return nil }
                let t = tags[id].map { " | " + $0.summary } ?? ""
                return "\(id) | \(f.family)\(t)"
            }
        }
        let likes = lines(1), dislikes = lines(-1)
        if likes.isEmpty && dislikes.isEmpty { return "" }
        var out = "DESIGNER'S TASTE (from thumbs up/down on earlier results):"
        if !likes.isEmpty { out += "\nLIKED:\n" + likes.joined(separator: "\n") }
        if !dislikes.isEmpty { out += "\nDISLIKED (never pick, and avoid similar looks):\n" + dislikes.joined(separator: "\n") }
        return out
    }

    func fmtUSD(_ v: Double) -> String { v < 0.01 ? String(format: "$%.4f", v) : String(format: "$%.2f", v) }
}

// MARK: - 화면

struct ScoutView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var scout = ScoutStore.shared
    @FocusState private var briefFocused: Bool
    @State private var dropping = false
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if let img = scout.photo {
                        ZStack(alignment: .topTrailing) {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                            Button { scout.clearPhoto() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.white, .black.opacity(0.6)) }
                                .buttonStyle(.plain).offset(x: 5, y: -5).help(T("사진 지우기", "Remove photo"))
                        }.help(scout.photoNote.isEmpty ? T("이 사진의 글자로 브리프를 썼어요", "Brief written from this photo") : scout.photoNote)
                    }
                    TextField(T("브리프 — 예: 베이커리 로고용 따뜻한 손글씨, 한글·영문 둘 다", "Brief — e.g. warm hand-lettered font for a bakery logo, Korean + English"), text: $scout.brief)
                        .textFieldStyle(.roundedBorder).font(.system(size: 15)).controlSize(.large).focused($briefFocused)
                        .onSubmit { scout.search() }
                    Button(action: { scout.search() }) {
                        if scout.searching { ProgressView().controlSize(.small).frame(width: 52) } else { Text(T("찾기", "Find")).frame(width: 52) }
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(scout.searching || scout.describing || scout.brief.trimmingCharacters(in: .whitespaces).isEmpty)
                    Menu {
                        Button(T("사진 고르기…", "Choose a photo…")) { scout.openPhotoPanel() }
                        Button(T("클립보드 이미지 붙여넣기", "Paste image from clipboard")) { scout.pasteImage() }
                    } label: {
                        if scout.describing { ProgressView().controlSize(.small).frame(width: 22) } else { Image(systemName: "photo.badge.magnifyingglass").frame(width: 22) }
                    }.menuStyle(.borderedButton).menuIndicator(.hidden).fixedSize().controlSize(.large).disabled(scout.describing || scout.searching)
                        .help(T("사진으로 찾기 — 간판·포스터 사진을 고르거나 여기로 끌어다 놓으면 Muse Spark 가 글자를 보고 브리프를 써서 바로 찾아요", "Find from a photo — pick or drop a sign/poster photo; Muse Spark describes the lettering as a brief and searches"))
                }
                HStack(spacing: 10) {
                    let tagged = scout.taggedCount, all = scout.targets().count
                    Text(T("태깅된 패밀리 \(tagged.formatted())/\(all.formatted())", "\(tagged.formatted())/\(all.formatted()) families tagged")).font(.system(size: 12)).foregroundColor(.secondary)
                    if scout.tagging {
                        ProgressView(value: Double(scout.done), total: Double(max(1, scout.total))).frame(width: 140)
                        Button(T("중지", "Stop")) { scout.cancelTagging() }.controlSize(.small)
                    } else {
                        Button(tagged == 0 ? T("내 폰트 태깅", "Tag my fonts") : T("나머지 태깅", "Tag the rest")) { scout.tagAll(onlyMissing: true) }.controlSize(.small).disabled(tagged >= all)
                            .help(T("패밀리 대표 1벌씩 샘플을 그려 Muse Spark 에 보내요 (패밀리당 약 1,000 토큰)", "Renders one sample per family and sends it to Muse Spark (≈1,000 tokens each)"))
                        if tagged > 0 { Menu(T("더 보기", "More")) {
                            Button(T("전부 다시 태깅", "Re-tag everything")) { scout.tagAll(onlyMissing: false) }
                            let nnAll = scout.catalogCandidates().count, nnDone = scout.catalogTaggedCount
                            if nnAll > 0 {
                                Button(T("눈누 폰트 태깅 \(nnDone)/\(nnAll) (남은 \(nnAll - nnDone)개 ≈ \(scout.fmtUSD(Double(nnAll - nnDone) * 0.0045)))", "Tag Noonnu fonts \(nnDone)/\(nnAll) (≈ \(scout.fmtUSD(Double(nnAll - nnDone) * 0.0045)) left)")) { scout.tagCatalog() }.disabled(nnDone >= nnAll)
                                Button(T("눈누 폰트 10개만 시험 태깅", "Tag 10 Noonnu fonts (test)")) { scout.tagCatalog(limit: 10) }.disabled(nnDone >= nnAll)
                            }
                            if scout.likeCount + scout.dislikeCount > 0 { Button(T("👍/👎 기록 지우기 (👍\(scout.likeCount) · 👎\(scout.dislikeCount))", "Clear thumbs (👍\(scout.likeCount) · 👎\(scout.dislikeCount))")) { scout.clearPrefs() } }
                            Button(T("태그 지우기", "Clear tags"), role: .destructive) { scout.clearTags() }
                        }.menuStyle(.borderlessButton).fixedSize().controlSize(.small) }
                    }
                    if !scout.results.isEmpty {
                        Picker("", selection: $scout.board) { Text(T("보드", "Board")).tag(true); Text(T("목록", "List")).tag(false) }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 110).controlSize(.small)
                        Toggle(T("배경 이미지", "Backgrounds"), isOn: $scout.imagesOn).toggleStyle(.checkbox).controlSize(.small)
                            .help(T("조합 카드 배경을 Muse Image 로 그려요 (장당 $0.01)", "Draw pairing backgrounds with Muse Image ($0.01 each)"))
                    }
                    Spacer()
                    Text(T("누적 \(scout.fmtUSD(scout.usage.usd)) · \(scout.usage.calls)회", "total \(scout.fmtUSD(scout.usage.usd)) · \(scout.usage.calls) calls")).font(.system(size: 11)).foregroundColor(.secondary).monospacedDigit()
                        .help(T("Muse Spark 1.3 표준 요금 기준 추정", "Estimate at Muse Spark 1.3 standard pricing"))
                    Button(scout.keyHint) { scout.showKeySheet = true }.controlSize(.small)
                }
                if !scout.status.isEmpty { Text(scout.status).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1) }
            }
            .padding(.horizontal, 16).padding(.vertical, 10).background(Color(nsColor: .windowBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4])).padding(4).opacity(dropping ? 1 : 0))
            Divider()
            Group {
                if scout.results.isEmpty {
                    ScrollView {
                        VStack(spacing: 14) {
                            Image(systemName: "sparkle.magnifyingglass").font(.system(size: 28)).foregroundColor(.secondary)
                            Text(scout.taggedCount == 0
                                 ? T("1) 「내 폰트 태깅」 — 설치된 폰트를 Muse Spark 가 디자이너 말로 설명해 둬요\n2) 브리프를 쓰고 「찾기」", "1) “Tag my fonts” — Muse Spark describes your installed fonts in designer language\n2) Write a brief and press “Find”")
                                 : T("브리프를 쓰고 「찾기」 — 분위기·용도·시대·언어를 말로 적으면 돼요\n또는 간판·포스터 사진을 이 창에 끌어다 놓기", "Write a brief and press “Find” — mood, use, era, language, in plain words\nor drop a photo of a sign or poster onto this window"))
                                .multilineTextAlignment(.center).foregroundColor(.secondary)
                            if scout.taggedCount > 0 {
                                Text(T("이런 식으로 —", "Try one —")).font(.system(size: 11)).foregroundColor(.secondary).padding(.top, 6)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 300), spacing: 8)], spacing: 8) {
                                    ForEach(ScoutView.examples, id: \.0) { ex in
                                        Button(T(ex.0, ex.1)) { scout.brief = T(ex.0, ex.1); scout.search() }
                                            .buttonStyle(.bordered).controlSize(.regular)
                                    }
                                }.frame(maxWidth: 760)
                            }
                        }.padding(60).frame(maxWidth: .infinity)
                    }
                } else if scout.board {
                    ScoutBoard()
                } else {
                    ScrollView { LazyVStack(spacing: 0) { ForEach(scout.results) { r in ScoutRow(result: r); Divider() } } }
                }
            }
            .background(store.bg)
            .environment(\.colorScheme, store.bgIsDark ? .dark : .light)
        }
        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $dropping) { scout.acceptDrop($0) }
        .onAppear {   // 개발용: SCOUT_TEST_PHOTO=<이미지 경로> 로 실행하면 그 사진으로 바로 찾기 (UI 자동 검증)
            if scout.photo == nil, let p = ProcessInfo.processInfo.environment["SCOUT_TEST_PHOTO"], let img = NSImage(contentsOfFile: p) { scout.findFromPhoto(img) }
            if let n = ProcessInfo.processInfo.environment["SCOUT_TAG_CATALOG"].flatMap(Int.init), !scout.tagging { scout.tagCatalog(limit: n) }   // 개발용: 눈누 N개 시험 태깅
        }
        .sheet(isPresented: $scout.showKeySheet) { ScoutKeySheet() }
        .background(Button("") { briefFocused = true }.keyboardShortcut("l", modifiers: [.command]).opacity(0).frame(width: 0, height: 0))
    }
}

extension ScoutView {
    /// 빈 상태의 예시 브리프 (한/영) — «이런 말엔 이런 폰트» 입구
    static let examples: [(String, String)] = [
        ("베이커리 간판용 따뜻한 손글씨, 한글·영문 둘 다", "Warm hand-lettered font for a bakery sign, Korean + English"),
        ("다이어리 스티커에 쓸 귀엽고 동글동글한 한글", "Cute, round Korean for diary stickers"),
        ("향수 라벨 — 우아한 하이컨트라스트 세리프, 영문", "Perfume label — elegant high-contrast serif, Latin"),
        ("그림책 제목, 둥근 손글씨 느낌", "Picture-book title, soft rounded handwriting"),
        ("테크 스타트업 로고, 기하학적 산세리프", "Tech startup logo, geometric sans"),
        ("요가 스튜디오 간판, 차분하고 얇은 명조", "Yoga studio sign, calm thin serif"),
    ]
}

// MARK: - 보드 (타일 + 조합 카드)

struct ScoutBoard: View {
    @EnvironmentObject var store: Store
    @ObservedObject var scout = ScoutStore.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !scout.pairs.isEmpty {
                    Text(scout.pairs.contains { !$0.name.isEmpty } ? T("방향 제안 — 아트디렉터 2차 심사", "Directions — art director's review") : T("조합 제안 — 제목 + 부제 + 본문", "Pairings — headline + sub + body")).font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: max(1, scout.pairs.count)), alignment: .leading, spacing: 14) {
                        ForEach(scout.pairs) { ScoutPairCard(pair: $0) }
                    }
                    Divider().padding(.vertical, 4)
                }
                Text(T("후보 \(scout.results.count)개 — 같은 문구로 비교", "\(scout.results.count) picks — same copy on every tile")).font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 14, alignment: .top)], alignment: .leading, spacing: 18) {
                    ForEach(scout.results) { ScoutTile(result: $0) }
                }
            }
            .padding(16)
        }
    }
}

/// 카피 줄들을 역할·크기대로 쌓아 그린다 — 타일(폰트 1벌)과 조합 카드(줄 크기별 폰트)가 공유
struct ScoutCopyStack: View {
    @EnvironmentObject var store: Store
    @ObservedObject var scout = ScoutStore.shared
    let copy: ScoutCopy
    let fg: Color
    let scale: CGFloat
    let fontFor: (ScoutLine) -> FontItem
    var body: some View {
        let center = copy.centered
        VStack(alignment: center ? .center : .leading, spacing: 7 * scale) {
            ForEach(Array(copy.lines.enumerated()), id: \.offset) { _, ln in
                let f = fontFor(ln)
                Text(ln.text(korean: scout.hasKorean(f)))
                    .font(store.fontCache.font(f, ln.pt * scale)).foregroundColor(fg.opacity(ln.opacity))
                    .lineLimit(ln.isSmall ? 3 : (ln.size == "xl" ? 1 : 2)).minimumScaleFactor(0.3)
                    .multilineTextAlignment(center ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: center ? .center : .leading)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 눈누 미설치 폰트 배지 + 다운로드/눈누 페이지 버튼
struct ScoutNotInstalled: View {
    @EnvironmentObject var store: Store
    @ObservedObject var scout = ScoutStore.shared
    let id: String
    let compact: Bool
    var body: some View {
        let c = scout.catalogItem(id: id)
        HStack(spacing: 4) {
            Text(T("미설치 · 눈누", "Not installed · Noonnu")).font(.system(size: 9, weight: .semibold)).foregroundColor(.orange)
                .padding(.horizontal, 5).padding(.vertical, 1).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.orange.opacity(0.6)))
            if let c = c {
                if let dl = c.download, let u = URL(string: dl) {
                    Button(compact ? "↓" : T("다운로드", "Download")) { NSWorkspace.shared.open(u) }.controlSize(.mini).help(T("배포처 다운로드 페이지", "Distributor download page"))
                }
                Button(compact ? "눈누" : T("눈누 페이지", "Noonnu page")) { store.openPage(c) }.controlSize(.mini)
            }
        }
    }
}

/// 👍/👎 두 개 — 타일·목록 줄 공용
struct ScoutPrefButtons: View {
    @ObservedObject var scout = ScoutStore.shared
    let item: FontItem
    var size: CGFloat = 12
    var body: some View {
        let v = scout.pref(item)
        HStack(spacing: 4) {
            Button { scout.setPref(item, 1) } label: {
                Image(systemName: v > 0 ? "hand.thumbsup.fill" : "hand.thumbsup").font(.system(size: size)).foregroundColor(v > 0 ? .green : Color.primary.opacity(0.3))
            }.buttonStyle(.plain).help(T("👍 이 결이 좋아요 — 다음 검색·심사에 반영", "👍 Like this — future searches lean this way"))
            Button { scout.setPref(item, -1) } label: {
                Image(systemName: v < 0 ? "hand.thumbsdown.fill" : "hand.thumbsdown").font(.system(size: size)).foregroundColor(v < 0 ? .red : Color.primary.opacity(0.3))
            }.buttonStyle(.plain).help(T("👎 안 고를 폰트 — 다음부터 빼고 비슷한 결도 피함", "👎 Wouldn't pick — excluded from future searches"))
        }
    }
}

/// 미니 목업 — 레이아웃 6종을 한 곳에서. 조합 카드(역할별 폰트)와 타일(폰트 1벌)이 공유한다. 이미지 없으면 단색.
struct ScoutMockup: View {
    @EnvironmentObject var store: Store
    @ObservedObject var scout = ScoutStore.shared
    let copy: ScoutCopy
    let palette: String
    let layout: String
    let image: NSImage?
    let scale: CGFloat
    let fontFor: (ScoutLine) -> FontItem

    func stack(_ fg: Color, _ sc: CGFloat, center: Bool? = nil) -> some View {
        let c = center.map { ScoutCopy(genre: copy.genre, align: $0 ? "center" : "left", lines: copy.lines) } ?? copy
        return ScoutCopyStack(copy: c, fg: fg, scale: scale * sc, fontFor: fontFor)
    }
    @ViewBuilder func photo(_ pal: (bg: Color, fg: Color)) -> some View {
        // overlay 로 얹어야 사진의 고유 크기가 레이아웃을 밀어내지 않는다
        if let img = image { Color.clear.overlay(Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)).clipped() } else { pal.bg }
    }
    var body: some View {
        let pal = ScoutPalette.colors(palette)
        GeometryReader { g in
            let h = g.size.height
            Group {
                if image == nil {
                    ZStack(alignment: .topLeading) { pal.bg; stack(pal.fg, 1).padding(16 * scale) }
                } else {
                    switch layout {
                    case "split":
                        HStack(spacing: 0) {
                            ZStack(alignment: .topLeading) { pal.bg; stack(pal.fg, 0.85).padding(14 * scale) }.frame(width: g.size.width * 0.52)
                            photo(pal)
                        }
                    case "band":
                        VStack(spacing: 0) {
                            photo(pal)
                            ZStack(alignment: .topLeading) { pal.bg; stack(pal.fg, 0.72).padding(.horizontal, 14 * scale).padding(.vertical, 10 * scale) }.frame(height: h * 0.46)
                        }
                    case "badge":
                        ZStack {
                            photo(pal)
                            Color.black.opacity(0.18)
                            stack(pal.fg, 0.86).fixedSize(horizontal: false, vertical: true).padding(12 * scale)
                                .background(RoundedRectangle(cornerRadius: 8).fill(pal.bg.opacity(0.96)))
                                .padding(.horizontal, 18 * scale).padding(.vertical, 16 * scale)
                        }
                    case "frame":
                        ZStack(alignment: .topLeading) {
                            pal.bg
                            VStack(alignment: .leading, spacing: 10 * scale) {
                                photo(pal).frame(height: h * 0.46).clipShape(RoundedRectangle(cornerRadius: 6))
                                stack(pal.fg, 0.75)
                            }.padding(12 * scale)
                        }
                    case "poster":
                        ZStack {
                            photo(pal)
                            pal.bg.opacity(0.35)
                            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                            stack(.white, 0.97, center: true).padding(16 * scale)
                        }
                    default: // overlay
                        ZStack(alignment: .bottomLeading) {
                            photo(pal)
                            LinearGradient(colors: [.clear, .black.opacity(0.25), .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
                            VStack { Spacer(minLength: 0); stack(.white, 0.9).fixedSize(horizontal: false, vertical: true) }.padding(16 * scale)
                        }
                    }
                }
            }
            .frame(width: g.size.width, height: h)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct ScoutTile: View {
    @EnvironmentObject var store: Store
    @ObservedObject var scout = ScoutStore.shared
    let result: ScoutResult
    @State private var showDetail = false
    func roleLabel(_ r: String) -> String {
        switch r { case "headline": return T("제목용", "Headline"); case "price": return T("가격·숫자용", "Price"); case "sub": return T("부제용", "Sub"); case "body": return T("본문용", "Body"); case "avoid": return T("장식용·비추천", "Avoid"); default: return r }
    }
    var body: some View {
        let item = result.item
        // 소속 방향이 있으면 그 방향의 배경·레이아웃·팔레트를 재사용 (추가 비용 0) — 배경 이미지를 끄면 단색
        let dir: ScoutPair? = (result.direction >= 1 && result.direction <= scout.pairs.count) ? scout.pairs[result.direction - 1] : nil
        let img: NSImage? = (scout.imagesOn && dir != nil) ? scout.pairImages[dir!.id] : nil
        VStack(alignment: .leading, spacing: 7) {
            ScoutMockup(copy: scout.copy, palette: img != nil ? dir!.palette : result.palette, layout: dir?.layout ?? "overlay", image: img, scale: 1, fontFor: { _ in item })
                .aspectRatio(4 / 3, contentMode: .fit)
            HStack(spacing: 6) {
                Text("\(result.score)").font(.system(size: 10, weight: .bold)).monospacedDigit().padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15)).cornerRadius(4)
                Text(item.family).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if item.id.hasPrefix("nn:") { ScoutNotInstalled(id: item.id, compact: true) }
                Spacer(minLength: 2)
                ScoutPrefButtons(item: item)
                Button { store.toggleFav(item) } label: {
                    Image(systemName: "star.fill").font(.system(size: 12)).foregroundColor(store.isFav(item) ? Color(red: 0.94, green: 0.71, blue: 0) : Color.primary.opacity(0.18))
                }.buttonStyle(.plain).padding(.leading, 2)
            }.foregroundColor(.primary)
            if result.legibility > 0 {
                HStack(spacing: 6) {
                    Text(T("가독성", "Legibility") + " " + String(repeating: "●", count: result.legibility) + String(repeating: "○", count: 5 - result.legibility)).font(.system(size: 10)).foregroundColor(.secondary)
                    if !result.roleFit.isEmpty {
                        Text(roleLabel(result.roleFit)).font(.system(size: 9, weight: .semibold)).foregroundColor(result.roleFit == "avoid" ? .red : .secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
                    }
                    if let d = dir, !d.name.isEmpty { Text(d.name).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1) }
                }
            }
            Text(result.note.isEmpty ? result.why : result.note).font(.system(size: 11)).foregroundColor(Color.primary.opacity(0.7)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .opacity(result.roleFit == "avoid" ? 0.6 : 1)
        .contentShape(Rectangle())
        .onTapGesture { showDetail = true }
        .help(T("클릭하면 내 문구 미리보기·태그 전체", "Click for your own sample text and all tags"))
        .popover(isPresented: $showDetail, arrowEdge: .bottom) {
            ScoutRow(result: result).frame(width: 640).padding(.vertical, 4)
                .background(store.bg).environment(\.colorScheme, store.bgIsDark ? .dark : .light)
        }
    }
}

struct ScoutPairCard: View {
    @EnvironmentObject var store: Store
    @ObservedObject var scout = ScoutStore.shared
    let pair: ScoutPair
    static let H: CGFloat = 230
    func nm(_ f: FontItem) -> String { f.id.hasPrefix("nn:") ? f.family + T("(미설치·눈누)", "(Noonnu, not installed)") : f.family }
    func fontFor(_ ln: ScoutLine) -> FontItem {
        if ln.role == "price" { return pair.price }
        switch ln.size { case "xl", "l": return pair.headline; case "m": return pair.sub; default: return pair.body }
    }
    var body: some View {
        let img = scout.imagesOn ? scout.pairImages[pair.id] : nil
        let busy = scout.imagesOn && scout.pairImageBusy.contains(pair.id)
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                ScoutMockup(copy: scout.copy, palette: pair.palette, layout: pair.layout, image: img, scale: 0.8, fontFor: fontFor)
                    .frame(height: ScoutPairCard.H)
                if busy { ProgressView().controlSize(.small).padding(8) }
            }
            HStack(spacing: 6) {
                if !pair.name.isEmpty { Text(pair.name).font(.system(size: 12, weight: .bold)).lineLimit(1).foregroundColor(.primary) }
                if !pair.mood.isEmpty { Text(pair.mood).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1) }
                Spacer(minLength: 2)
                Text(pair.layout).font(.system(size: 9)).foregroundColor(.secondary).padding(.horizontal, 5).padding(.vertical, 1).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
            }
            let fonts = pair.price.id == pair.headline.id ? "\(nm(pair.headline)) + \(nm(pair.sub)) + \(nm(pair.body))"
                : T("제목 \(nm(pair.headline)) · 가격 \(nm(pair.price)) · 부제 \(nm(pair.sub)) · 본문 \(nm(pair.body))", "Headline \(nm(pair.headline)) · Price \(nm(pair.price)) · Sub \(nm(pair.sub)) · Body \(nm(pair.body))")
            Text(fonts).font(.system(size: 10.5, weight: .semibold)).lineLimit(2).foregroundColor(.primary).fixedSize(horizontal: false, vertical: true)
            Text(pair.why).font(.system(size: 11)).foregroundColor(Color.primary.opacity(0.7)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ScoutRow: View {
    @EnvironmentObject var store: Store
    @ObservedObject var scout = ScoutStore.shared
    let result: ScoutResult
    @State private var showTags = false
    var body: some View {
        let item = result.item
        let t = scout.tag(for: item)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("\(result.score)").font(.system(size: 11, weight: .bold)).monospacedDigit().padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15)).cornerRadius(5).help(T("적합도", "Fit score"))
                Text(item.family).font(.system(size: 13, weight: .bold)).lineLimit(1)
                    .onTapGesture { store.copy(item.ps, T("PostScript 이름 복사됨: ", "Copied PostScript name: ") + item.ps) }
                if item.familyEN != item.family { Text(item.familyEN).foregroundColor(.secondary).lineLimit(1) }
                Text(item.style).foregroundColor(.secondary).lineLimit(1)
                if item.id.hasPrefix("nn:") { ScoutNotInstalled(id: item.id, compact: false) }
                if let t = t {
                    Button { showTags.toggle() } label: {
                        Text(t.summary).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                            .padding(.horizontal, 7).padding(.vertical, 1).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    }.buttonStyle(.plain).help(T("클릭하면 Muse Spark 가 본 태그 전체", "Click for everything Muse Spark saw"))
                    .popover(isPresented: $showTags, arrowEdge: .bottom) { ScoutTagCard(item: item, tag: t) }
                }
                Spacer(minLength: 4)
                let n = store.familyCount(item)
                if n > 1 { Text(T("\(n)개 스타일", "\(n) styles")).font(.system(size: 11)).foregroundColor(.secondary) }
                ScoutPrefButtons(item: item, size: 13)
                Button { store.toggleFav(item) } label: {
                    Image(systemName: "star.fill").font(.system(size: 14)).foregroundColor(store.isFav(item) ? Color(red: 0.94, green: 0.71, blue: 0) : Color.primary.opacity(0.18))
                }.buttonStyle(.plain).help(T("즐겨찾기", "Favorite")).padding(.leading, 2)
            }.foregroundColor(Color.primary)
            Text(scout.previewText(item, korean: t?.korean ?? (store.profiles[item.id]?.isKo ?? true)))
                .font(store.fontCache.font(item, store.size)).foregroundColor(store.fg).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            Text(result.why).font(.system(size: 12)).foregroundColor(Color.primary.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct ScoutTagCard: View {
    let item: FontItem
    let tag: ScoutTag
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.family).font(.system(size: 13, weight: .bold))
                Text(item.style).foregroundColor(.secondary)
                Spacer()
                Text("muse-spark-1.3").font(.system(size: 10)).foregroundColor(.secondary)
            }
            row(T("분위기", "Mood"), tag.mood.joined(separator: ", "))
            row(T("구조", "Style"), tag.style.joined(separator: ", "))
            row(T("시대", "Era"), tag.era)
            row(T("굵기감", "Weight"), tag.weightFeel)
            row(T("어울리는 곳", "Best for"), tag.bestUse.joined(separator: ", "))
            row(T("언어", "Scripts"), ((tag.latin ? ["Latin"] : []) + (tag.korean ? [T("한글", "Korean")] : [])).joined(separator: " + "))
            if !tag.personality.isEmpty { Text("“" + tag.personality + "”").font(.system(size: 12)).italic().padding(.top, 2).fixedSize(horizontal: false, vertical: true) }
            if !tag.avoid.isEmpty { row(T("피할 곳", "Avoid"), tag.avoid) }
            Text(T("샘플 이미지 1장을 보고 Muse Spark 가 쓴 설명 · 이 맥에만 저장", "Written by Muse Spark from one rendered sample · stored only on this Mac")).font(.system(size: 10)).foregroundColor(.secondary).padding(.top, 4)
        }
        .padding(14).frame(width: 420)
    }
    func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(k).font(.system(size: 11)).foregroundColor(.secondary).frame(width: 74, alignment: .trailing)
            Text(v.isEmpty ? "—" : v).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ScoutKeySheet: View {
    @ObservedObject var scout = ScoutStore.shared
    @State private var key = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(T("Meta Model API 키", "Meta Model API key")).font(.system(size: 14, weight: .bold))
            Text(T("dev.meta.ai → API keys → Create API key. 키는 이 맥의 키체인에만 저장되고 Meta 서버로만 전송돼요.", "dev.meta.ai → API keys → Create API key. Stored only in this Mac's Keychain and sent only to Meta's API.")).font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField(T("키 붙여넣기", "Paste key"), text: $key).textFieldStyle(.roundedBorder)
            HStack {
                if scout.hasKey { Button(T("키 삭제", "Remove key"), role: .destructive) { scout.setKey(""); scout.showKeySheet = false } }
                Spacer()
                Button(T("취소", "Cancel")) { scout.showKeySheet = false }
                Button(T("저장", "Save")) { scout.setKey(key); scout.showKeySheet = false }.buttonStyle(.borderedProminent).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(T("모델 muse-spark-1.3 (표준 모드 — 내 폰트 이미지는 학습에 쓰이지 않아요)", "Model muse-spark-1.3 (standard mode — your font images are not used for training)")).font(.system(size: 10)).foregroundColor(.secondary)
        }
        .padding(18).frame(width: 440)
    }
}
