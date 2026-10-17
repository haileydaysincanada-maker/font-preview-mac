#!/usr/bin/env python3
"""catalog_src.py 를 읽어 링크·슬러그를 전부 실제로 확인한 뒤 catalog.json 을 쓴다.
확인 못 한 항목은 넣지 않고 끝에 보고한다 (URL 환각 금지).
"""
import json, os, re, sys, urllib.request, urllib.error, urllib.parse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import catalog_src as S

UA = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/128 Safari/537.36", "Accept": "*/*"}
TOKEN = os.environ.get("GITHUB_TOKEN")

def get(url, json_=False, timeout=20):
    h = dict(UA)
    if json_ and TOKEN: h["Authorization"] = "Bearer " + TOKEN
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = r.read()
        return (r.status, json.loads(data) if json_ else data)

def norm(url):
    # 한글이 든 URL 은 퍼센트 인코딩해서 검사·저장
    return urllib.parse.quote(url, safe=":/?=&%+#@")

def ok(url):
    url = norm(url)
    try:
        st, _ = get(url)
        return st < 400
    except urllib.error.HTTPError as e:
        return e.code < 400
    except Exception:
        return False

report = {"dropped": [], "fallback": []}
items = []

# ── Google Fonts: google/fonts 레포의 ofl / apache / ufl 폴더 목록으로 슬러그 검증
dirs = {}
root = get("https://api.github.com/repos/google/fonts/git/trees/main", json_=True)[1]
for d in ("ofl", "apache", "ufl"):
    sha = next(t["sha"] for t in root["tree"] if t["path"] == d)
    tree = get(f"https://api.github.com/repos/google/fonts/git/trees/{sha}", json_=True)[1]
    for t in tree["tree"]:
        if t["type"] == "tree":
            dirs.setdefault(t["path"], d)
print("google dirs:", len(dirs))

def google(slug, name, name_en, tags, desc, lang):
    if slug not in dirs:
        report["dropped"].append(("google", slug)); return
    items.append({
        "id": "g:" + slug, "name": name, "nameEN": name_en, "lang": lang, "source": "google",
        "page": "https://fonts.google.com/specimen/" + urllib.parse.quote(name_en.replace(" ", "+"), safe="+"),
        "license": "SIL OFL (상업용 무료)" if dirs[slug] == "ofl" else ("Apache 2.0 (상업용 무료)" if dirs[slug] == "apache" else "Ubuntu Font License"),
        "tags": tags, "desc": desc, "match": [name_en],
        "install": {"kind": "google", "dir": dirs[slug], "slug": slug},
    })

for slug, name, name_en, tags, desc in S.KO_GOOGLE:
    if name is None: continue
    google(slug, name, name_en, tags, desc, "ko")
for slug, name_en, tags, desc in S.LA_GOOGLE:
    google(slug, name_en, name_en, tags, desc, "la")

# ── GitHub 릴리스
for repo, rx, name, name_en, tags, desc, page, lic, prev in S.KO_GITHUB:
    try:
        rel = get(f"https://api.github.com/repos/{repo}/releases/latest", json_=True)[1]
        assets = [a["name"] for a in rel.get("assets", [])]
        hit = [a for a in assets if re.search(rx, a)]
        if not hit:
            report["dropped"].append(("github-no-asset", repo, assets)); continue
        if not ok(page):
            report["fallback"].append(("page", page)); page = f"https://github.com/{repo}"
        items.append({"id": "gh:" + repo, "name": name, "nameEN": name_en, "lang": "ko", "source": "github", "page": page,
                      "license": lic, "tags": tags, "desc": desc + f" (최신 릴리스 {rel.get('tag_name','')})", "match": [name_en],
                      "install": {"kind": "github_release", "repo": repo, "asset": rx},
                      "preview": prev if ok(prev) else None})
        if not ok(prev): report["fallback"].append(("preview-missing", prev))
        print("release ok", repo, rel.get("tag_name"), hit[0])
    except Exception as e:
        report["dropped"].append(("github", repo, str(e)))

# ── 링크만 (열리는지 확인, 안 열리면 눈누 검색으로)
MATCH = {
    "Cafe24 Fonts": ["Cafe24"], "BM Fonts": ["BM ", "BMJUA", "BMDoHyeon", "BMHANNA", "BMEULJIRO", "배달의민족"], "S-Core Dream": ["S-Core", "SCDream", "에스코어"],
    "Gmarket Sans": ["Gmarket"], "Hakgyoansim": ["Hakgyoansim", "학교안심"], "Gangwon Edu": ["GangwonEdu", "강원교육"], "Paperlogy": ["Paperlogy", "페이퍼로지"],
    "Freesentation": ["Freesentation"], "Onglip": ["Ownglyph", "온글잎"], "Jalnan": ["Jalnan", "잘난"], "Tmon Monsori": ["Tmon", "몬소리"], "NEXON Lv2 Gothic": ["NEXON", "넥슨"],
    "CookieRun": ["CookieRun", "쿠키런"], "Mapo Fonts": ["Mapo", "마포"], "Yangjin": ["Yangjin", "양진"], "Aggro": ["Aggro", "어그로"], "The Jamsil": ["Jamsil", "잠실"],
    "Binggrae": ["Binggrae", "빙그레"], "Chosun Ilbo Myungjo": ["Chosun", "조선일보"], "KOTRA Hope": ["KOTRA", "코트라"], "Subak Hwa": ["SangSang", "상상토끼"], "Noonnu Popular": [],
}
for name, name_en, url, lic, tags, desc in S.KO_LINK:
    u = norm(url)
    if not ok(u):
        u2 = norm(f"https://noonnu.cc/index?search={name.split(' (')[0]}")
        if not ok(u2):
            report["dropped"].append(("link", url)); continue
        report["fallback"].append(("link", url, u2)); u = u2
    items.append({"id": "l:" + name_en, "name": name, "nameEN": name_en, "lang": "ko", "source": "link", "page": u,
                  "license": lic, "tags": tags, "desc": desc, "match": MATCH.get(name_en, [name_en]), "install": None})

# ── Adobe Fonts
adobe_ok = ok("https://fonts.adobe.com/fonts/proxima-nova")
print("adobe reachable:", adobe_ok)
for slug, name, tags, desc in S.ADOBE:
    page = f"https://fonts.adobe.com/fonts/{slug}"
    if adobe_ok and not ok(page):
        report["fallback"].append(("adobe", slug)); page = "https://fonts.adobe.com/search?query=" + urllib.parse.quote(name)
    elif not adobe_ok:
        page = "https://fonts.adobe.com/search?query=" + urllib.parse.quote(name)
    lang = "ko" if "Korean" in name else "la"
    m = name.split(" (")[0]
    items.append({"id": "a:" + slug, "name": name, "nameEN": name, "lang": lang, "source": "adobe", "page": page,
                  "license": "Adobe Fonts (Creative Cloud 구독에 포함, 상업용 가능)", "tags": tags, "desc": desc,
                  "match": [m, name.split("(")[-1].rstrip(")") if "(" in name else m], "install": None})

missing = [i["nameEN"] for i in items if i["nameEN"] not in S.DESC_EN]
for i in items:
    i["descEN"] = S.DESC_EN.get(i["nameEN"])
print("descEN missing:", missing)
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "catalog.json")
json.dump({"version": 1, "items": items}, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(f"\n✅ {len(items)}개 → {out}")
print("dropped:", json.dumps(report["dropped"], ensure_ascii=False))
print("fallback:", json.dumps(report["fallback"], ensure_ascii=False))
