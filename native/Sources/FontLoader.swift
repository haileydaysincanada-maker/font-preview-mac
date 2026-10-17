import Foundation
import CoreText

enum FontLoader {
    static let exts: Set<String> = ["ttf", "otf", "ttc", "woff", "woff2", "dfont"]

    static func attr(_ d: CTFontDescriptor, _ key: CFString) -> String? {
        CTFontDescriptorCopyAttribute(d, key) as? String
    }
    static func mtime(_ path: String) -> TimeInterval {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }
    static func source(_ path: String) -> FontItem.Source {
        if path.contains("CoreSync") { return .adobe }
        if path.hasPrefix("/System/") { return .system }
        return .user
    }

    /// 설치된 폰트 전부 (숨김 시스템 폰트 제외, PostScript 이름 중복 제거). 0.2초쯤.
    static func installed(excluding folderPaths: [String] = []) -> (fonts: [FontItem], hidden: Int, dup: Int) {
        let coll = CTFontCollectionCreateFromAvailableFonts(nil)
        let descs = CTFontCollectionCreateMatchingFontDescriptors(coll) as? [CTFontDescriptor] ?? []
        var out: [FontItem] = [], seen = Set<String>(), hidden = 0, dup = 0
        for d in descs {
            guard let ps = attr(d, kCTFontNameAttribute), !ps.isEmpty else { continue }
            let famAttr = attr(d, kCTFontFamilyNameAttribute) ?? ps
            if ps.hasPrefix(".") || famAttr.hasPrefix(".") { hidden += 1; continue }
            if seen.contains(ps) { dup += 1; continue }
            seen.insert(ps)
            let font = CTFontCreateWithFontDescriptor(d, 12, nil)
            let famKo = (CTFontCopyLocalizedName(font, kCTFontFamilyNameKey, nil) as String?) ?? famAttr
            let famEN = (CTFontCopyName(font, kCTFontFamilyNameKey) as String?) ?? famAttr
            let style = attr(d, kCTFontStyleNameAttribute) ?? "Regular"
            let full = (CTFontCopyLocalizedName(font, kCTFontFullNameKey, nil) as String?) ?? attr(d, kCTFontDisplayNameAttribute) ?? ps
            let url = CTFontDescriptorCopyAttribute(d, kCTFontURLAttribute) as? URL
            let path = url?.path ?? ""
            if folderPaths.contains(where: { path.hasPrefix($0 + "/") }) { continue }  // 폴더 모드로 이 프로세스에만 등록한 폰트는 설치 목록에 안 섞는다
            out.append(FontItem(id: ps, ps: ps, family: famKo, familyEN: famEN, style: style, full: full, path: path,
                                file: (path as NSString).lastPathComponent, source: source(path), mtime: mtime(path), folderID: nil, descriptor: d))
        }
        return (out, hidden, dup)
    }

    /// 폴더 안 폰트 파일들 (설치 안 함 — 이 프로세스에만 등록해서 미리보기)
    static func folder(_ dir: URL) -> [FontItem] {
        let fid = shortHash(dir.path)
        var files: [URL] = []
        if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let u as URL in e where exts.contains(u.pathExtension.lowercased()) { files.append(u) }
        }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        var out: [FontItem] = []
        for u in files {
            CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil)   // 이미 등록돼 있으면 에러 — 무시
            let descs = CTFontManagerCreateFontDescriptorsFromURL(u as CFURL) as? [CTFontDescriptor] ?? []
            let stem = u.deletingPathExtension().lastPathComponent
            for (i, d) in descs.enumerated() {
                let font = CTFontCreateWithFontDescriptor(d, 12, nil)
                let ps = attr(d, kCTFontNameAttribute) ?? stem
                let famKo = (CTFontCopyLocalizedName(font, kCTFontFamilyNameKey, nil) as String?) ?? attr(d, kCTFontFamilyNameAttribute) ?? stem
                let famEN = (CTFontCopyName(font, kCTFontFamilyNameKey) as String?) ?? famKo
                let id = i == 0 ? u.path : u.path + "#\(i)"
                out.append(FontItem(id: id, ps: ps, family: famKo, familyEN: famEN, style: attr(d, kCTFontStyleNameAttribute) ?? "Regular",
                                    full: (CTFontCopyLocalizedName(font, kCTFontFullNameKey, nil) as String?) ?? stem, path: u.path,
                                    file: u.lastPathComponent, source: .folder, mtime: mtime(u.path), folderID: fid, descriptor: d))
            }
            if descs.isEmpty {
                // 이름을 못 읽는 파일(woff2 등)은 파일명으로라도
                let d = CTFontDescriptorCreateWithAttributes([kCTFontURLAttribute: u] as CFDictionary)
                out.append(FontItem(id: u.path, ps: stem, family: stem, familyEN: stem, style: "Regular", full: stem, path: u.path,
                                    file: u.lastPathComponent, source: .folder, mtime: mtime(u.path), folderID: fid, descriptor: d))
            }
        }
        return out
    }
}
