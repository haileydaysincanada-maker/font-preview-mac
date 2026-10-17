import Foundation
import CoreText

// MARK: - 추천 카탈로그 (native/catalog.json → 앱 Resources)

struct CatalogInstall: Codable {
    let kind: String          // google / github_release
    let dir: String?          // google: ofl / apache / ufl
    let slug: String?         // google
    let repo: String?         // github_release
    let asset: String?        // github_release: asset 이름 정규식
}

struct CatalogItem: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let nameEN: String
    let lang: String          // ko / la
    let source: String        // google / github / link / adobe
    let page: String
    let license: String
    let tags: [String]
    let desc: String
    let match: [String]
    let install: CatalogInstall?
    let preview: String?      // 미리보기용 단일 파일 직링크 (GitHub 배포분)

    var previewable: Bool { source == "google" || preview != nil }

    var sourceLabel: String {
        switch source {
        case "google": return "Google Fonts"
        case "github": return "GitHub 배포"
        case "adobe": return "Adobe Fonts"
        default: return "배포처"
        }
    }
    var canInstall: Bool { install != nil }
    /// 분류 태그 → 앱 태그 이름 (thin/bold 는 굵기 태그로)
    var normTags: [String] { tags.map { ["thin", "bold"].contains($0) ? "w:" + $0 : $0 } }
    static func == (a: CatalogItem, b: CatalogItem) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct Catalog: Codable { let version: Int; let items: [CatalogItem] }

enum CatalogLoader {
    static func load() -> [CatalogItem] {
        let candidates = [
            CONF_DIR.appendingPathComponent("catalog.json"),                  // 사용자가 덮어쓴 것이 있으면 우선
            Bundle.main.url(forResource: "catalog", withExtension: "json"),
        ].compactMap { $0 }
        for u in candidates {
            if let d = try? Data(contentsOf: u), let c = try? JSONDecoder().decode(Catalog.self, from: d) { return c.items }
        }
        return []
    }
}

// MARK: - 설치 (Google Fonts = google/fonts 레포 ttf, GitHub 릴리스 = 최신 zip)

enum InstallError: LocalizedError {
    case http(Int, String), noAsset, noFiles, unzip
    var errorDescription: String? {
        switch self {
        case .http(let c, let u): return "내려받기 실패 (\(c)) \(u)"
        case .noAsset: return "릴리스에서 설치 파일을 못 찾았어요"
        case .noFiles: return "압축 안에 폰트 파일(otf/ttf)이 없어요"
        case .unzip: return "압축 풀기 실패"
        }
    }
}

enum Installer {
    static let fontsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts")
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpAdditionalHeaders = ["User-Agent": "FontViewer/1.0 (macOS)", "Accept": "*/*"]
        c.timeoutIntervalForRequest = 60
        return URLSession(configuration: c)
    }()

    static func fetch(_ url: URL) async throws -> Data {
        let (d, r) = try await session.data(from: url)
        let code = (r as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw InstallError.http(code, url.lastPathComponent) }
        return d
    }

    /// 설치한 파일 URL 목록을 돌려준다.
    static func install(_ item: CatalogItem) async throws -> [URL] {
        guard let inst = item.install else { return [] }
        let dest = fontsDir.appendingPathComponent(item.nameEN.replacingOccurrences(of: "/", with: "-"))
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var written: [URL] = []
        switch inst.kind {
        case "google":
            let api = URL(string: "https://api.github.com/repos/google/fonts/contents/\(inst.dir ?? "ofl")/\(inst.slug ?? "")")!
            let listData = try await fetch(api)
            let list = try JSONSerialization.jsonObject(with: listData) as? [[String: Any]] ?? []
            for e in list {
                guard let name = e["name"] as? String, let dl = e["download_url"] as? String, let u = URL(string: dl) else { continue }
                let ext = (name as NSString).pathExtension.lowercased()
                guard ext == "ttf" || ext == "otf" else { continue }
                let out = dest.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: out.path) { try (try await fetch(u)).write(to: out) }
                written.append(out)
            }
        case "github_release":
            let api = URL(string: "https://api.github.com/repos/\(inst.repo ?? "")/releases/latest")!
            let relData = try await fetch(api)
            let rel = try JSONSerialization.jsonObject(with: relData) as? [String: Any] ?? [:]
            let rx = try NSRegularExpression(pattern: inst.asset ?? ".*")
            guard let assets = rel["assets"] as? [[String: Any]],
                  let a = assets.first(where: { ($0["name"] as? String).map { rx.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil } ?? false }),
                  let dl = a["browser_download_url"] as? String, let u = URL(string: dl) else { throw InstallError.noAsset }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fontviewer-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let zip = tmp.appendingPathComponent("a.zip")
            try (try await fetch(u)).write(to: zip)
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-xk", zip.path, tmp.appendingPathComponent("x").path]
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw InstallError.unzip }
            var otf: [URL] = [], ttf: [URL] = []
            let all = (FileManager.default.enumerator(at: tmp.appendingPathComponent("x"), includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
            do {
                for f in all {
                    let path = f.path.lowercased()
                    if path.contains("/web/") || path.contains("woff") || path.contains("__macosx") || path.contains("variable") { continue }
                    if f.pathExtension.lowercased() == "otf" { otf.append(f) } else if f.pathExtension.lowercased() == "ttf" { ttf.append(f) }
                }
            }
            let files = otf.isEmpty ? ttf : otf
            guard !files.isEmpty else { throw InstallError.noFiles }
            for f in files {
                let out = dest.appendingPathComponent(f.lastPathComponent)
                if FileManager.default.fileExists(atPath: out.path) { try? FileManager.default.removeItem(at: out) }
                try FileManager.default.copyItem(at: f, to: out)
                written.append(out)
            }
        default: break
        }
        for u in written { CTFontManagerRegisterFontsForURL(u as CFURL, .user, nil) }  // 이미 등록돼 있으면 에러 — 무시
        return written
    }
}

// MARK: - 미리보기 (설치 안 하고 임시 파일로 그린다)

enum PreviewLoader {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/fontviewer/preview")
    static func safeName(_ id: String) -> String { id.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined() }

    /// 미리보기 파일을 캐시에 확보하고 CGFont 로 돌려준다 (어디에도 등록하지 않음 → 설치 목록에 안 섞임)
    /// Google 은 문구(text)에 든 글자만 담은 서브셋을 받는다 — 전체 파일은 한글이 빠진 영문 축소판이 와서 속는다.
    static func font(for item: CatalogItem, text: String) async throws -> CGFont {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = item.source == "google" ? dir.appendingPathComponent(safeName(item.id) + "_" + shortHash(text)) : dir.appendingPathComponent(safeName(item.id))
        var file: URL? = ["ttf", "otf"].map { base.appendingPathExtension($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
        if file == nil {
            if let p = item.preview, let u = URL(string: p) {
                let out = base.appendingPathExtension(u.pathExtension.isEmpty ? "otf" : u.pathExtension)
                try (try await Installer.fetch(u)).write(to: out); file = out
            } else if item.source == "google" {
                // 브라우저가 아닌 UA 로 CSS 를 받으면 TrueType 직링크가 온다
                var cs = CharacterSet.urlQueryAllowed; cs.remove(charactersIn: "&+=#")
                let q = text.addingPercentEncoding(withAllowedCharacters: cs) ?? ""
                let css = URL(string: "https://fonts.googleapis.com/css?family=" + item.nameEN.replacingOccurrences(of: " ", with: "+") + "&text=" + q)!
                let text = String(decoding: try await Installer.fetch(css), as: UTF8.self)
                let rx = try NSRegularExpression(pattern: #"url\((https://fonts\.gstatic\.com/[^)]+)\)"#)  // text= 서브셋은 .ttf 확장자 없이 온다
                guard let m = rx.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let r = Range(m.range(at: 1), in: text), let u = URL(string: String(text[r])) else { throw InstallError.noFiles }
                let out = base.appendingPathExtension("ttf")
                try (try await Installer.fetch(u)).write(to: out); file = out
            }
        }
        guard let f = file, let prov = CGDataProvider(url: f as CFURL), let cg = CGFont(prov) else { throw InstallError.noFiles }
        return cg
    }
}

// MARK: - 취향 점수

struct Recommendation: Identifiable {
    let item: CatalogItem
    let score: Double
    let reason: String
    var id: String { item.id }
}
