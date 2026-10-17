import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum AppInfo {
    static let info = Bundle.main.infoDictionary ?? [:]
    static let version = info["CFBundleShortVersionString"] as? String ?? "?"
    static let build = info["CFBundleVersion"] as? String ?? "?"
    static let author = info["FVAuthor"] as? String ?? ""
    static let contact = info["FVContact"] as? String ?? ""
    static let builtAt = info["FVBuiltAt"] as? String ?? ""
    static let copyright = info["NSHumanReadableCopyright"] as? String ?? ""
    static var mailURL: URL? { contact.isEmpty ? nil : URL(string: "mailto:\(contact)?subject=" + ("[Font Preview v\(version) build \(build)] " + T("문의", "Inquiry")).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!) }
    static var line: String { T("폰트 미리보기", "Font Preview") + " v\(version) · " + T("빌드", "build") + " \(build)" + (builtAt.isEmpty ? "" : " (\(builtAt))") + (author.isEmpty ? "" : " · \(author)") }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        NavigationSplitView {
            SidebarView().navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 320)
        } detail: {
            DetailView()
        }
        .overlay(alignment: .bottom) {
            if let t = store.toast {
                Text(t).font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.black.opacity(0.85)).foregroundColor(.white).cornerRadius(8).padding(.bottom, 28)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.toast)
        .id(store.uiLang)   // 언어를 바꾸면 전체를 다시 그린다
    }
}

// MARK: - 사이드바

struct SidebarView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        List(selection: Binding(get: { Optional(store.nav) }, set: { if let v = $0 { store.nav = v } })) {
            Section(T("폰트", "Fonts")) {
                navRow("all", T("전체 설치 폰트", "All installed fonts")); navRow("ko", T("한글 폰트", "Korean fonts")); navRow("laOnly", T("영문 전용 폰트", "Latin-only fonts")); navRow("recent", T("최근 설치한 폰트", "Recently installed")); navRow("fav", "★ " + T("즐겨찾기", "Favorites"))
            }
            Section(T("추천", "Recommended")) {
                navRow("rec:all", T("추천 폰트 (미설치)", "Worth installing")); navRow("rec:taste", T("내 취향 추천", "For my taste"))
            }
            Section(T("자동 분류", "By look (auto)")) {
                ForEach(Cat.all, id: \.0) { k, _ in navRow("cat:" + k, Cat.name(k)) }
            }
            Section {
                if store.setNames.isEmpty {
                    Text(T("폰트 줄의 「+ 세트」로 담으면 여기 생겨요", "Add fonts with “+ Set” on a font row and they appear here")).font(.system(size: 11)).foregroundColor(.secondary)
                }
                ForEach(store.setNames, id: \.self) { n in
                    navRow("set:" + n, n).contextMenu {
                        Button(T("이름 바꾸기", "Rename")) { if let v = store.ask(T("세트 이름", "Set name"), initial: n) { store.renameSet(n, v) } }
                        Button(T("세트 삭제", "Delete set"), role: .destructive) { if store.confirm(T("「\(n)」 세트를 지울까요?", "Delete the set “\(n)”?"), T("폰트 파일은 지워지지 않아요.", "Font files are not deleted.")) { store.deleteSet(n) } }
                    }
                }
            } header: {
                HStack { Text(T("내 세트", "My sets")); Spacer(); Button { if let v = store.ask(T("새 세트 이름", "New set name")) { store.createSet(v) } } label: { Image(systemName: "plus") }.buttonStyle(.plain).help(T("새 세트", "New set")) }
            }
            Section {
                if store.folders.isEmpty {
                    Text(T("+ 를 누르거나 폰트 폴더를 여기 또는 앱 아이콘에 드롭하세요", "Press + or drop a font folder here or on the app icon")).font(.system(size: 11)).foregroundColor(.secondary)
                }
                ForEach(store.folders, id: \.path) { u in
                    let fid = shortHash(u.path)
                    navRow("folder:" + fid, u.lastPathComponent).help(u.path).contextMenu {
                        Button(T("Finder 에서 보기", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                        Button(T("목록에서 빼기", "Remove from list"), role: .destructive) { store.removeFolder(fid) }
                    }
                }
            } header: {
                HStack { Text(T("폴더 (설치 안 된 폰트)", "Folders (not installed)")); Spacer(); Button { store.pickFolder() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help(T("폴더 추가", "Add folder")) }
            }
        }
        .listStyle(.sidebar)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            for p in providers {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var url: URL? = nil
                    if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) } else if let u = item as? URL { url = u }
                    if let u = url { Task { @MainActor in store.addFolder(u) } }
                }
            }
            return true
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Button(T("폰트 다시 읽기", "Reload fonts")) { store.reloadFonts(); store.showToast(T("폰트 목록을 다시 읽었어요", "Font list reloaded")) }.frame(maxWidth: .infinity)
                Text(T("설치 폰트 \(store.installedCount.formatted())개", "\(store.installedCount.formatted()) installed fonts")
                     + (store.hiddenCount > 0 ? T("\n미리보기 못 하는 숨김 시스템 폰트 \(store.hiddenCount.formatted())개 제외", "\n\(store.hiddenCount.formatted()) hidden system fonts excluded") : "")
                     + (store.dupCount > 0 ? T(" · 중복 이름 \(store.dupCount)개 제외", " · \(store.dupCount) duplicate names excluded") : ""))
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(AppInfo.line).font(.system(size: 10)).foregroundColor(.secondary.opacity(0.8)).help(AppInfo.copyright)
                if let u = AppInfo.mailURL {
                    Link(destination: u) { Label(T("문의", "Contact") + " · \(AppInfo.contact)", systemImage: "envelope").font(.system(size: 10)) }.help(T("클릭하면 메일 앱이 열려요", "Opens your mail app"))
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
        }
    }
    func navRow(_ id: String, _ label: String) -> some View {
        HStack {
            Text(label).lineLimit(1)
            Spacer()
            Text((store.counts[id] ?? 0).formatted()).font(.system(size: 11)).foregroundColor(.secondary).monospacedDigit()
        }.tag(id)
    }
}

// MARK: - 본문

struct DetailView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(store.stripTitle).font(.system(size: 14, weight: .bold))
                Text(store.stripDesc).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
                Spacer()
                if store.nav.hasPrefix("rec:") { Toggle(T("설치된 것도 보기", "Show installed too"), isOn: $store.showInstalledRecs).toggleStyle(.checkbox).font(.system(size: 12)) }
                Picker("", selection: $store.lang) { Text(T("전체", "All")).tag(""); Text(T("한글", "Korean")).tag("ko"); Text(T("영문 전용", "Latin only")).tag("la") }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220).help(T("지금 보는 목록에서 한글 되는 폰트만 / 영문 전용만 거르기", "Filter the current list to Korean-capable or Latin-only fonts"))
            }.padding(.horizontal, 16).padding(.vertical, 9).background(Color(nsColor: .windowBackgroundColor))
            Divider()
            if store.nav.hasPrefix("rec:") { RecommendList() } else { FontList() }
        }
    }
}

struct TopBar: View {
    @EnvironmentObject var store: Store
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                TextField(T("미리보기 문구", "Sample text"), text: $store.sample).textFieldStyle(.roundedBorder).font(.system(size: 16)).controlSize(.large)
                Menu(T("문구 목록", "Phrases")) {
                    ForEach(store.phrases, id: \.self) { p in Button(p) { store.sample = p } }
                    Divider()
                    Button(T("폰트 이름으로", "Use font names")) { store.sample = "" }
                }.frame(width: 118)
                Button(store.sampleSaved ? T("문구 삭제", "Forget") : T("문구 저장", "Save phrase")) { store.togglePhraseSaved() }
            }
            HStack(spacing: 10) {
                Text(T("크기", "Size")).foregroundColor(.secondary)
                Slider(value: $store.size, in: 9...180, step: 1).frame(width: 130)
                Text("\(Int(store.size))px").foregroundColor(.secondary).monospacedDigit().frame(width: 44, alignment: .leading)
                TextField(T("폰트 이름 검색 ( / )", "Search fonts ( / )"), text: $store.query).textFieldStyle(.roundedBorder).frame(maxWidth: 260).focused($searchFocused)
                Picker("", selection: $store.weight) {
                    Text(T("굵기 전체", "Any weight")).tag(""); ForEach(Cat.weights, id: \.0) { k, _ in Text(Cat.name("w:" + k)).tag(k) }
                }.frame(width: 118).labelsHidden()
                Picker("", selection: $store.sort) {
                    Text(T("이름순", "By name")).tag("name"); Text(T("최근 설치순", "Recently installed")).tag("recent"); Text(T("얇은 → 굵은", "Thin → bold")).tag("weight"); Text(T("즐겨찾기 먼저", "Favorites first")).tag("fav")
                }.frame(width: 150).labelsHidden()
                Spacer()
            }
            HStack(spacing: 12) {
                Toggle(T("패밀리 묶기", "Group families"), isOn: $store.group).toggleStyle(.checkbox)
                HStack(spacing: 6) { Text(T("글자", "Text")).foregroundColor(.secondary); ColorPicker("", selection: $store.fg, supportsOpacity: false).labelsHidden() }
                HStack(spacing: 6) { Text(T("배경", "Background")).foregroundColor(.secondary); ColorPicker("", selection: $store.bg, supportsOpacity: false).labelsHidden() }
                Button { let f = store.fg; store.fg = store.bg; store.bg = f } label: { Image(systemName: "arrow.left.arrow.right") }.help(T("글자/배경 색 바꾸기", "Swap text/background colors"))
                Spacer()
                Text(store.progress).font(.system(size: 11)).foregroundColor(.secondary)
                Menu {
                    ForEach(UILang.allCases, id: \.self) { l in Button(action: { store.uiLang = l }) { HStack { Text(l.title); if store.uiLang == l { Image(systemName: "checkmark") } } } }
                } label: { Label(store.uiLang.title, systemImage: "globe") }.menuStyle(.borderlessButton).fixedSize().help(T("화면 언어", "Interface language"))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(Button("") { searchFocused = true }.keyboardShortcut("/", modifiers: []).opacity(0).frame(width: 0, height: 0))
    }
}

struct FontList: View {
    @EnvironmentObject var store: Store
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.visible) { item in
                    FontRow(item: item).id(item.id)
                    Divider()
                }
                if store.visible.isEmpty {
                    Text(T("조건에 맞는 폰트가 없습니다", "No fonts match")).foregroundColor(.secondary).padding(60)
                }
            }
        }
        .background(store.bg)
    }
}

struct FontRow: View {
    @EnvironmentObject var store: Store
    let item: FontItem
    @State private var editing = false
    var body: some View {
        let n = store.familyCount(item)
        let p = store.profiles[item.id]
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(item.family).font(.system(size: 13, weight: .bold)).lineLimit(1)
                    .onTapGesture { store.copy(item.ps, T("PostScript 이름 복사됨: ", "Copied PostScript name: ") + item.ps) }.help(T("클릭하면 PostScript 이름 복사: \(item.ps)", "Click to copy PostScript name: \(item.ps)"))
                if item.familyEN != item.family { Text(item.familyEN).foregroundColor(.secondary).lineLimit(1) }
                Text(item.style).foregroundColor(.secondary).lineLimit(1)
                if p == nil {
                    chip(T("분석 전", "not analyzed yet"), ghost: true)
                } else if p?.err == 1 {
                    chip(T("불러오지 못함", "could not load"), warn: true).help(T("CoreText 가 이 폰트를 못 불러왔어요 (대체 폰트로 보임)", "CoreText could not load this font (shown with a fallback)"))
                } else {
                    let s = store.tagSummary(item)
                    Button { editing.toggle() } label: { chip(s.isEmpty ? T("분류 없음", "unclassified") : s, ghost: s.isEmpty, manual: store.isManual(item)) }
                        .buttonStyle(.plain).help(T("클릭하면 분류 고치기", "Click to fix the classification"))
                        .popover(isPresented: $editing, arrowEdge: .bottom) { TagEditor(item: item) }
                }
                if item.source == .folder { Text(item.sourceLabel).font(.system(size: 11)).foregroundColor(.secondary) }
                Text(item.file).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .leading)
                    .onTapGesture { store.copy(item.path, T("경로 복사됨", "Path copied")) }.help(item.path + T(" (클릭하면 경로 복사)", " (click to copy path)"))
                if n > 1 {
                    Button(store.isExpanded(item) ? T("접기", "Collapse") : T("\(n)개 스타일", "\(n) styles")) { store.toggleExpand(item) }.buttonStyle(.plain)
                        .font(.system(size: 11)).padding(.horizontal, 7).padding(.vertical, 1).background(Color.primary.opacity(0.07)).cornerRadius(9)
                }
                Spacer(minLength: 4)
                Menu(T("+ 세트", "+ Set")) {
                    ForEach(store.setNames, id: \.self) { s in
                        Toggle(s, isOn: Binding(get: { store.inSet(s, item) }, set: { store.setMembership(s, item, $0) }))
                    }
                    if !store.setNames.isEmpty { Divider() }
                    Button(T("새 세트 만들어 담기…", "New set with this font…")) { if let v = store.ask(T("새 세트 이름", "New set name")) { store.createSet(v, adding: item); store.showToast(T("「\(v)」에 담았어요", "Added to “\(v)”")) } }
                }.menuStyle(.borderlessButton).fixedSize().foregroundColor(.secondary)
                Button { store.toggleFav(item) } label: {
                    Image(systemName: "star.fill").font(.system(size: 14)).foregroundColor(store.isFav(item) ? Color(red: 0.94, green: 0.71, blue: 0) : Color.primary.opacity(0.18))
                }.buttonStyle(.plain).help(T("즐겨찾기", "Favorite"))
            }
            .foregroundColor(Color(nsColor: .labelColor))
            Text(store.shownSample(for: item))
                .font(store.fontCache.font(item, store.size))
                .foregroundColor(store.fg)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
    func chip(_ s: String, ghost: Bool = false, warn: Bool = false, manual: Bool = false) -> some View {
        Text(s).font(.system(size: 11)).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundColor(warn ? .orange : ghost ? .secondary : Color(nsColor: .labelColor))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(manual ? Color.accentColor : warn ? Color.orange : Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: (ghost || manual) ? [3, 2] : [])))
    }
}

struct TagEditor: View {
    @EnvironmentObject var store: Store
    let item: FontItem
    var body: some View {
        let t = store.tagsOf(item)
        VStack(alignment: .leading, spacing: 10) {
            Text(item.family + "  " + item.style).font(.system(size: 12, weight: .bold))
            Text(T("분류 (여러 개 가능)", "Categories (pick any)")).font(.system(size: 11)).foregroundColor(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(Cat.all, id: \.0) { k, _ in toggleChip(Cat.name(k), on: t.contains(k)) { store.toggleTag(item, k) } }
            }
            Text(T("굵기", "Weight")).font(.system(size: 11)).foregroundColor(.secondary)
            HStack(spacing: 6) { ForEach(Cat.weights, id: \.0) { k, _ in toggleChip(Cat.name("w:" + k), on: t.contains("w:" + k)) { store.toggleTag(item, "w:" + k) } } }
            HStack {
                if store.isManual(item) { Button(T("자동으로 되돌리기", "Reset to automatic")) { store.resetManual(item) } }
                Spacer()
                Text(T("점선 테두리 = 손으로 고친 것", "Dashed outline = edited by hand")).font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
        .padding(14).frame(width: 400)
    }
    func toggleChip(_ l: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(l).font(.system(size: 11)).padding(.horizontal, 9).padding(.vertical, 3)
                .background(on ? Color(nsColor: .labelColor) : Color.clear)
                .foregroundColor(on ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .labelColor))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(on ? 0 : 0.25)))
                .cornerRadius(11)
        }.buttonStyle(.plain)
    }
}

// MARK: - 추천

struct RecommendList: View {
    @EnvironmentObject var store: Store
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.recs) { r in RecommendRow(rec: r); Divider() }
                if store.recs.isEmpty {
                    Text(store.nav == "rec:taste" && store.tasteCount < 3
                         ? T("아직 취향 정보가 부족해요.\n폰트 줄의 ★ 을 누르거나 「+ 세트」에 담아 주세요.", "Not enough taste data yet.\nStar a few fonts or add them to a set.")
                         : T("조건에 맞는 추천이 없습니다", "No recommendations match"))
                        .multilineTextAlignment(.center).foregroundColor(.secondary).padding(60)
                }
            }
        }
        .background(store.bg)
    }
}

struct RecommendRow: View {
    @EnvironmentObject var store: Store
    let rec: Recommendation
    var body: some View {
        let c = rec.item
        let installed = store.isInstalled(c)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(c.displayName).font(.system(size: 14, weight: .bold))
                if let sub = c.displaySub { Text(sub).foregroundColor(.secondary) }
                pill(c.sourceLabel, tint: c.source == "adobe" ? .red : c.source == "google" ? .blue : .secondary)
                pill(licenseText(c.license), tint: .secondary)
                if installed { pill(T("설치됨 ✓", "Installed ✓"), tint: .green) }
                Spacer()
                Button(c.source == "adobe" ? T("활성화 페이지", "Activate on Adobe") : T("페이지 열기", "Open page")) { store.openPage(c) }
                if c.canInstall && !installed {
                    if store.installing.contains(c.id) { ProgressView().controlSize(.small).frame(width: 60) }
                    else { Button(T("설치", "Install")) { store.install(c) }.buttonStyle(.borderedProminent) }
                }
            }
            Text(c.displayDesc).font(.system(size: 12))
            Group {
                if let f = store.previewFont(c) {
                    Text(store.shownSample(forCatalog: c)).font(f).foregroundColor(store.fg).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                } else if store.previewState(c).loading {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(T("미리보기 불러오는 중…", "Loading preview…")).font(.system(size: 11)).foregroundColor(.secondary) }.frame(height: CGFloat(store.size) * 1.2)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(store.shownSample(forCatalog: c)).font(.system(size: CGFloat(store.size))).foregroundColor(store.fg.opacity(0.25)).lineLimit(1)
                        Text(c.previewable ? T("미리보기를 못 받았어요 — 「페이지 열기」에서 확인", "Preview unavailable — see “Open page”") : T("실제 모양은 「페이지 열기」에서 확인 (파일 직접 제공 안 함)", "See the real shape via “Open page” (no file served directly)")).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { store.loadPreview(c) }
            .onChange(of: store.previewText) { _ in store.loadPreview(c) }
            HStack(spacing: 6) {
                ForEach(c.tags, id: \.self) { t in Text(Cat.name(t)).font(.system(size: 11)).padding(.horizontal, 7).padding(.vertical, 1).background(Color.primary.opacity(0.07)).cornerRadius(9) }
                Text(c.lang == "ko" ? T("한글", "Korean") : T("영문", "Latin")).font(.system(size: 11)).foregroundColor(.secondary)
                if !rec.reason.isEmpty { Text("· " + rec.reason).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
    func pill(_ s: String, tint: Color) -> some View {
        Text(s).font(.system(size: 10, weight: .semibold)).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundColor(tint).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(0.6)))
    }
}
