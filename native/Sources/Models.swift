import Foundation
import CoreText
import CryptoKit

// MARK: - 폰트 한 벌

struct FontItem: Identifiable, Hashable {
    enum Source: String { case system, user, adobe, folder }
    let id: String          // 설치: PostScript 이름 / 폴더: 파일경로(+#서체번호)
    let ps: String
    let family: String      // 현지화(한글) 패밀리명
    let familyEN: String    // 영문 패밀리명
    let style: String
    let full: String
    let path: String
    let file: String
    let source: Source
    let mtime: TimeInterval
    let folderID: String?
    let descriptor: CTFontDescriptor

    var familyKey: String { folderID.map { family + "@" + $0 } ?? family }
    var sourceLabel: String {
        switch source {
        case .system: return "시스템"
        case .user: return path.hasPrefix("/Library") ? "공용" : "사용자"
        case .adobe: return "Adobe Fonts"
        case .folder: return "폴더"
        }
    }
    func ctFont(_ size: CGFloat) -> CTFont { CTFontCreateWithFontDescriptor(descriptor, size, nil) }
    static func == (a: FontItem, b: FontItem) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

func shortHash(_ s: String) -> String {
    let d = Insecure.SHA1.hash(data: Data(s.utf8))
    return d.map { String(format: "%02x", $0) }.joined().prefix(8).description
}

// MARK: - 생김새 측정값

struct Profile: Codable {
    var err: Int? = nil
    var ko: Int? = nil, la: Int? = nil, ja: Int? = nil, hj: Int? = nil
    var stem: Double? = nil, foot: Double? = nil, slant: Double? = nil, outline: Int? = nil
    var bar: Double? = nil, corner: Double? = nil, contrast: Double? = nil
    var aspect: Double? = nil, straight: Double? = nil, density: Double? = nil
    var irr: Double? = nil, mono: Int? = nil
    var isKo: Bool { ko == 1 }
    var isLaOnly: Bool { la == 1 && ko != 1 && ja != 1 && hj != 1 }
}

// MARK: - 사용자 데이터 (웹판 user.json 과 같은 키)

struct ManualTag: Codable { var on: [String] = []; var off: [String] = [] }

struct UIState: Codable {
    var sample: String? = nil
    var size: Double? = nil
    var q: String? = nil
    var weight: String? = nil
    var sort: String? = nil
    var group: Bool? = nil
    var fg: String? = nil
    var bg: String? = nil
    var nav: String? = nil
    var lang: String? = nil
}

struct UserData: Codable {
    var fav: [String] = []
    var sets: [String: [String]] = [:]
    var phrases: [String] = ["다람쥐 헌 쳇바퀴에 타고파", "The quick brown fox jumps over the lazy dog", "쫄깃 탱글", "ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz", "0123456789 ₩$% !?&@#*()"]
    var tags: [String: ManualTag] = [:]
    var state2: UIState? = nil

    init() {}
    // 웹판 파일에 다른 타입이 섞여 있어도 키별로 느슨하게 읽는다
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fav = (try? c.decode([String].self, forKey: .fav)) ?? []
        sets = (try? c.decode([String: [String]].self, forKey: .sets)) ?? [:]
        if let p = try? c.decode([String].self, forKey: .phrases) { phrases = p }
        tags = (try? c.decode([String: ManualTag].self, forKey: .tags)) ?? [:]
        state2 = try? c.decode(UIState.self, forKey: .state2)
    }
}

// MARK: - 분류 정의

enum Cat {
    static let all: [(String, String)] = [
        ("black", "두꺼운 제목용"), ("sans", "고딕·산세리프"), ("serif", "명조·세리프"), ("round", "둥근·귀여운"),
        ("hand", "손글씨"), ("brush", "붓글씨·캘리"), ("deco", "장식·디자인"), ("wide", "넙적한 (평체)"), ("narrow", "길쭉한 (장체)"),
    ]
    static let weights: [(String, String)] = [("thin", "가는"), ("regular", "보통"), ("bold", "두꺼운"), ("black", "아주 두꺼운")]
    static let label: [String: String] = {
        var d: [String: String] = [:]
        for (k, l) in all { d[k] = l }
        for (k, l) in weights { d["w:" + k] = l }
        return d
    }()
}

// MARK: - 자동 분류 규칙 (웹판 detectAuto 와 동일한 기준값)

enum Classifier {
    struct TH {
        static let thin = 0.05, bold = 0.11, black = 0.15
        static let foot = 1.7, contrast = 2.2, corner = 0.5
        static let handStraight = 0.5, handIrrKo = 0.015, handIrrLa = 0.02, brushStraight = 0.3
        static let sansMin = 0.7, slant = 0.165
        static let wideKo = 1.18, narrowKo = 0.82, wideLa = 1.0, narrowLa = 0.6
    }
    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    static let RX: [String: NSRegularExpression] = [
        "thin": rx(#"\b(thin|hairline|ultralight|extralight|ul|el)\b|가는|얇은"#),
        "light": rx(#"\blight\b|라이트|가는체"#),
        "bold": rx(#"\b(bold|semibold|demibold|extrabold|b|eb|sb)\b|볼드|굵은"#),
        "black": rx(#"\b(black|heavy|ultra|extrabold|eb|fat)\b|블랙|헤비|진한 볼드체"#),
        "serif": rx(#"serif|명조|바탕|myungjo|myeongjo|batang|mincho|song|roman|garamond|baskerville|caslon|didot|bodoni|times|georgia|minion"#),
        "sans": rx(#"\bsans\b|고딕|gothic|돋움|dotum|gulim|굴림|helvetica|arial|futura|pretendard|spoqa|noto sans"#),
        "round": rx(#"round|둥근|rounded|라운드|rd\b|통통|dunggeun"#),
        "hand": rx(#"hand|script|\bpen\b|cursive|손글씨|손글|손멋|필기|펜글|연필|낙서|crayon|marker|chalk|sign|write|writing|scrawl|끄적|꼬불|삐뚤|어린이"#),
        "brush": rx(#"brush|calli|붓|캘리|먹|ink|흘림|서예|궁서|gungseo"#),
        "italic": rx(#"italic|oblique|기울|slant"#),
        "deco": rx(#"outline|hollow|inline|외곽|테두리|pixel|dot\b|도트|픽셀|8.?bit|bitmap|shadow|3d|stencil|스텐실|neon|네온|display|디스플레이|decor|장식"#),
        "wide": rx(#"extended|expanded|\bwide\b|평체|넓은|ext\b|exp\b"#),
        "narrow": rx(#"condensed|narrow|compressed|장체|좁은|\bcond\b|\bcn\b|compact"#),
    ]
    static func m(_ k: String, _ s: String) -> Bool {
        RX[k]!.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func auto(name n: String, profile pOpt: Profile?) -> Set<String> {
        let p = pOpt ?? Profile()
        var t = Set<String>()
        // 굵기
        var w: Double? = p.stem ?? (p.density.map { $0 * 0.55 })
        if w == nil && pOpt != nil && pOpt?.err != nil { w = nil }
        var wt: String? = nil
        if let w = w { wt = w < TH.thin ? "thin" : w < TH.bold ? "regular" : w < TH.black ? "bold" : "black" }
        else if m("black", n) { wt = "black" } else if m("bold", n) { wt = "bold" } else if m("thin", n) || m("light", n) { wt = "thin" } else if pOpt != nil && p.err == nil { wt = "regular" }
        if let wt = wt { t.insert("w:" + wt); if wt == "black" { t.insert("black") } }
        // 손글씨 계열
        let irrTH = p.isKo ? TH.handIrrKo : TH.handIrrLa
        let handish = m("hand", n) || m("brush", n) || (p.irr.map { $0 >= irrTH } ?? false) || ((p.straight.map { $0 < TH.handStraight } ?? false) && (p.stem ?? 0) >= 0.05)
        let brush = handish && (m("brush", n) || (p.straight.map { $0 < TH.brushStraight } ?? false))
        if brush { t.insert("brush") } else if handish { t.insert("hand") }
        let nameSerif = m("serif", n) && !m("sans", n)
        let serif = !handish && (nameSerif || ((p.mono ?? 0) == 0 && ((p.foot.map { $0 >= TH.foot } ?? false) || (p.contrast.map { $0 >= TH.contrast } ?? false))))
        if serif { t.insert("serif") }
        let round = m("round", n) || (!serif && (p.corner.map { $0 <= TH.corner } ?? false) && (p.bar ?? 0) >= 0.06 && (p.straight ?? 1) >= 0.6)
        if round { t.insert("round") }
        let thinOk = (p.stem.map { $0 < TH.thin } ?? false) && ((p.foot ?? 0) < 1.3)
        if !serif && !handish && !round && ((p.straight.map { $0 >= TH.sansMin } ?? false) || thinOk || m("sans", n)) { t.insert("sans") }
        if (p.outline ?? 0) == 1 || m("deco", n) { t.insert("deco") }
        if let a = p.aspect {
            let (wi, na) = p.isKo ? (TH.wideKo, TH.narrowKo) : (TH.wideLa, TH.narrowLa)
            if a >= wi { t.insert("wide") } else if a <= na { t.insert("narrow") }
        }
        if m("wide", n) { t.remove("narrow"); t.insert("wide") }
        if m("narrow", n) { t.remove("wide"); t.insert("narrow") }
        return t
    }

    static func apply(_ auto: Set<String>, manual: ManualTag?) -> Set<String> {
        guard let mt = manual else { return auto }
        var t = auto
        for x in mt.off { t.remove(x) }
        for x in mt.on {
            if x.hasPrefix("w:") { for y in t where y.hasPrefix("w:") { t.remove(y) } }
            t.insert(x)
        }
        return t
    }
}
