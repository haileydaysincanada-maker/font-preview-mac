import SwiftUI
import Combine
import AppKit
import CoreText

let DEFAULT_SAMPLE = "다람쥐 헌 쳇바퀴에 타고파 The quick brown fox 0123456789"
let CONF_DIR = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/fontviewer")
let USER_JSON = CONF_DIR.appendingPathComponent("user.json")
let FOLDERS_JSON = CONF_DIR.appendingPathComponent("folders.json")
let PROFILES_JSON = CONF_DIR.appendingPathComponent("profiles_native_v1.json")

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces); if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0; Scanner(string: s).scanHexInt64(&v)
        if s.count == 6 { self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255) } else { self = .black }
    }
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

final class FontCache {
    private var dict: [String: Font] = [:]
    func font(_ item: FontItem, _ size: Double) -> Font {
        let k = item.id + "@" + String(Int(size))
        if let f = dict[k] { return f }
        if dict.count > 6000 { dict.removeAll() }
        let f = Font(item.ctFont(CGFloat(size)))
        dict[k] = f
        return f
    }
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    let fontCache = FontCache()

    // 데이터
    @Published private(set) var fonts: [FontItem] = []
    @Published private(set) var profiles: [String: Profile] = [:]
    @Published private(set) var user = UserData()
    @Published private(set) var folders: [URL] = []
    private(set) var hiddenCount = 0, dupCount = 0, installedCount = 0

    // 화면 상태
    @Published var sample = DEFAULT_SAMPLE { didSet { saveUserSoon() } }
    @Published var size: Double = 36 { didSet { saveUserSoon() } }
    @Published var query = "" { didSet { saveUserSoon() } }
    @Published var weight = "" { didSet { applyFilters(); saveUserSoon() } }
    @Published var sort = "name" { didSet { applyFilters(); saveUserSoon() } }
    @Published var group = true { didSet { applyFilters(); saveUserSoon() } }
    @Published var fg: Color = Color(hex: "#111111") { didSet { saveUserSoon() } }
    @Published var bg: Color = .white { didSet { saveUserSoon() } }
    @Published var nav = "all" { didSet { applyFilters(); saveUserSoon() } }
    @Published var lang = "" { didSet { applyFilters(); saveUserSoon() } }   // "" 전체 / "ko" 한글 / "la" 영문 전용
    // 추천
    @Published private(set) var catalog: [CatalogItem] = []
    @Published private(set) var recs: [Recommendation] = []
    @Published private(set) var installing = Set<String>()
    @Published var showInstalledRecs = false { didSet { applyFilters() } }
    private var installedCatalogIDs = Set<String>()
    private(set) var tasteCount = 0
    @Published private(set) var previewFonts: [String: CGFont] = [:]
    @Published private(set) var previewLoading = Set<String>()
    @Published private(set) var previewFailed = Set<String>()
    private var previewFontCache: [String: Font] = [:]
    @Published private(set) var previewText = ""   // 미리보기 서브셋에 쓰는 문구 (입력 후 0.6초 뒤 반영)
    @Published private(set) var expanded = Set<String>()
    @Published private(set) var visible: [FontItem] = []
    @Published private(set) var visibleFamilies = 0
    @Published private(set) var counts: [String: Int] = [:]
    @Published var progress = ""
    @Published var toast: String? = nil

    // 파생
    private var tags: [String: Set<String>] = [:]
    private var rep: [String: String] = [:]
    private var famCount: [String: Int] = [:]
    private var byID: [String: FontItem] = [:]
    private var bag = Set<AnyCancellable>()
    private var saveTask: Task<Void, Never>? = nil
    private var analysisTask: Task<Void, Never>? = nil

    private init() {
        $query.debounce(for: .milliseconds(150), scheduler: DispatchQueue.main).sink { [weak self] _ in self?.applyFilters() }.store(in: &bag)
        $sample.debounce(for: .milliseconds(600), scheduler: DispatchQueue.main).sink { [weak self] s in self?.previewText = Store.previewTextFor(s) }.store(in: &bag)
        previewText = Store.previewTextFor(sample)
        loadUser()
        folders = loadFolders()
        profiles = (try? JSONDecoder().decode([String: Profile].self, from: Data(contentsOf: PROFILES_JSON))) ?? [:]
        catalog = CatalogLoader.load()
        reloadFonts()
    }

    // MARK: 로드
    func reloadFonts() {
        analysisTask?.cancel()
        let inst = FontLoader.installed(excluding: folders.map { $0.path })
        installedCount = inst.fonts.count; hiddenCount = inst.hidden; dupCount = inst.dup
        var all = inst.fonts
        for f in folders { all += FontLoader.folder(f) }
        fonts = all
        byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // 패밀리 대표(Regular 계열 우선)
        var groups: [String: [FontItem]] = [:]
        for f in all { groups[f.familyKey, default: []].append(f) }
        let repRE = try! NSRegularExpression(pattern: #"^(regular|normal|medium|book|roman|plain|r|m|보통|레귤러|미디엄|기본|일반체|중간체)$"#, options: [.caseInsensitive])
        let rmRE = try! NSRegularExpression(pattern: #"regular|medium"#, options: [.caseInsensitive])
        func matches(_ re: NSRegularExpression, _ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        rep = [:]; famCount = [:]
        for (k, items) in groups {
            famCount[k] = items.count
            rep[k] = (items.first { matches(repRE, $0.style) } ?? items.first { matches(rmRE, $0.style) } ?? items[0]).id
        }
        recomputeAllTags()
        recomputeInstalledCatalog()
        applyFilters()
        startAnalysis()
    }

    // MARK: 추천
    private func recomputeInstalledCatalog() {
        let names = fonts.filter { $0.source != .folder }.map { ($0.family + "|" + $0.familyEN + "|" + $0.ps).lowercased() }
        var s = Set<String>()
        for c in catalog where !c.match.isEmpty {
            let ms = c.match.map { $0.lowercased() }
            if names.contains(where: { n in ms.contains { n.contains($0) } }) { s.insert(c.id) }
        }
        installedCatalogIDs = s
    }
    func isInstalled(_ c: CatalogItem) -> Bool { installedCatalogIDs.contains(c.id) }
    /// 즐겨찾기 + 세트에 담긴 폰트의 태그 빈도 (취향)
    private func tasteProfile() -> (freq: [String: Double], koShare: Double, count: Int) {
        var liked = Set(user.fav)
        for (_, ids) in user.sets { liked.formUnion(ids) }
        let items = liked.compactMap { byID[$0] }
        guard !items.isEmpty else { return ([:], 0.5, 0) }
        var cnt: [String: Double] = [:], ko = 0.0
        for f in items {
            for t in tagsOf(f) { cnt[t, default: 0] += 1 }
            if profiles[f.id]?.isKo ?? false { ko += 1 }
        }
        let n = Double(items.count)
        return (cnt.mapValues { $0 / n }, ko / n, items.count)
    }
    private func catalogBase(_ c: CatalogItem, terms: [String]) -> Bool {
        if !showInstalledRecs && isInstalled(c) { return false }
        if lang == "ko" && c.lang != "ko" { return false }
        if lang == "la" && c.lang != "la" { return false }
        if !weight.isEmpty && !c.normTags.contains("w:" + weight) && !(weight == "black" && c.tags.contains("black")) { return false }
        if !terms.isEmpty {
            let hay = (c.name + " " + c.nameEN + " " + c.desc + " " + c.tags.compactMap { Cat.label[$0] ?? Cat.label["w:" + $0] }.joined(separator: " ") + " " + c.sourceLabel).lowercased()
            if !terms.allSatisfy({ hay.contains($0) }) { return false }
        }
        return true
    }
    private func buildRecs(mode: String, terms: [String]) -> [Recommendation] {
        let base = catalog.filter { catalogBase($0, terms: terms) }
        if mode == "all" {
            return base.map { Recommendation(item: $0, score: 0, reason: "") }
        }
        let t = tasteProfile()
        tasteCount = t.count
        guard t.count >= 3 else { return [] }
        var out: [Recommendation] = []
        for c in base {
            var score = 0.0
            var hits: [(String, Double)] = []
            for tag in Set(c.normTags) {
                let f = t.freq[tag] ?? 0
                if f > 0 { score += f; hits.append((tag, f)) }
            }
            if score <= 0 { continue }
            score += (c.lang == "ko" ? t.koShare : 1 - t.koShare) * 0.5
            hits.sort { $0.1 > $1.1 }
            let why = hits.prefix(2).map { "\(Cat.label[$0.0] ?? $0.0) \(Int(($0.1 * Double(t.count)).rounded()))개" }.joined(separator: " · ")
            out.append(Recommendation(item: c, score: score, reason: "별·세트에 담은 폰트 \(t.count)개 중 " + why + " 와 같은 결"))
        }
        return out.sorted { $0.score > $1.score }
    }
    func install(_ c: CatalogItem) {
        guard !installing.contains(c.id) else { return }
        installing.insert(c.id)
        Task {
            do {
                let files = try await Installer.install(c)
                try? await Task.sleep(nanoseconds: 800_000_000)
                installing.remove(c.id)
                reloadFonts()
                showToast("\(c.name) 설치됨 (\(files.count)개 파일 → ~/Library/Fonts)")
            } catch {
                installing.remove(c.id)
                showToast("설치 실패: " + error.localizedDescription)
            }
        }
    }
    func openPage(_ c: CatalogItem) { if let u = URL(string: c.page) { NSWorkspace.shared.open(u) } }
    /// 서브셋에 넣을 글자: 문구 + 폰트 이름(문구가 비었을 때) + 숫자. 글자 종류만 남기고 200자 제한.
    static func previewTextFor(_ s: String) -> String {
        var seen = Set<Character>(); var out = ""
        for ch in (s + " 0123456789") where !ch.isWhitespace || ch == " " { if seen.insert(ch).inserted { out.append(ch) } }
        return String(out.prefix(200))
    }
    private func previewKey(_ c: CatalogItem) -> String { c.source == "google" ? c.id + "|" + previewText + "|" + c.nameEN : c.id }
    func loadPreview(_ c: CatalogItem) {
        let k = previewKey(c)
        guard c.previewable, previewFonts[k] == nil, !previewLoading.contains(k), !previewFailed.contains(k) else { return }
        previewLoading.insert(k)
        let text = previewText + " " + c.nameEN
        Task {
            do { let f = try await PreviewLoader.font(for: c, text: text); previewFonts[k] = f }
            catch { previewFailed.insert(k) }
            previewLoading.remove(k)
        }
    }
    func previewState(_ c: CatalogItem) -> (loading: Bool, failed: Bool) { let k = previewKey(c); return (previewLoading.contains(k), previewFailed.contains(k)) }
    func previewFont(_ c: CatalogItem) -> Font? {
        guard let cg = previewFonts[previewKey(c)] else { return nil }
        let k = previewKey(c) + "@" + String(Int(size))
        if let f = previewFontCache[k] { return f }
        if previewFontCache.count > 3000 { previewFontCache.removeAll() }
        let f = Font(CTFontCreateWithGraphicsFont(cg, CGFloat(size), nil, nil))
        previewFontCache[k] = f
        return f
    }
    /// 카탈로그 항목용 문구 (영문 폰트면 영문만)
    func shownSample(forCatalog c: CatalogItem) -> String { latinOnly(sample.isEmpty ? c.nameEN : sample, strip: c.lang == "la" || lang == "la") }

    func familyCount(_ item: FontItem) -> Int { famCount[item.familyKey] ?? 1 }
    func isExpanded(_ item: FontItem) -> Bool { expanded.contains(item.familyKey) }
    func toggleExpand(_ item: FontItem) { if expanded.contains(item.familyKey) { expanded.remove(item.familyKey) } else { expanded.insert(item.familyKey) }; applyFilters() }

    // MARK: 태그
    private func nameOf(_ f: FontItem) -> String { (f.family + " " + f.familyEN + " " + f.style + " " + f.ps + " " + f.file).lowercased() }
    private func recomputeTag(_ f: FontItem) { tags[f.id] = Classifier.apply(Classifier.auto(name: nameOf(f), profile: profiles[f.id]), manual: user.tags[f.id]) }
    private func recomputeAllTags() { for f in fonts { recomputeTag(f) } }
    func tagsOf(_ item: FontItem) -> Set<String> { tags[item.id] ?? [] }
    func autoTags(_ item: FontItem) -> Set<String> { Classifier.auto(name: nameOf(item), profile: profiles[item.id]) }
    func isManual(_ item: FontItem) -> Bool { if let m = user.tags[item.id] { return !m.on.isEmpty || !m.off.isEmpty }; return false }
    func tagSummary(_ item: FontItem) -> String {
        let t = tagsOf(item)
        var parts = Cat.all.filter { t.contains($0.0) }.map { $0.1 }
        if let w = t.first(where: { $0.hasPrefix("w:") }), w != "w:regular", !(w == "w:black" && t.contains("black")) { parts.append(Cat.label[w] ?? w) }
        return parts.joined(separator: " · ")
    }
    func toggleTag(_ item: FontItem, _ id: String) {
        let auto = autoTags(item); let cur = tagsOf(item)
        var m = user.tags[item.id] ?? ManualTag()
        m.on.removeAll { $0 == id }; m.off.removeAll { $0 == id }
        if id.hasPrefix("w:") {
            m.on.removeAll { $0.hasPrefix("w:") }; m.off.removeAll { $0.hasPrefix("w:") }
            if !auto.contains(id) { m.on.append(id) }
        } else if cur.contains(id) {
            if auto.contains(id) { m.off.append(id) }
        } else if !auto.contains(id) { m.on.append(id) }
        if m.on.isEmpty && m.off.isEmpty { user.tags[item.id] = nil } else { user.tags[item.id] = m }
        recomputeTag(item); applyFilters(); saveUserSoon()
    }
    func resetManual(_ item: FontItem) { user.tags[item.id] = nil; recomputeTag(item); applyFilters(); saveUserSoon() }

    // MARK: 즐겨찾기·세트·문구
    func isFav(_ item: FontItem) -> Bool { user.fav.contains(item.id) }
    func toggleFav(_ item: FontItem) {
        if let i = user.fav.firstIndex(of: item.id) { user.fav.remove(at: i) } else { user.fav.append(item.id) }
        if nav == "fav" || sort == "fav" { applyFilters() } else { refreshCounts() }
        saveUserSoon()
    }
    var setNames: [String] { user.sets.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    func inSet(_ name: String, _ item: FontItem) -> Bool { user.sets[name]?.contains(item.id) ?? false }
    func setMembership(_ name: String, _ item: FontItem, _ on: Bool) {
        var arr = user.sets[name] ?? []
        arr.removeAll { $0 == item.id }; if on { arr.append(item.id) }
        user.sets[name] = arr
        if nav == "set:" + name { applyFilters() } else { refreshCounts() }
        saveUserSoon()
    }
    func createSet(_ name: String, adding item: FontItem? = nil) {
        if user.sets[name] == nil { user.sets[name] = [] }
        if let it = item, !(user.sets[name]!.contains(it.id)) { user.sets[name]!.append(it.id) }
        refreshCounts(); saveUserSoon()
    }
    func deleteSet(_ name: String) { user.sets[name] = nil; if nav == "set:" + name { nav = "all" } else { refreshCounts() }; saveUserSoon() }
    func renameSet(_ old: String, _ new: String) {
        guard !new.isEmpty, new != old, user.sets[new] == nil else { return }
        user.sets[new] = user.sets[old]; user.sets[old] = nil
        if nav == "set:" + old { nav = "set:" + new } else { refreshCounts() }
        saveUserSoon()
    }
    var phrases: [String] { user.phrases }
    var sampleSaved: Bool { user.phrases.contains(sample.trimmingCharacters(in: .whitespaces)) }
    func togglePhraseSaved() {
        let s = sample.trimmingCharacters(in: .whitespaces); guard !s.isEmpty else { return }
        if let i = user.phrases.firstIndex(of: s) { user.phrases.remove(at: i); showToast("문구 삭제") } else { user.phrases.insert(s, at: 0); showToast("문구 저장") }
        saveUserSoon()
    }

    // MARK: 폴더
    private func loadFolders() -> [URL] {
        ((try? JSONDecoder().decode([String].self, from: Data(contentsOf: FOLDERS_JSON))) ?? []).filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
    private func saveFolders() {
        try? FileManager.default.createDirectory(at: CONF_DIR, withIntermediateDirectories: true)
        try? JSONEncoder().encode(folders.map { $0.path }).write(to: FOLDERS_JSON)
    }
    func addFolder(_ u: URL) {
        var url = u
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if !isDir.boolValue { url = url.deletingLastPathComponent() }
        url = URL(fileURLWithPath: url.path)  // 꼬리 슬래시 정리
        guard !folders.contains(where: { $0.path == url.path }) else { nav = "folder:" + shortHash(url.path); return }
        folders.append(url); saveFolders()
        reloadFonts()
        nav = "folder:" + shortHash(url.path)
        showToast("폴더 등록: \(url.lastPathComponent)")
    }
    func removeFolder(_ fid: String) {
        folders.removeAll { shortHash($0.path) == fid }; saveFolders()
        if nav == "folder:" + fid { nav = "all" }
        reloadFonts()
    }
    func folderName(_ fid: String) -> String { folders.first { shortHash($0.path) == fid }?.lastPathComponent ?? "폴더" }
    func folderPath(_ fid: String) -> String { folders.first { shortHash($0.path) == fid }?.path ?? "" }
    func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        p.prompt = "이 폴더 보기"; p.message = "미리볼 폰트 폴더를 고르세요 (설치되지 않아요)"
        if p.runModal() == .OK { for u in p.urls { addFolder(u) } }
    }

    // MARK: 필터
    func passNav(_ f: FontItem, _ n: String) -> Bool {
        switch n {
        case "all": return f.source != .folder
        case "ko": return f.source != .folder && (profiles[f.id]?.isKo ?? false)
        case "laOnly": return f.source != .folder && (profiles[f.id]?.isLaOnly ?? false)
        case "recent": return f.source != .folder && f.mtime >= Date().timeIntervalSince1970 - 30 * 86400
        case "fav": return user.fav.contains(f.id)
        case "rec:all", "rec:taste": return false
        default:
            if n.hasPrefix("cat:") { return tagsOf(f).contains(String(n.dropFirst(4))) }
            if n.hasPrefix("set:") { return user.sets[String(n.dropFirst(4))]?.contains(f.id) ?? false }
            if n.hasPrefix("folder:") { return f.folderID == String(n.dropFirst(7)) }
            return true
        }
    }
    private func baseFilter() -> [Bool] {
        let terms = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        return fonts.map { f in
            if !terms.isEmpty {
                let hay = (f.family + " " + f.familyEN + " " + f.full + " " + f.ps + " " + f.style + " " + f.file).lowercased()
                if !terms.allSatisfy({ hay.contains($0) }) { return false }
            }
            if !weight.isEmpty && !tagsOf(f).contains("w:" + weight) { return false }
            if lang == "ko" && !(profiles[f.id]?.isKo ?? false) { return false }
            if lang == "la" && !(profiles[f.id]?.isLaOnly ?? false) { return false }
            if group && terms.isEmpty && !expanded.contains(f.familyKey) && rep[f.familyKey] != f.id { return false }
            return true
        }
    }
    var allNavs: [String] {
        ["all", "ko", "laOnly", "recent", "fav"] + Cat.all.map { "cat:" + $0.0 } + setNames.map { "set:" + $0 } + folders.map { "folder:" + shortHash($0.path) }
    }
    private func refreshCounts(base: [Bool]? = nil) {
        let b = base ?? baseFilter()
        var c: [String: Int] = [:]
        let navs = allNavs
        for (i, f) in fonts.enumerated() where b[i] { for n in navs where passNav(f, n) { c[n, default: 0] += 1 } }
        let termsR = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        c["rec:all"] = buildRecs(mode: "all", terms: termsR).count
        c["rec:taste"] = buildRecs(mode: "taste", terms: termsR).count
        counts = c
    }
    func applyFilters() {
        if nav.hasPrefix("set:") && user.sets[String(nav.dropFirst(4))] == nil { nav = "all"; return }
        let termsR = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        recs = nav.hasPrefix("rec:") ? buildRecs(mode: String(nav.dropFirst(4)), terms: termsR) : []
        let b = baseFilter()
        var vis: [FontItem] = []
        for (i, f) in fonts.enumerated() where b[i] && passNav(f, nav) { vis.append(f) }
        let w: (FontItem) -> Double = { [profiles] f in let p = profiles[f.id]; return p?.stem ?? p?.density.map { $0 * 0.55 } ?? 9 }
        let fav = Set(user.fav)
        vis.sort { a, b in
            switch sort {
            case "recent": if a.mtime != b.mtime { return a.mtime > b.mtime }
            case "weight": let wa = w(a), wb = w(b); if wa != wb { return wa < wb }
            case "fav": let fa = fav.contains(a.id), fb = fav.contains(b.id); if fa != fb { return fa }
            default: break
            }
            let c = a.family.localizedStandardCompare(b.family)
            if c != .orderedSame { return c == .orderedAscending }
            return a.style.localizedStandardCompare(b.style) == .orderedAscending
        }
        visible = vis
        visibleFamilies = Set(vis.map { $0.familyKey }).count
        refreshCounts(base: b)
    }

    /// 미리보기에 실제로 그릴 문구. 「영문 전용」이면 한글·한자·가나를 빼고 영문만.
    static let LATIN_FALLBACK = "The quick brown fox jumps over the lazy dog 0123456789"
    func shownSample(for item: FontItem) -> String {
        let base = sample.isEmpty ? item.full : sample
        // 영문 전용 토글이거나, 영문 전용 그룹이거나, 그 폰트에 한글이 없으면 영문만
        let noKo = profiles[item.id].map { $0.ko == 0 } ?? false
        return latinOnly(base, strip: lang == "la" || nav == "laOnly" || noKo)
    }
    func latinOnly(_ base: String, strip: Bool) -> String {
        guard strip else { return base }
        let stripped = String(base.unicodeScalars.filter { u in
            let v = u.value
            let cjk = (0xAC00...0xD7A3).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v) || (0xA960...0xA97F).contains(v) || (0xD7B0...0xD7FF).contains(v)
                || (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x3040...0x30FF).contains(v) || (0x3000...0x303F).contains(v) || (0xFF00...0xFFEF).contains(v)
            return !cjk
        }).replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let hasLetter = stripped.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        return hasLetter ? stripped : Store.LATIN_FALLBACK
    }

    var stripTitle: String {
        switch nav {
        case "all": return "전체 설치 폰트"
        case "ko": return "한글 폰트"
        case "laOnly": return "영문 전용 폰트"
        case "recent": return "최근 설치한 폰트"
        case "fav": return "즐겨찾기"
        case "rec:all": return "추천 폰트"
        case "rec:taste": return "내 취향 추천"
        default:
            if nav.hasPrefix("cat:") { return Cat.label[String(nav.dropFirst(4))] ?? "" }
            if nav.hasPrefix("set:") { return String(nav.dropFirst(4)) }
            if nav.hasPrefix("folder:") { return folderName(String(nav.dropFirst(7))) }
            return ""
        }
    }
    var stripDesc: String {
        if nav == "rec:all" { return "\(recs.count)개 · 설치하면 좋을 무료·구독 폰트 — 라이선스는 꼭 확인" + (lang == "ko" ? " · 한글만" : lang == "la" ? " · 영문만" : "") }
        if nav == "rec:taste" { return tasteCount < 3 ? "별(★)이나 세트에 폰트를 3개 이상 담으면 그 결로 골라드려요 (지금 \(tasteCount)개)" : "\(recs.count)개 · 별·세트에 담은 \(tasteCount)개의 생김새와 비슷한 순" }
        var d = "\(visible.count.formatted())개 · \(visibleFamilies.formatted())개 패밀리"
        if lang == "ko" { d += " · 한글 되는 것만" } else if lang == "la" { d += " · 영문 전용만" }
        if nav.hasPrefix("cat:") { d += " · 생김새로 자동 분류 — 틀린 건 분류 표시를 눌러 고치면 돼요" }
        else if nav.hasPrefix("set:") { d += " · 폰트 줄의 「+ 세트」로 넣고 빼요" }
        else if nav.hasPrefix("folder:") { d += " · " + folderPath(String(nav.dropFirst(7))) }
        else if nav == "recent" { d += " · 최근 30일 안에 설치된 파일" }
        return d
    }

    // MARK: 분석 (백그라운드)
    private func startAnalysis() {
        let todo = (visible + fonts).filter { profiles[$0.id] == nil }
        var seen = Set<String>(); let items = todo.filter { seen.insert($0.id).inserted }
        guard !items.isEmpty else { progress = ""; return }
        let total = items.count
        analysisTask = Task.detached(priority: .utility) { [weak self] in
            let gbm = Bitmap(Measure.GW, Measure.GH), sbm = Bitmap(Measure.SW, Measure.SH)
            var batch: [(String, Profile)] = []
            var done = 0
            for it in items {
                if Task.isCancelled { return }
                batch.append((it.id, Measure.analyze(it, gbm: gbm, sbm: sbm)))
                done += 1
                if batch.count >= 25 || done == total {
                    let b = batch; batch = []
                    let d = done
                    await MainActor.run { self?.absorb(b, done: d, total: total) }
                }
            }
        }
    }
    private func absorb(_ batch: [(String, Profile)], done: Int, total: Int) {
        for (id, p) in batch { profiles[id] = p; if let f = byID[id] { recomputeTag(f) } }
        progress = done < total ? "생김새 분석 중 \(done)/\(total)" : ""
        applyFilters()
        if done >= total {
            try? FileManager.default.createDirectory(at: CONF_DIR, withIntermediateDirectories: true)
            try? JSONEncoder().encode(profiles).write(to: PROFILES_JSON)
            let err = fonts.filter { profiles[$0.id]?.err == 1 }.count
            if err > 0 { progress = "불러오지 못한 폰트 \(err)개" }
        }
    }

    // MARK: 저장
    private func loadUser() {
        if let d = try? Data(contentsOf: USER_JSON), let u = try? JSONDecoder().decode(UserData.self, from: d) { user = u }
        if let s = user.state2 {
            if let v = s.sample { sample = v }
            if let v = s.size { size = max(9, min(180, v)) }
            if let v = s.weight { weight = v }
            if let v = s.sort { sort = v }
            if let v = s.group { group = v }
            if let v = s.fg { fg = Color(hex: v) }
            if let v = s.bg { bg = Color(hex: v) }
            if let v = s.nav { nav = v }
            if let v = s.lang { lang = v }
        }
    }
    func saveUserSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveUserNow()
        }
    }
    func saveUserNow() {
        var u = user
        u.state2 = UIState(sample: sample, size: size, q: "", weight: weight, sort: sort, group: group, fg: fg.hexString, bg: bg.hexString, nav: nav, lang: lang)
        try? FileManager.default.createDirectory(at: CONF_DIR, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        if let d = try? enc.encode(u) { try? d.write(to: USER_JSON, options: .atomic) }
    }

    // MARK: 잡동사니
    func showToast(_ s: String) {
        toast = s
        Task { try? await Task.sleep(nanoseconds: 1_700_000_000); if toast == s { toast = nil } }
    }
    func copy(_ s: String, _ msg: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string); showToast(msg)
    }
    func ask(_ title: String, _ message: String = "", initial: String = "") -> String? {
        let a = NSAlert(); a.messageText = title; a.informativeText = message
        a.addButton(withTitle: "확인"); a.addButton(withTitle: "취소")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); tf.stringValue = initial
        a.accessoryView = tf; a.window.initialFirstResponder = tf
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let s = tf.stringValue.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }
    func confirm(_ title: String, _ message: String = "") -> Bool {
        let a = NSAlert(); a.messageText = title; a.informativeText = message; a.alertStyle = .warning
        a.addButton(withTitle: "삭제"); a.addButton(withTitle: "취소")
        return a.runModal() == .alertFirstButtonReturn
    }
}
