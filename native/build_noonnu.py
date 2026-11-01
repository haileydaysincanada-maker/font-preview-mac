#!/usr/bin/env python3
"""눈누(noonnu.cc) 전체 폰트 목록 → native/noonnu.json

- 목록(/index?sort=recent&page=N): 카드마다 이름·제작사·굵기 수·대표 웹폰트(@font-face)·썸네일·상세 페이지 id
- 상세(/font_page/N): 굵기별 웹폰트 URL 전부, 라이선스 요약표(인쇄·웹사이트·포장지·영상·임베딩·BI/CI·OFL 허용 여부), 배포처 다운로드 링크, 라이선스 본문 첫 문장
- 눈누는 서버 렌더라 curl 로 받힌다(브라우저 UA 필요). 폰트 파일은 jsDelivr CDN(woff/woff2) — 앱이 미리보기에 그대로 쓴다.
사용: python3 build_noonnu.py [--limit N]   → noonnu.json (앱 번들 + build_catalog.py 가 합친다)
"""
import re, json, sys, time, html, concurrent.futures as cf, urllib.request, pathlib

HERE = pathlib.Path(__file__).resolve().parent
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
LIMIT = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else 0

def get(url, tries=3):
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Language": "ko"})
            with urllib.request.urlopen(req, timeout=30) as r: return r.read().decode("utf-8", "replace")
        except Exception as e:
            if i == tries - 1: print("  ! fail", url, e, file=sys.stderr); return ""
            time.sleep(1.5 * (i + 1))

def strip(t):
    t = re.sub(r"<style>.*?</style>", "", t, flags=re.S); t = re.sub(r"<script.*?</script>", "", t, flags=re.S); t = re.sub(r"<svg.*?</svg>", "", t, flags=re.S)
    t = re.sub(r"<[^>]+>", "|", t); t = html.unescape(t); t = re.sub(r"\s+", " ", t); return re.sub(r"(\|\s*)+", "|", t)

# ── 상세 ──
USES = ["인쇄", "웹사이트", "포장지", "영상", "임베딩", "BI/CI", "OFL"]
def detail(it):
    h = get(it["page"])
    if not h: return it
    urls = []
    for fam, u in re.findall(r"font-family:\s*'([^']+)';\s*src:\s*url\('([^']+)'\)", h):
        if u not in [x["url"] for x in urls]: urls.append({"family": fam, "url": u})
    it["files"] = urls
    if not it["webfont"] and urls: it["webfont"] = urls[0]["url"]; it["family"] = urls[0]["family"]
    dl = re.findall(r'href="([^"]+\?ref=noonnu\.cc[^"]*)"', h)
    it["download"] = html.unescape(dl[0]) if dl else ""
    txt = strip(h)
    i = txt.find("라이선스 요약표")
    uses = {}
    if i >= 0:
        seg = txt[i:i + 1500].split("|")
        for k, cell in enumerate(seg):
            if cell.strip() in USES and k + 2 < len(seg):
                uses[cell.strip()] = "허용" if "사용 가능" in seg[k + 2] or "허용" in seg[k + 2] else seg[k + 2].strip()[:12]
    it["uses"] = uses
    j = txt.find("라이선스 본문")
    it["license"] = txt[j + 7:j + 300].strip("| ").split("|")[0][:140] if j >= 0 else ""
    return it


# ── --fill: 기존 noonnu.json 에서 상세(uses) 가 비어 있는 항목만 다시 받는다 (수집 중 실패분 보충, 동시 4)
if "--fill" in sys.argv:
    db = json.loads((HERE / "noonnu.json").read_text())
    todo = [i for i in db["items"] if not i.get("uses")]
    print(f"fill: {len(todo)} items", file=sys.stderr)
    def detail_safe(it):
        try: return detail(it)
        except Exception as e: print("  ! detail", it["id"], e, file=sys.stderr); return it
    with cf.ThreadPoolExecutor(4) as ex:
        for n, it in enumerate(ex.map(detail_safe, todo), 1):
            if n % 50 == 0: print(f"fill {n}/{len(todo)}", file=sys.stderr)
    for it in db["items"]: it["format"] = "woff2" if it["webfont"].endswith(".woff2") else ("woff" if it["webfont"].endswith(".woff") else pathlib.Path(it["webfont"]).suffix.lstrip(".") or "")
    db["fetched"] = time.strftime("%Y-%m-%d")
    (HERE / "noonnu.json").write_text(json.dumps(db, ensure_ascii=False, indent=1))
    print("fill done; still missing uses:", sum(1 for i in db["items"] if not i.get("uses")), file=sys.stderr)
    sys.exit(0)

# ── 목록 ──
items, seen = [], set()
page = 1
while True:
    h = get(f"https://noonnu.cc/index?sort=recent&page={page}")
    cards = h.split('<div class="min-w-[300px] h-[300px]')[1:]
    if not cards: break
    for c in cards:
        m = re.search(r'href="/font_page/(\d+)"', c)
        if not m: continue
        pid = m.group(1)
        if pid in seen: continue
        seen.add(pid)
        ff = re.search(r"font-family:\s*'([^']+)';\s*src:\s*url\('([^']+)'\)", c)
        name = re.search(r'<img[^>]+alt="([^"]*)"', c)
        thumb = re.search(r'<img[^>]+src="([^"]+)"', c)
        txt = strip(c).split("|")
        txt = [x.strip() for x in txt if x.strip()]
        maker = txt[1] if len(txt) > 1 else ""
        variants = next((x for x in txt if "굵기" in x), "")
        items.append({"id": "nn:" + pid, "page": f"https://noonnu.cc/font_page/{pid}", "name": html.unescape(name.group(1)) if name else (ff.group(1) if ff else pid),
                      "family": ff.group(1) if ff else "", "webfont": ff.group(2) if ff else "", "thumb": thumb.group(1) if thumb else "",
                      "maker": maker, "variants": variants})
    print(f"page {page}: {len(cards)} cards, total {len(items)}", file=sys.stderr)
    page += 1
    if LIMIT and len(items) >= LIMIT: items = items[:LIMIT]; break
    time.sleep(0.3)

with cf.ThreadPoolExecutor(8) as ex:
    done = 0
    for it in ex.map(detail, items):
        done += 1
        if done % 100 == 0: print(f"detail {done}/{len(items)}", file=sys.stderr)

for it in items: it["format"] = "woff2" if it["webfont"].endswith(".woff2") else ("woff" if it["webfont"].endswith(".woff") else pathlib.Path(it["webfont"]).suffix.lstrip(".") or "")
out = {"version": 1, "fetched": time.strftime("%Y-%m-%d"), "count": len(items), "items": items}
(HERE / "noonnu.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))
from collections import Counter
print("saved", len(items), Counter(i["format"] for i in items), "with download:", sum(1 for i in items if i.get("download")), file=sys.stderr)
