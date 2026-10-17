#!/usr/bin/env python3
"""폰트 미리보기(폰트뷰어) — 맥에 설치된 폰트 + 폴더 폰트를 한 화면에서 미리보는 도구 (NexusFont 맥 대체).

사용법
  python3 fontviewer.py                # 로컬 서버를 띄우고 브라우저로 연다 (이미 떠 있으면 그 창만 연다)
  python3 fontviewer.py <폴더> [...]    # 폴더를 '설치 안 된 폰트' 목록에 등록하고 연다 (등록은 기억됨)
  python3 fontviewer.py --refresh      # 설치 폰트 목록 캐시 다시 읽기
  python3 fontviewer.py --out a.html   # 정적 HTML 로 저장 (폴더 폰트는 브라우저가 못 읽을 수 있음)

의존성 없음 — 파이썬 표준 라이브러리 + macOS system_profiler / osascript 만 쓴다.
"""
import argparse
import hashlib
import http.server
import json
import mimetypes
import os
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import webbrowser

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE_DIR = os.path.expanduser("~/Library/Caches/fontviewer")
CACHE_JSON = os.path.join(CACHE_DIR, "installed.json")
SERVER_JSON = os.path.join(CACHE_DIR, "server.json")
CONF_DIR = os.path.expanduser("~/Library/Application Support/fontviewer")
FOLDERS_JSON = os.path.join(CONF_DIR, "folders.json")
USER_JSON = os.path.join(CONF_DIR, "user.json")
PORT = 48721  # 고정 포트: 브라우저 저장소(즐겨찾기·세트)가 실행마다 안 갈리게
FONT_EXT = (".ttf", ".otf", ".ttc", ".woff", ".woff2", ".dfont")
WATCH_DIRS = [
    "/System/Library/Fonts",
    "/System/Library/Fonts/Supplemental",
    "/Library/Fonts",
    "~/Library/Fonts",
    "~/Library/Application Support/Adobe/CoreSync/plugins/livetype/.r",
]


def log(msg):
    print(msg, file=sys.stderr, flush=True)


# ──────────────────────────── 설치 폰트 수집 ────────────────────────────

def dir_signature():
    sig = []
    for d in WATCH_DIRS:
        d = os.path.expanduser(d)
        if not os.path.isdir(d):
            continue
        n, latest = 0, 0
        for root, dirs, files in os.walk(d):
            n += len(files)
            try:
                latest = max(latest, int(os.stat(root).st_mtime))
            except OSError:
                pass
        sig.append([d, n, latest])
    return sig


def classify(path):
    if "CoreSync" in path:
        return "adobe"
    if path.startswith("/System/"):
        return "system"
    return "user"


def collect_installed(refresh=False):
    """→ (fonts, meta). 캐시가 폰트 폴더 서명과 같으면 재사용."""
    sig = dir_signature()
    if not refresh and os.path.exists(CACHE_JSON):
        try:
            with open(CACHE_JSON, encoding="utf-8") as f:
                cached = json.load(f)
            if cached.get("sig") == sig:
                return cached["fonts"], cached.get("meta", {})
        except Exception:
            pass
    log("설치된 폰트 목록을 읽는 중… (system_profiler, 20초쯤)")
    raw = subprocess.run(["system_profiler", "SPFontsDataType", "-json"], capture_output=True, text=True, check=True).stdout
    data = json.loads(raw).get("SPFontsDataType", [])
    fonts, seen, hidden, dup = [], set(), 0, 0
    for file in data:
        path = file.get("path", "")
        try:
            mtime = int(os.stat(path).st_mtime)
        except OSError:
            mtime = 0
        for tf in file.get("typefaces", []):
            ps = tf.get("_name", "")
            fam = tf.get("family", "") or ps
            if not ps or ps.startswith(".") or fam.startswith("."):
                hidden += 1
                continue
            if tf.get("enabled", "yes") != "yes":
                continue
            if ps in seen:
                dup += 1
                continue
            seen.add(ps)
            fonts.append({
                "key": ps, "ps": ps, "full": tf.get("fullname", "") or ps, "family": fam,
                "style": tf.get("style", "") or "Regular", "vendor": tf.get("vendor", ""),
                "path": path, "file": os.path.basename(path), "src": classify(path), "mtime": mtime,
                "dup": tf.get("duplicate") == "yes",
            })
    meta = {"installed": len(fonts), "hidden": hidden, "dup": dup, "built": time.time()}
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(CACHE_JSON, "w", encoding="utf-8") as f:
        json.dump({"sig": sig, "fonts": fonts, "meta": meta}, f, ensure_ascii=False)
    log(f"폰트 {len(fonts)}개 수집 완료 (숨김 {hidden}, 중복 {dup} 제외)")
    return fonts, meta


# ──────────────────────────── 폴더 폰트(미설치) ────────────────────────────

def _parse_sfnt(f, off):
    f.seek(off)
    tag = f.read(4)
    if tag not in (b"\x00\x01\x00\x00", b"OTTO", b"true"):
        return None
    (num_tables,) = struct.unpack(">H", f.read(2))
    f.seek(off + 12)
    tables = {}
    for _ in range(num_tables):
        t, _cs, to, tl = struct.unpack(">4sIII", f.read(16))
        tables[t] = (to, tl)
    if b"name" not in tables:
        return None
    to, tl = tables[b"name"]
    f.seek(to)
    nd = f.read(tl)
    _fmt, count, str_off = struct.unpack(">HHH", nd[:6])
    names = {}
    for i in range(count):
        rec = nd[6 + 12 * i: 18 + 12 * i]
        if len(rec) < 12:
            break
        pid, eid, lid, nid, ln, so = struct.unpack(">HHHHHH", rec)
        if nid not in (1, 2, 4, 6, 16, 17):
            continue
        raw = nd[str_off + so: str_off + so + ln]
        if pid in (0, 3):
            txt = raw.decode("utf-16-be", "replace")
        elif pid == 1 and eid == 0:
            txt = raw.decode("mac_roman", "replace")
        else:
            continue
        pri = 3 if (pid == 3 and lid == 0x412) else 2 if (pid == 3 and lid == 0x409) else 1 if pid == 3 else 0
        if nid not in names or pri > names[nid][0]:
            names[nid] = (pri, txt.strip("\x00").strip())
    g = lambda n: names.get(n, (0, ""))[1]
    return {"family": g(16) or g(1), "style": g(17) or g(2) or "Regular", "full": g(4), "ps": g(6)}


def font_names(path):
    try:
        with open(path, "rb") as f:
            head = f.read(4)
            if head == b"ttcf":
                f.seek(8)
                (n,) = struct.unpack(">I", f.read(4))
                offs = struct.unpack(">%dI" % n, f.read(4 * n))
                return [x for x in (_parse_sfnt(f, o) for o in offs) if x]
            r = _parse_sfnt(f, 0)
            return [r] if r else []
    except Exception:
        return []


def fid_of(path):
    return hashlib.sha1(path.encode("utf-8")).hexdigest()[:8]


def load_folders():
    try:
        with open(FOLDERS_JSON, encoding="utf-8") as f:
            return [p for p in json.load(f) if os.path.isdir(p)]
    except Exception:
        return []


def save_folders(folders):
    os.makedirs(CONF_DIR, exist_ok=True)
    with open(FOLDERS_JSON, "w", encoding="utf-8") as f:
        json.dump(folders, f, ensure_ascii=False, indent=1)


def collect_folder(folder):
    folder = os.path.abspath(os.path.expanduser(folder))
    fid = fid_of(folder)
    fonts = []
    for root, dirs, fs in os.walk(folder):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for fn in sorted(fs):
            if not fn.lower().endswith(FONT_EXT) or fn.startswith("."):
                continue
            p = os.path.join(root, fn)
            faces = font_names(p)
            first = faces[0] if faces else {}
            stem = os.path.splitext(fn)[0]
            try:
                mtime = int(os.stat(p).st_mtime)
            except OSError:
                mtime = 0
            fonts.append({
                "key": p, "ps": first.get("ps") or stem, "full": first.get("full") or stem,
                "family": first.get("family") or stem, "style": first.get("style") or "Regular", "vendor": "",
                "path": p, "file": fn, "src": "folder", "mtime": mtime, "dup": False,
                "url": f"/fonts/{fid}/" + urllib.parse.quote(os.path.relpath(p, folder)),
                "faces": len(faces), "fid": fid,
            })
    return fonts


def gather(refresh=False):
    """설치 폰트 + 등록 폴더 → (fonts, meta)"""
    fonts, meta = collect_installed(refresh)
    meta = dict(meta)
    meta.setdefault("installed", len(fonts))
    meta["folders"] = []
    for folder in load_folders():
        ff = collect_folder(folder)
        fonts = fonts + ff
        meta["folders"].append({"fid": fid_of(folder), "path": folder, "name": os.path.basename(folder.rstrip("/")) or folder, "count": len(ff)})
    return fonts, meta


# ──────────────────────────── HTML ────────────────────────────

TEMPLATE = r"""<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>폰트 미리보기</title>
<style>
:root{
  --bg:#f3f3f1; --panel:#ffffff; --ink:#1c1c1e; --ink2:#7a7a80; --line:#e3e3e0;
  --accent:#2f6fed; --accent-bg:#e8f0ff; --chip:#eeeeec; --star:#f0b400; --ko:#1d7f4c; --warn:#b4530a;
}
*{box-sizing:border-box}
html,body{margin:0;height:100%;background:var(--bg);color:var(--ink);font:13px/1.4 -apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo","Helvetica Neue",sans-serif}
button,input,select{font:inherit;color:inherit}
body{display:flex;height:100vh;overflow:hidden}
/* ── 사이드바 */
.side{width:234px;flex:0 0 234px;background:var(--panel);border-right:1px solid var(--line);display:flex;flex-direction:column;height:100%}
.side-scroll{flex:1;overflow:auto;padding:16px 10px 10px}
.side-title{font-size:17px;font-weight:700;padding:2px 6px 14px;letter-spacing:-.01em}
.side-title small{font-size:11px;color:var(--ink2);font-weight:500;margin-left:6px}
.sec{margin-bottom:14px}
.sh{display:flex;align-items:center;justify-content:space-between;font-size:11px;color:var(--ink2);padding:4px 6px 4px;font-weight:600}
.sh .plus{border:0;background:none;color:var(--ink2);cursor:pointer;font-size:16px;line-height:1;padding:0 2px}
.sh .plus:hover{color:var(--accent)}
.nav{display:flex;width:100%;align-items:center;justify-content:space-between;gap:8px;border:0;background:transparent;border-radius:7px;padding:7px 8px;cursor:pointer;text-align:left;font-size:13px;position:relative}
.nav:hover{background:var(--chip)}
.nav.on{background:var(--accent-bg);color:var(--accent);font-weight:600}
.nav b{font-weight:500;color:var(--ink2);font-variant-numeric:tabular-nums;font-size:12px}
.nav.on b{color:var(--accent)}
.nav .x{display:none;color:var(--ink2);cursor:pointer;padding:0 2px;font-size:12px}
.nav:hover .x{display:inline}
.nav .x:hover{color:var(--warn)}
.nav span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.side-foot{border-top:1px solid var(--line);padding:12px 12px 14px}
.side-foot button{width:100%;height:34px;border:1px solid var(--line);border-radius:8px;background:var(--panel);cursor:pointer}
.side-foot button:hover{border-color:var(--accent);color:var(--accent)}
.side-foot .note{font-size:11px;color:var(--ink2);margin-top:8px;line-height:1.5}
/* ── 본문 */
.main{flex:1;min-width:0;display:flex;flex-direction:column;height:100%}
.top{background:var(--panel);border-bottom:1px solid var(--line);padding:12px 16px 10px;display:flex;flex-direction:column;gap:9px}
.r{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
input[type=text],input[type=search],select{height:34px;border:1px solid var(--line);border-radius:8px;padding:0 10px;background:var(--bg);outline:none;min-width:0}
input:focus,select:focus{border-color:var(--accent)}
#sample{flex:1 1 300px;font-size:16px;height:40px;padding:0 14px}
#phrases{width:118px}
#savePhrase{height:34px;border:1px solid var(--line);border-radius:8px;background:var(--panel);padding:0 12px;cursor:pointer;white-space:nowrap}
#savePhrase:hover{border-color:var(--accent);color:var(--accent)}
.lbl{color:var(--ink2);white-space:nowrap}
#size{width:120px;accent-color:var(--accent)}
#sizeV{min-width:40px;color:var(--ink2);font-variant-numeric:tabular-nums}
#q{flex:1 1 180px;max-width:260px}
#weight,#sort{width:118px}
.chk{display:flex;align-items:center;gap:6px;cursor:pointer;white-space:nowrap}
.chk input{accent-color:var(--accent);width:15px;height:15px;margin:0}
.col{display:flex;align-items:center;gap:6px;color:var(--ink2)}
.col input[type=color]{width:26px;height:22px;border:1px solid var(--line);border-radius:5px;padding:0;background:none;cursor:pointer}
#swap{height:26px;width:30px;border:1px solid var(--line);border-radius:6px;background:var(--panel);cursor:pointer}
.strip{padding:10px 16px;background:var(--panel);border-bottom:1px solid var(--line);display:flex;gap:10px;align-items:baseline;flex-wrap:wrap}
.strip .t{font-weight:700;font-size:14px}
.strip .d{color:var(--ink2);font-size:12px}
#list{flex:1;overflow:auto;background:var(--pbg,#fff)}
.font{padding:10px 16px 12px;border-bottom:1px solid var(--line);content-visibility:auto;contain-intrinsic-size:auto 88px}
.font.hide{display:none}
.head{display:flex;align-items:center;gap:8px;min-width:0;flex-wrap:nowrap;color:var(--ink)}
.fam{font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:260px;cursor:pointer}
.fam:hover{color:var(--accent)}
.en{color:var(--ink2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:200px}
.sty{color:var(--ink2);white-space:nowrap}
.tags{display:flex;gap:4px;align-items:center;flex-wrap:wrap}
.tag{font-size:11px;border:1px solid var(--line);border-radius:12px;padding:1px 8px;color:var(--ink);cursor:pointer;background:var(--panel);white-space:nowrap}
.tag:hover{border-color:var(--accent)}
.tag.manual{border-style:dashed;border-color:var(--accent)}
.tag.opt{color:var(--ink2)}
.tag.opt.on{background:var(--ink);color:#fff;border-color:var(--ink)}
.tag.ghost{color:var(--ink2);border-style:dashed}
.file{color:var(--ink2);font-size:11px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:220px;cursor:pointer}
.file:hover{color:var(--accent)}
.more{border:0;background:var(--chip);border-radius:10px;padding:1px 8px;cursor:pointer;color:var(--ink2);font-size:11px;white-space:nowrap}
.sp{flex:1}
.setbtn,.star{border:0;background:none;cursor:pointer;color:var(--ink2);font-size:12px;white-space:nowrap}
.setbtn:hover{color:var(--accent)}
.star{font-size:17px;line-height:1;color:#c9c9c9}
.star.on{color:var(--star)}
.badge{font-size:10px;border-radius:4px;padding:1px 5px;font-weight:600}
.badge.err{color:var(--warn);border:1px solid currentColor}
.prev{margin-top:4px;line-height:1.25;overflow-wrap:anywhere;word-break:keep-all;white-space:pre-wrap;color:var(--pfg,#111)}
.editor{display:flex;gap:6px;align-items:center;flex-wrap:wrap;margin-top:6px}
.editor .lab{font-size:11px;color:var(--ink2);margin-left:4px}
.editor .done,.editor .reset{border:0;background:none;color:var(--accent);cursor:pointer;font-size:12px}
.menu{position:fixed;z-index:20;background:var(--panel);border:1px solid var(--line);border-radius:10px;box-shadow:0 8px 24px rgba(0,0,0,.14);padding:6px;min-width:190px}
.menu label{display:flex;align-items:center;gap:8px;padding:6px 8px;border-radius:6px;cursor:pointer}
.menu label:hover{background:var(--chip)}
.menu .new{border:0;background:none;color:var(--accent);cursor:pointer;padding:6px 8px;width:100%;text-align:left}
.empty{padding:60px 0;text-align:center;color:var(--ink2)}
#toast{position:fixed;left:50%;bottom:28px;transform:translateX(-50%) translateY(20px);background:#1c1c1e;color:#fff;padding:8px 14px;border-radius:8px;opacity:0;transition:.2s;pointer-events:none;font-size:12px;z-index:30}
#toast.show{opacity:1;transform:translateX(-50%)}
</style>
</head>
<body>
<aside class="side">
  <div class="side-scroll" id="side"></div>
  <div class="side-foot"><button id="reload">폰트 다시 읽기</button><div class="note" id="note"></div></div>
</aside>
<div class="main">
  <div class="top">
    <div class="r">
      <input id="sample" type="text" placeholder="미리보기 문구">
      <select id="phrases"></select>
      <button id="savePhrase">문구 저장</button>
    </div>
    <div class="r">
      <span class="lbl">크기</span><input id="size" type="range" min="9" max="180" value="36"><span id="sizeV">36px</span>
      <input id="q" type="search" placeholder="폰트 이름 검색 ( / )">
      <select id="weight"><option value="">굵기 전체</option><option value="thin">가는</option><option value="regular">보통</option><option value="bold">두꺼운</option><option value="black">아주 두꺼운</option></select>
      <select id="sort"><option value="name">이름순</option><option value="recent">최근 설치순</option><option value="weight">얇은 → 굵은</option><option value="fav">즐겨찾기 먼저</option></select>
    </div>
    <div class="r">
      <label class="chk"><input type="checkbox" id="group"> 패밀리 묶기</label>
      <span class="col">글자 <input type="color" id="fg" value="#111111"></span>
      <span class="col">배경 <input type="color" id="bg" value="#ffffff"></span>
      <button id="swap" title="글자/배경 색 바꾸기">⇄</button>
      <span class="sp"></span><span class="lbl" id="status"></span>
    </div>
  </div>
  <div class="strip"><span class="t" id="stripT"></span><span class="d" id="stripD"></span></div>
  <div id="list"></div>
</div>
<div id="toast"></div>
<script id="data" type="application/json">__DATA__</script>
<script id="meta" type="application/json">__META__</script>
<script>
(async () => {
const FONTS = JSON.parse(document.getElementById('data').textContent);
const META = JSON.parse(document.getElementById('meta').textContent);
const SERVER = !!META.server;
const USER_KEYS = ['fav', 'sets', 'phrases', 'tags', 'state2'];
const USER = SERVER ? await fetch('/api/user', { cache: 'no-store' }).then(r => r.json()).catch(() => ({})) : {};
let pushT = null;
function pushUser() { if (!SERVER) return; clearTimeout(pushT); pushT = setTimeout(() => fetch('/api/user', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(USER) }).catch(() => {}), 400); }
const PROF_VER = 'v5';
const DEFAULT_SAMPLE = '다람쥐 헌 쳇바퀴에 타고파 The quick brown fox 0123456789';
const LS = (k, d) => { if (USER[k] !== undefined) return USER[k]; try { const v = localStorage.getItem('fv.' + k); return v === null ? d : JSON.parse(v); } catch (e) { return d; } };
const SAVE = (k, v) => { try { localStorage.setItem('fv.' + k, JSON.stringify(v)); } catch (e) {} if (USER_KEYS.includes(k)) { USER[k] = v; pushUser(); } };
const state = Object.assign({ sample: DEFAULT_SAMPLE, size: 36, q: '', weight: '', sort: 'name', group: true, fg: '#111111', bg: '#ffffff', nav: 'all' }, LS('state2', {}));
const fav = new Set(LS('fav', []));
const prof = LS('prof.' + PROF_VER, {});
const manual = LS('tags', {});
const sets = LS('sets', {});            // 이름 → [key]
const phrases = LS('phrases', ['다람쥐 헌 쳇바퀴에 타고파', 'The quick brown fox jumps over the lazy dog', '쫄깃 탱글', 'ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz', '0123456789 ₩$% !?&@#*()']);
const expanded = new Set();
const $ = id => document.getElementById(id);

const CATS = [['black', '두꺼운 제목용'], ['sans', '고딕·산세리프'], ['serif', '명조·세리프'], ['round', '둥근·귀여운'], ['hand', '손글씨'], ['brush', '붓글씨·캘리'], ['deco', '장식·디자인'], ['wide', '넙적한 (평체)'], ['narrow', '길쭉한 (장체)']];
const WEIGHTS = [['thin', '가는'], ['regular', '보통'], ['bold', '두꺼운'], ['black', '아주 두꺼운']];
const LABEL = {}; CATS.forEach(([k, l]) => LABEL[k] = l); WEIGHTS.forEach(([k, l]) => LABEL['w:' + k] = l);

// ── @font-face
const css = FONTS.map((f, i) => {
  const src = f.url ? `url("${f.url}")` : `local("${f.ps.replace(/"/g, '\\"')}"),local("${f.full.replace(/"/g, '\\"')}")`;
  return `@font-face{font-family:"f${i}";src:${src};font-display:block}`;
}).join('\n');
const st = document.createElement('style'); st.textContent = css; document.head.appendChild(st);

// ── 패밀리
const FAMKEY = FONTS.map(f => f.fid ? f.family + '@' + f.fid : f.family);
const families = new Map();
FONTS.forEach((f, i) => { const k = FAMKEY[i]; if (!families.has(k)) families.set(k, []); families.get(k).push(i); });
const REP_RE = /^(regular|normal|medium|book|roman|plain|r|m|보통|레귤러|미디엄|기본|일반체|중간체)$/i;
const rep = new Map();
families.forEach((idx, fam) => { rep.set(fam, idx.find(i => REP_RE.test(FONTS[i].style)) ?? idx.find(i => /regular|medium/i.test(FONTS[i].style)) ?? idx[0]); });

// ── 이름 힌트
const NAME = FONTS.map(f => (f.family + ' ' + f.style + ' ' + f.ps + ' ' + f.file).toLowerCase());
const RX = {
  thin: /\b(thin|hairline|ultralight|extralight|ul|el)\b|가는|얇은/, light: /\blight\b|라이트|가는체/,
  bold: /\b(bold|semibold|demibold|extrabold|b|eb|sb)\b|볼드|굵은/, black: /\b(black|heavy|ultra|extrabold|eb|fat)\b|블랙|헤비|진한 볼드체/,
  serif: /serif|명조|바탕|myungjo|myeongjo|batang|mincho|song|roman|garamond|baskerville|caslon|didot|bodoni|times|georgia|minion/,
  sans: /\bsans\b|고딕|gothic|돋움|dotum|gulim|굴림|helvetica|arial|futura|pretendard|spoqa|noto sans/,
  round: /round|둥근|rounded|라운드|rd\b|통통|dunggeun/,
  hand: /hand|script|\bpen\b|cursive|손글씨|손글|손멋|필기|펜글|연필|낙서|crayon|marker|chalk|sign|write|writing|scrawl|끄적|꼬불|삐뚤|어린이/,
  brush: /brush|calli|붓|캘리|먹|ink|흘림|서예|궁서|gungseo/,
  italic: /italic|oblique|기울|slant/,
  deco: /outline|hollow|inline|외곽|테두리|pixel|dot\b|도트|픽셀|8.?bit|bitmap|shadow|3d|stencil|스텐실|neon|네온|display|디스플레이|decor|장식/,
  wide: /extended|expanded|\bwide\b|평체|넓은|ext\b|exp\b/,
  narrow: /condensed|narrow|compressed|장체|좁은|\bcond\b|\bcn\b|compact/,
};
const TH = { thin: 0.05, bold: 0.11, black: 0.15, foot: 1.7, contrast: 2.2, corner: 0.5, handStraight: 0.5, handIrrKo: 0.015, handIrrLa: 0.02, brushStraight: 0.3, sansMin: 0.7, slant: 0.165, wideKo: 1.18, narrowKo: 0.82, wideLa: 1.0, narrowLa: 0.6 };

function detectAuto(i) {
  const p = prof[FONTS[i].key] || {}, n = NAME[i], t = new Set();
  // 굵기
  let w = p.stem != null ? p.stem : (p.density != null ? p.density * 0.55 : null), wt = null;
  if (w != null) wt = w < TH.thin ? 'thin' : w < TH.bold ? 'regular' : w < TH.black ? 'bold' : 'black';
  else if (RX.black.test(n)) wt = 'black'; else if (RX.bold.test(n)) wt = 'bold'; else if (RX.thin.test(n) || RX.light.test(n)) wt = 'thin'; else if (Object.keys(p).length && !p.err) wt = 'regular';
  if (wt) t.add('w:' + wt);
  if (wt === 'black') t.add('black');
  // 손글씨 계열
  const handish = RX.hand.test(n) || RX.brush.test(n) || (p.irr != null && p.irr >= (p.ko ? TH.handIrrKo : TH.handIrrLa)) || (p.straight != null && p.straight < TH.handStraight && (p.stem || 0) >= 0.05);
  const brush = handish && (RX.brush.test(n) || (p.straight != null && p.straight < TH.brushStraight));
  if (brush) t.add('brush'); else if (handish) t.add('hand');
  const nameSerif = RX.serif.test(n) && !RX.sans.test(n);
  const serif = !handish && (nameSerif || (!p.mono && ((p.foot != null && p.foot >= TH.foot) || (p.contrast != null && p.contrast >= TH.contrast))));
  if (serif) t.add('serif');
  const round = RX.round.test(n) || (!serif && p.corner != null && p.corner <= TH.corner && (p.bar || 0) >= 0.06 && (p.straight == null || p.straight >= 0.6));
  if (round) { t.add('round'); t.delete('sans'); }
  const thinOk = p.stem != null && p.stem < TH.thin && (p.foot == null || p.foot < 1.3);
  if (!serif && !handish && !round && ((p.straight != null && p.straight >= TH.sansMin) || thinOk || RX.sans.test(n))) t.add('sans');
  if (p.outline || RX.deco.test(n)) t.add('deco');
  if (p.aspect != null) { const [wi, na] = p.ko ? [TH.wideKo, TH.narrowKo] : [TH.wideLa, TH.narrowLa]; if (p.aspect >= wi) t.add('wide'); else if (p.aspect <= na) t.add('narrow'); }
  if (RX.wide.test(n)) { t.delete('narrow'); t.add('wide'); }
  if (RX.narrow.test(n)) { t.delete('wide'); t.add('narrow'); }
  return t;
}
function tagsOf(i) {
  const t = detectAuto(i), m = manual[FONTS[i].key];
  if (m) { (m.off || []).forEach(x => t.delete(x)); (m.on || []).forEach(x => { if (x.startsWith('w:')) [...t].filter(y => y.startsWith('w:')).forEach(y => t.delete(y)); t.add(x); }); }
  return t;
}
let TAGS = FONTS.map((_, i) => tagsOf(i));
const isKo = i => !!prof[FONTS[i].key]?.ko;
const isLaOnly = i => { const p = prof[FONTS[i].key]; return !!(p && p.la && !p.ko && !p.ja && !p.hj); };
const RECENT = Date.now() / 1000 - 30 * 86400;

// ── 행
const list = $('list');
const rows = FONTS.map((f, i) => {
  const el = document.createElement('div'); el.className = 'font'; el.dataset.i = i;
  const n = families.get(FAMKEY[i]).length;
  const en = f.full && f.full !== f.family && !f.full.startsWith(f.family) ? f.full.replace(/\s*(regular|bold|light|medium|italic|black|thin|heavy|extrabold|semibold)\s*$/i, '') : '';
  el.innerHTML = `<div class="head">
      <span class="fam" title="클릭하면 PostScript 이름 복사: ${esc(f.ps)}">${esc(f.family)}</span>${en && en !== f.family ? `<span class="en">${esc(en)}</span>` : ''}<span class="sty">${esc(f.style)}</span>
      <span class="tags" data-tags></span>
      <span class="file" title="${esc(f.path)} (클릭하면 경로 복사)">${esc(f.file)}</span>
      ${n > 1 ? `<button class="more">${n}개 스타일</button>` : ''}
      <span class="sp"></span>
      <button class="setbtn" title="내 세트에 담기">+ 세트</button>
      <button class="star" title="즐겨찾기">★</button>
    </div>
    <div class="prev" style="font-family:'f${i}'"></div>
    <div class="editor" data-editor style="display:none"></div>`;
  el.querySelector('.star').onclick = () => toggleFav(f.key, el);
  el.querySelector('.fam').onclick = () => copy(f.ps, 'PostScript 이름 복사됨: ' + f.ps);
  el.querySelector('.file').onclick = () => copy(f.path, '경로 복사됨');
  el.querySelector('.setbtn').onclick = (e) => setMenu(e.currentTarget, f.key);
  const more = el.querySelector('.more'); if (more) more.onclick = () => { expanded.has(FAMKEY[i]) ? expanded.delete(FAMKEY[i]) : expanded.add(FAMKEY[i]); render(); };
  el.querySelector('.star').classList.toggle('on', fav.has(f.key));
  return el;
});
const frag = document.createDocumentFragment(); rows.forEach(r => frag.appendChild(r)); list.appendChild(frag);
const emptyEl = document.createElement('div'); emptyEl.className = 'empty'; emptyEl.textContent = '조건에 맞는 폰트가 없습니다'; emptyEl.style.display = 'none'; list.appendChild(emptyEl);

const editing = new Set();
function drawTags(i) {
  const el = rows[i], box = el.querySelector('[data-tags]'), ed = el.querySelector('[data-editor]'), t = TAGS[i], m = manual[FONTS[i].key] || { on: [], off: [] }, p = prof[FONTS[i].key];
  const cats = [...t].filter(x => !x.startsWith('w:')), w = [...t].find(x => x.startsWith('w:'));
  const parts = cats.map(x => LABEL[x]); if (w && w !== 'w:regular' && !(w === 'w:black' && cats.includes('black'))) parts.push(LABEL[w]);
  let h = '';
  if (p && p.err) h += `<span class="badge err" title="이 브라우저가 폰트를 못 불러왔습니다 (미리보기가 대체 폰트로 보임)">브라우저에서 못 찾음</span>`;
  if (!p) h += `<span class="tag ghost">분석 전</span>`;
  else h += parts.length ? `<span class="tag ${m.on.length || m.off.length ? 'manual' : ''}" title="클릭하면 분류 고치기">${parts.join(' · ')}</span>` : `<span class="tag ghost" title="클릭하면 분류 고치기">분류 없음</span>`;
  box.innerHTML = h;
  const tg = box.querySelector('.tag'); if (tg) tg.onclick = () => { editing.has(i) ? editing.delete(i) : editing.add(i); drawTags(i); };
  if (!editing.has(i)) { ed.style.display = 'none'; ed.innerHTML = ''; return; }
  ed.style.display = '';
  ed.innerHTML = `<span class="lab">분류</span>` + CATS.map(([k, l]) => `<span class="tag opt ${t.has(k) ? 'on' : ''}" data-t="${k}">${l}</span>`).join('') +
    `<span class="lab">굵기</span>` + WEIGHTS.map(([k, l]) => `<span class="tag opt ${t.has('w:' + k) ? 'on' : ''}" data-t="w:${k}">${l}</span>`).join('') +
    `<button class="done">완료</button>` + (m.on.length || m.off.length ? `<button class="reset">자동으로 되돌리기</button>` : '');
  ed.querySelectorAll('.tag.opt').forEach(s => s.onclick = () => {
    const id = s.dataset.t, key = FONTS[i].key, mm = manual[key] || (manual[key] = { on: [], off: [] }), auto = detectAuto(i);
    mm.on = mm.on.filter(x => x !== id); mm.off = mm.off.filter(x => x !== id);
    if (id.startsWith('w:')) { mm.on = mm.on.filter(x => !x.startsWith('w:')); mm.off = mm.off.filter(x => !x.startsWith('w:')); if (!auto.has(id)) mm.on.push(id); }
    else if (t.has(id)) { if (auto.has(id)) mm.off.push(id); } else { if (!auto.has(id)) mm.on.push(id); }
    if (!mm.on.length && !mm.off.length) delete manual[key];
    SAVE('tags', manual); TAGS[i] = tagsOf(i); drawTags(i); render(false);
  });
  ed.querySelector('.done').onclick = () => { editing.delete(i); drawTags(i); };
  const rs = ed.querySelector('.reset'); if (rs) rs.onclick = () => { delete manual[FONTS[i].key]; SAVE('tags', manual); TAGS[i] = tagsOf(i); drawTags(i); render(false); };
}
function esc(s) { return String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }
function toggleFav(key, el) { fav.has(key) ? fav.delete(key) : fav.add(key); el.querySelector('.star').classList.toggle('on', fav.has(key)); SAVE('fav', [...fav]); render(state.nav === 'fav' || state.sort === 'fav'); }
let toastT; function toast(msg) { const t = $('toast'); t.textContent = msg; t.classList.add('show'); clearTimeout(toastT); toastT = setTimeout(() => t.classList.remove('show'), 1800); }
function copy(txt, msg) { navigator.clipboard?.writeText(txt).then(() => toast(msg), () => toast('복사 실패')); }

// ── 세트 메뉴
let menuEl = null;
function closeMenu() { if (menuEl) { menuEl.remove(); menuEl = null; } }
document.addEventListener('click', e => { if (menuEl && !menuEl.contains(e.target) && !e.target.classList.contains('setbtn')) closeMenu(); });
function setMenu(btn, key) {
  closeMenu(); const names = Object.keys(sets);
  const m = document.createElement('div'); m.className = 'menu';
  m.innerHTML = names.map(n => `<label><input type="checkbox" ${sets[n].includes(key) ? 'checked' : ''} data-n="${esc(n)}"> ${esc(n)} <b style="margin-left:auto;color:var(--ink2);font-weight:500">${sets[n].length}</b></label>`).join('') + `<button class="new">+ 새 세트 만들어 담기</button>`;
  m.querySelectorAll('input').forEach(c => c.onchange = () => { const n = c.dataset.n; sets[n] = sets[n].filter(k => k !== key); if (c.checked) sets[n].push(key); SAVE('sets', sets); buildSide(); render(false); });
  m.querySelector('.new').onclick = () => { const n = prompt('새 세트 이름'); if (!n) return; if (!sets[n]) sets[n] = []; if (!sets[n].includes(key)) sets[n].push(key); SAVE('sets', sets); closeMenu(); buildSide(); render(false); toast(`「${n}」에 담았어요`); };
  document.body.appendChild(m); const r = btn.getBoundingClientRect(); m.style.top = (r.bottom + 4) + 'px'; m.style.left = Math.min(r.left, innerWidth - 220) + 'px'; menuEl = m;
}

// ── 사이드바
const side = $('side');
function navItem(id, label, extra = '') { return `<button class="nav" data-nav="${esc(id)}"><span>${esc(label)}</span><span style="display:flex;gap:4px;align-items:center">${extra}<b data-c></b></span></button>`; }
function buildSide() {
  let h = `<div class="side-title">폰트 미리보기<small>v2 · 맥</small></div>`;
  h += `<div class="sec"><div class="sh"><span>폰트</span></div>` + navItem('all', '전체 설치 폰트') + navItem('ko', '한글 폰트') + navItem('laOnly', '영문 전용 폰트') + navItem('recent', '최근 설치한 폰트') + navItem('fav', '★ 즐겨찾기') + `</div>`;
  h += `<div class="sec"><div class="sh"><span>자동 분류</span></div>` + CATS.map(([k, l]) => navItem('cat:' + k, l)).join('') + `</div>`;
  h += `<div class="sec"><div class="sh"><span>내 세트</span><button class="plus" data-newset title="새 세트">+</button></div>` + Object.keys(sets).map(n => navItem('set:' + n, n, `<span class="x" data-del-set="${esc(n)}" title="세트 삭제">✕</span>`)).join('') + (Object.keys(sets).length ? '' : `<div class="note" style="padding:4px 8px;font-size:11px;color:var(--ink2)">폰트 줄의 「+ 세트」로 담으면 여기 생겨요</div>`) + `</div>`;
  h += `<div class="sec"><div class="sh"><span>폴더 (설치 안 된 폰트)</span><button class="plus" data-addfolder title="폴더 추가">+</button></div>` + (META.folders || []).map(fo => navItem('folder:' + fo.fid, fo.name, `<span class="x" data-del-folder="${fo.fid}" title="목록에서 빼기">✕</span>`)).join('') + (META.folders && META.folders.length ? '' : `<div class="note" style="padding:4px 8px;font-size:11px;color:var(--ink2)">+ 를 누르거나 폰트 폴더를 앱에 드롭하세요</div>`) + `</div>`;
  side.innerHTML = h;
  side.querySelectorAll('.nav').forEach(b => b.onclick = (e) => { if (e.target.closest('.x')) return; state.nav = b.dataset.nav; render(); persist(); });
  side.querySelector('[data-newset]').onclick = () => { const n = prompt('새 세트 이름'); if (!n) return; if (!sets[n]) sets[n] = []; SAVE('sets', sets); buildSide(); render(false); };
  side.querySelectorAll('[data-del-set]').forEach(b => b.onclick = (e) => { e.stopPropagation(); const n = b.dataset.delSet; if (!confirm(`「${n}」 세트를 지울까요? (폰트는 안 지워져요)`)) return; delete sets[n]; SAVE('sets', sets); if (state.nav === 'set:' + n) state.nav = 'all'; buildSide(); render(); });
  side.querySelector('[data-addfolder]').onclick = addFolder;
  side.querySelectorAll('[data-del-folder]').forEach(b => b.onclick = (e) => { e.stopPropagation(); api('/api/folder/remove?fid=' + b.dataset.delFolder).then(() => location.reload()); });
  $('note').innerHTML = `설치 폰트 ${(META.installed || 0).toLocaleString()}개` + (META.hidden ? `<br>미리보기 못 하는 숨김 시스템 폰트 ${META.hidden.toLocaleString()}개 제외` : '') + (META.dup ? ` · 중복 이름 ${META.dup}개 제외` : '');
}
async function api(path) {
  if (!SERVER) { toast('이 기능은 폰트뷰어 앱(서버)으로 열었을 때만 돼요'); throw new Error('no server'); }
  const r = await fetch(path, { cache: 'no-store' }); if (!r.ok) { toast('서버 응답 오류'); throw new Error(r.status); } return r.json();
}
async function addFolder() {
  if (!SERVER) { toast('폴더 추가는 폰트뷰어 앱으로 열었을 때만 돼요 (또는 폴더를 앱에 드롭)'); return; }
  toast('폴더 선택 창을 띄웠어요 (Finder 쪽을 보세요)');
  const r = await api('/api/folder/pick'); if (r.cancel) return; if (r.error) { toast(r.error); return; } location.reload();
}
$('reload').onclick = async () => { if (!SERVER) { toast('앱으로 열었을 때만 다시 읽을 수 있어요'); return; } toast('폰트 목록을 다시 읽는 중… (20초쯤)'); await api('/api/refresh'); location.reload(); };
buildSide();

// ── 컨트롤
function fillPhrases() { $('phrases').innerHTML = `<option value="">문구 목록</option>` + phrases.map(p => `<option value="${esc(p)}">${esc(p.length > 24 ? p.slice(0, 24) + '…' : p)}</option>`).join('') + `<option value="__name">폰트 이름으로</option>`; $('savePhrase').textContent = phrases.includes(state.sample) ? '문구 삭제' : '문구 저장'; }
fillPhrases();
$('sample').value = state.sample; $('size').value = state.size; $('sizeV').textContent = state.size + 'px'; $('q').value = state.q; $('weight').value = state.weight; $('sort').value = state.sort; $('group').checked = state.group; $('fg').value = state.fg; $('bg').value = state.bg;
$('sample').oninput = e => { state.sample = e.target.value; applySample(); fillPhrases(); persist(); };
$('phrases').onchange = e => { const v = e.target.value; if (!v) return; state.sample = v === '__name' ? '' : v; $('sample').value = state.sample; applySample(); fillPhrases(); e.target.value = ''; persist(); };
$('savePhrase').onclick = () => { const s = state.sample.trim(); if (!s) return; const i = phrases.indexOf(s); if (i >= 0) { phrases.splice(i, 1); toast('문구 삭제'); } else { phrases.unshift(s); toast('문구 저장'); } SAVE('phrases', phrases); fillPhrases(); };
$('size').oninput = e => { state.size = +e.target.value; $('sizeV').textContent = state.size + 'px'; applySize(); persist(); };
$('q').oninput = e => { state.q = e.target.value; render(); persist(); };
$('weight').onchange = e => { state.weight = e.target.value; render(); persist(); };
$('sort').onchange = e => { state.sort = e.target.value; render(); persist(); };
$('group').onchange = e => { state.group = e.target.checked; render(); persist(); };
$('fg').oninput = e => { state.fg = e.target.value; applyColors(); persist(); };
$('bg').oninput = e => { state.bg = e.target.value; applyColors(); persist(); };
$('swap').onclick = () => { [state.fg, state.bg] = [state.bg, state.fg]; $('fg').value = state.fg; $('bg').value = state.bg; applyColors(); persist(); };
document.addEventListener('keydown', e => { if (e.key === '/' && !/input|select|textarea/i.test(document.activeElement.tagName)) { e.preventDefault(); $('q').focus(); $('q').select(); } if (e.key === 'Escape') { closeMenu(); document.activeElement.blur(); } });
function persist() { SAVE('state2', state); }
function applySize() { rows.forEach(r => r.querySelector('.prev').style.fontSize = state.size + 'px'); }
function applySample() { rows.forEach((r, i) => r.querySelector('.prev').textContent = state.sample || FONTS[i].full); }
function applyColors() { list.style.setProperty('--pbg', state.bg); list.style.setProperty('--pfg', state.fg); }

// ── 필터
const NAVL = { all: '전체 설치 폰트', ko: '한글 폰트', laOnly: '영문 전용 폰트', recent: '최근 설치한 폰트', fav: '즐겨찾기' };
function passNav(i, nav) {
  const f = FONTS[i];
  if (nav === 'all') return f.src !== 'folder';
  if (nav === 'ko') return f.src !== 'folder' && isKo(i);
  if (nav === 'laOnly') return f.src !== 'folder' && isLaOnly(i);
  if (nav === 'recent') return f.src !== 'folder' && f.mtime >= RECENT;
  if (nav === 'fav') return fav.has(f.key);
  if (nav.startsWith('cat:')) return TAGS[i].has(nav.slice(4));
  if (nav.startsWith('set:')) return (sets[nav.slice(4)] || []).includes(f.key);
  if (nav.startsWith('folder:')) return f.fid === nav.slice(7);
  return true;
}
function render(reorder = true) {
  if (state.nav.startsWith('set:') && !sets[state.nav.slice(4)]) state.nav = 'all';
  const terms = state.q.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const base = FONTS.map((f, i) => {
    if (terms.length) { const hay = (f.family + ' ' + f.full + ' ' + f.ps + ' ' + f.style + ' ' + f.vendor + ' ' + f.file).toLowerCase(); if (!terms.every(t => hay.includes(t))) return false; }
    if (state.weight && !TAGS[i].has('w:' + state.weight)) return false;
    if (state.group && !terms.length && !expanded.has(FAMKEY[i]) && rep.get(FAMKEY[i]) !== i) return false;
    return true;
  });
  const vis = [];
  FONTS.forEach((f, i) => { const ok = base[i] && passNav(i, state.nav); rows[i].classList.toggle('hide', !ok); if (ok) vis.push(i); });
  // 사이드바 카운트(검색·굵기·묶기 반영)
  side.querySelectorAll('.nav').forEach(b => { let c = 0; FONTS.forEach((f, i) => { if (base[i] && passNav(i, b.dataset.nav)) c++; }); b.querySelector('[data-c]').textContent = c.toLocaleString(); b.classList.toggle('on', b.dataset.nav === state.nav); });
  if (reorder) {
    const coll = new Intl.Collator('ko');
    const wOf = i => { const p = prof[FONTS[i].key] || {}; return p.stem != null ? p.stem : p.density != null ? p.density * 0.55 : 9; };
    vis.sort((a, b) => {
      if (state.sort === 'recent') return (FONTS[b].mtime - FONTS[a].mtime) || coll.compare(FONTS[a].family, FONTS[b].family);
      if (state.sort === 'weight') return (wOf(a) - wOf(b)) || coll.compare(FONTS[a].family, FONTS[b].family);
      if (state.sort === 'fav') { const d = (fav.has(FONTS[b].key) ? 1 : 0) - (fav.has(FONTS[a].key) ? 1 : 0); if (d) return d; }
      return coll.compare(FONTS[a].family, FONTS[b].family) || coll.compare(FONTS[a].style, FONTS[b].style);
    });
    const frag = document.createDocumentFragment(); vis.forEach(i => frag.appendChild(rows[i])); list.insertBefore(frag, emptyEl);
  }
  emptyEl.style.display = vis.length ? 'none' : '';
  const fams = new Set(vis.map(i => FONTS[i].family)).size;
  const nav = state.nav;
  $('stripT').textContent = NAVL[nav] || (nav.startsWith('cat:') ? LABEL[nav.slice(4)] : nav.startsWith('set:') ? nav.slice(4) : nav.startsWith('folder:') ? ((META.folders || []).find(x => x.fid === nav.slice(7)) || {}).name || '폴더' : '');
  let d = `${vis.length.toLocaleString()}개 · ${fams.toLocaleString()}개 패밀리`;
  if (nav.startsWith('cat:')) d += ' · 생김새로 자동 분류 — 틀린 건 분류 표시를 눌러 고치면 돼요';
  else if (nav.startsWith('set:')) d += ' · 폰트 줄의 「+ 세트」로 넣고 빼요';
  else if (nav.startsWith('folder:')) d += ' · ' + (((META.folders || []).find(x => x.fid === nav.slice(7)) || {}).path || '');
  else if (nav === 'recent') d += ' · 최근 30일 안에 설치된 파일';
  $('stripD').textContent = d;
}
applySize(); applySample(); applyColors(); render(); FONTS.forEach((_, i) => drawTags(i));

// ══════════ 생김새 측정 (캔버스) ══════════
const A = 120;
const pc = document.createElement('canvas'); pc.width = 120; pc.height = 56; const px = pc.getContext('2d', { willReadFrequently: true });
function pixels(fam, text, fb) { px.clearRect(0, 0, 120, 56); px.font = `36px "${fam}", "${fb}"`; px.fillText(text, 2, 42); return px.getImageData(0, 0, 120, 56).data; }
function same(a, b) { for (let i = 3; i < a.length; i += 4) if (a[i] !== b[i]) return false; return true; }
function has(fam, text, fbA, fbB) { return same(pixels(fam, text, fbA), pixels(fam, text, fbB)); }
const GW = 320, GH = 160, GS = 96;
const gc = document.createElement('canvas'); gc.width = GW; gc.height = GH; const gx = gc.getContext('2d', { willReadFrequently: true });
function glyph(fam, ch) {
  gx.clearRect(0, 0, GW, GH); gx.font = `${GS}px "${fam}"`; gx.textBaseline = 'alphabetic'; gx.fillText(ch, 16, 120);
  const d = gx.getImageData(0, 0, GW, GH).data; let x0 = GW, y0 = GH, x1 = -1, y1 = -1, n = 0;
  for (let y = 0; y < GH; y++) for (let x = 0; x < GW; x++) if (d[(y * GW + x) * 4 + 3] > A) { n++; if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
  return n ? { d, x0, y0, x1, y1, n } : null;
}
const on = (g, x, y) => g.d[(y * GW + x) * 4 + 3] > A;
function rowRuns(g, y) { const r = []; let c = 0; for (let x = g.x0; x <= g.x1; x++) { if (on(g, x, y)) c++; else if (c) { r.push(c); c = 0; } } if (c) r.push(c); return r; }
function rowInk(g, y) { let n = 0; for (let x = g.x0; x <= g.x1; x++) if (on(g, x, y)) n++; return n; }
function centroid(g, ya, yb) { let s = 0, n = 0; for (let y = ya; y <= yb; y++) for (let x = g.x0; x <= g.x1; x++) if (on(g, x, y)) { s += x; n++; } return n ? s / n : null; }
function stemStats(g) {
  const h = g.y1 - g.y0 + 1, ym = g.y0 + (h >> 1), runs = rowRuns(g, ym), stem = Math.max(1, ...runs);
  const band = Math.max(2, Math.round(h * 0.08)); let endMax = 0;
  for (let y = g.y0; y < g.y0 + band; y++) endMax = Math.max(endMax, rowInk(g, y));
  for (let y = g.y1 - band + 1; y <= g.y1; y++) endMax = Math.max(endMax, rowInk(g, y));
  const q = Math.max(2, Math.round(h * 0.2)), cT = centroid(g, g.y0, g.y0 + q), cB = centroid(g, g.y1 - q, g.y1);
  return { stem, foot: endMax / stem, slant: cT != null && cB != null ? (cT - cB) / (h - q) : 0, outline: runs.length >= 2 ? 1 : 0 };
}
function cornerFill(g) {
  const t = g.y1 - g.y0 + 1, r = Math.max(2, Math.round(t / 4)); let n = 0, tot = 0;
  for (const [cx, cy] of [[g.x0, g.y0], [g.x1 - r + 1, g.y0], [g.x0, g.y1 - r + 1], [g.x1 - r + 1, g.y1 - r + 1]])
    for (let y = cy; y < cy + r; y++) for (let x = cx; x < cx + r; x++) { tot++; if (on(g, x, y)) n++; }
  return n / tot;
}
const SW = 760, SH = 128, SS = 64, AS = 60;
const sc = document.createElement('canvas'); sc.width = SW; sc.height = SH; const sx = sc.getContext('2d', { willReadFrequently: true });
function strokeStats(fam, text) {
  sx.clearRect(0, 0, SW, SH); sx.font = `${SS}px "${fam}"`; sx.textBaseline = 'alphabetic'; sx.fillText(text, 8, 96);
  const w = sx.measureText(text).width, d = sx.getImageData(0, 0, SW, SH).data, onp = new Uint8Array(SW * SH); let ink = 0;
  for (let i = 0; i < SW * SH; i++) if (d[i * 4 + 3] > AS) { onp[i] = 1; ink++; }
  if (!ink) return null;
  const L = Math.round(SS * 0.28), maxT = Math.round(SS * 0.3), mark = new Uint8Array(SW * SH), hr = new Uint16Array(SW * SH), vr = new Uint16Array(SW * SH);
  for (let y = 0; y < SH; y++) { let s = -1; for (let x = 0; x <= SW; x++) { const v = x < SW && onp[y * SW + x]; if (v && s < 0) s = x; if (!v && s >= 0) { const len = x - s; for (let k = s; k < x; k++) { hr[y * SW + k] = len; if (len >= L) mark[y * SW + k] = 1; } s = -1; } } }
  for (let x = 0; x < SW; x++) { let s = -1; for (let y = 0; y <= SH; y++) { const v = y < SH && onp[y * SW + x]; if (v && s < 0) s = y; if (!v && s >= 0) { const len = y - s; for (let k = s; k < y; k++) { vr[k * SW + x] = len; if (len >= L) mark[k * SW + x] = 1; } s = -1; } } }
  let m = 0, tn = 0, ts = 0, ts2 = 0;
  for (let i = 0; i < SW * SH; i++) { if (!onp[i]) continue; m += mark[i]; const t = Math.min(hr[i], vr[i]); if (t > 0 && t <= maxT) { tn++; ts += t; ts2 += t * t; } }
  let cv = null; if (tn > 50) { const mean = ts / tn; cv = Math.sqrt(Math.max(0, ts2 / tn - mean * mean)) / mean; }
  return { s: m / ink, d: ink / (Math.min(w, SW - 8) * SS), cv };
}
function irregularity(fam, chars) {
  const tops = [], bots = [];
  for (const ch of chars) { const g = glyph(fam, ch); if (g) { tops.push(g.y0); bots.push(g.y1); } }
  if (tops.length < 4) return null;
  const sd = a => { const m = a.reduce((x, y) => x + y, 0) / a.length; return Math.sqrt(a.reduce((x, y) => x + (y - m) ** 2, 0) / a.length); };
  return +(((sd(tops) + sd(bots)) / 2) / GS).toFixed(3);
}
async function analyze(i) {
  const fam = `f${i}`, p = {};
  try { const faces = await document.fonts.load(`36px "${fam}"`, '한글A'); if (!faces.length || !faces.some(x => x.status === 'loaded')) { p.err = 1; return p; } } catch (e) { p.err = 1; return p; }
  p.ko = has(fam, '한글', 'AppleMyungjo', 'Apple SD Gothic Neo') ? 1 : 0;
  p.la = has(fam, 'Hamburg', 'Georgia', 'Helvetica') ? 1 : 0;
  p.ja = has(fam, 'あア', 'Hiragino Mincho ProN', 'Hiragino Sans') ? 1 : 0;
  p.hj = has(fam, '漢字', 'Hiragino Mincho ProN', 'Hiragino Sans') ? 1 : 0;
  const vch = p.ko && has(fam, 'ㅣ', 'AppleMyungjo', 'Apple SD Gothic Neo') ? 'ㅣ' : p.la ? 'l' : null;
  const hch = p.ko && has(fam, 'ㅡ', 'AppleMyungjo', 'Apple SD Gothic Neo') ? 'ㅡ' : p.la ? '-' : null;
  if (vch) { const g = glyph(fam, vch); if (g) { const s = stemStats(g); p.stem = +(s.stem / GS).toFixed(3); p.foot = +s.foot.toFixed(2); p.slant = +s.slant.toFixed(3); p.outline = s.outline; } }
  if (hch) { const g = glyph(fam, hch); if (g) { p.bar = +((g.y1 - g.y0 + 1) / GS).toFixed(3); p.corner = +cornerFill(g).toFixed(2); } }
  if (p.stem && p.bar) p.contrast = +(p.stem / p.bar).toFixed(2);
  const ach = p.ko ? '한' : p.la ? 'H' : null;
  if (ach) { const g = glyph(fam, ach); if (g) p.aspect = +((g.x1 - g.x0 + 1) / (g.y1 - g.y0 + 1)).toFixed(2); }
  const sample = p.ko ? '다람쥐 헌 쳇바퀴' : p.la ? 'Hamburgefons' : null;
  if (sample) { const r = strokeStats(fam, sample); if (r) { p.straight = +r.s.toFixed(2); p.density = +r.d.toFixed(3); if (r.cv != null) p.cv = +r.cv.toFixed(2); } }
  const ich = p.ko ? ['가', '나', '다', '라', '마', '바', '사', '아', '자', '하'] : p.la ? ['n', 'm', 'u', 'r', 'v', 'w', 'x', 'z'] : null;
  if (ich) { const r = irregularity(fam, ich); if (r != null) p.irr = r; }
  if (p.la) { gx.font = `${GS}px "${fam}"`; const wi = gx.measureText('i').width, wm = gx.measureText('m').width, ww = gx.measureText('W').width; p.mono = wm && Math.abs(wi - wm) < wm * 0.03 && Math.abs(ww - wm) < wm * 0.03 ? 1 : 0; }
  return p;
}
window.fvProf = prof; window.fvTH = TH; window.fvRetag = () => { TAGS = FONTS.map((_, i) => tagsOf(i)); render(); FONTS.forEach((_, i) => drawTags(i)); };
(async () => {
  const todo = FONTS.map((f, i) => i).filter(i => !prof[FONTS[i].key]);
  todo.sort((a, b) => (rows[a].classList.contains('hide') ? 1 : 0) - (rows[b].classList.contains('hide') ? 1 : 0));
  let n = 0;
  for (const i of todo) {
    prof[FONTS[i].key] = await analyze(i); TAGS[i] = tagsOf(i); drawTags(i); n++;
    if (n % 25 === 0) { $('status').textContent = `생김새 분석 중 ${n}/${todo.length}`; SAVE('prof.' + PROF_VER, prof); render(false); await new Promise(r => setTimeout(r, 0)); }
  }
  if (todo.length) { SAVE('prof.' + PROF_VER, prof); render(false); }
  const err = FONTS.filter(f => prof[f.key]?.err).length;
  $('status').textContent = err ? `브라우저가 못 불러온 폰트 ${err}개` : '';
})();
if (SERVER) { const beat = () => fetch('/ping', { cache: 'no-store' }).catch(() => {}); beat(); setInterval(beat, 15000); }
})();
</script>
</body>
</html>
"""


def build_html(fonts, meta, server=False):
    m = dict(meta)
    m["server"] = server
    j = lambda o: json.dumps(o, ensure_ascii=False).replace("</", "<\\/")
    return TEMPLATE.replace("__DATA__", j(fonts)).replace("__META__", j(m))


# ──────────────────────────── 서버 ────────────────────────────

def pick_folder_dialog():
    script = '''tell application "Finder"
    activate
    set f to choose folder with prompt "미리볼 폰트 폴더를 고르세요"
end tell
return POSIX path of f'''
    try:
        r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=600)
    except subprocess.TimeoutExpired:
        return None
    if r.returncode != 0:
        return None
    return r.stdout.strip() or None


def _do_post(self):
    u = urllib.parse.urlparse(self.path)
    n = int(self.headers.get("Content-Length") or 0)
    body = self.rfile.read(n) if n else b""
    if u.path == "/api/user":
        try:
            data = json.loads(body.decode("utf-8"))
            os.makedirs(CONF_DIR, exist_ok=True)
            tmp = USER_JSON + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False)
            os.replace(tmp, USER_JSON)
            return self.send(200, '{"ok":true}')
        except Exception as e:
            return self.send(400, json.dumps({"error": str(e)}))
    return self.send(404, "{}")


def running_server():
    """이미 떠 있는 서버 URL (없으면 None)."""
    try:
        with open(SERVER_JSON, encoding="utf-8") as f:
            url = json.load(f)["url"]
        urllib.request.urlopen(url + "ping", timeout=1)
        return url
    except Exception:
        return None


def serve(open_browser=True):
    last = {"ping": None, "start": time.time()}
    lock = threading.Lock()

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def send(self, code, body, ctype="application/json; charset=utf-8"):
            if isinstance(body, str):
                body = body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            u = urllib.parse.urlparse(self.path)
            qs = urllib.parse.parse_qs(u.query)
            if u.path in ("/", "/index.html"):
                with lock:
                    fonts, meta = gather()
                return self.send(200, build_html(fonts, meta, server=True), "text/html; charset=utf-8")
            if u.path == "/ping":
                last["ping"] = time.time()
                self.send_response(204); self.end_headers(); return
            if u.path.startswith("/fonts/"):
                parts = u.path[len("/fonts/"):].split("/", 1)
                if len(parts) == 2:
                    fid, rel = parts[0], urllib.parse.unquote(parts[1])
                    for base in load_folders():
                        if fid_of(base) != fid:
                            continue
                        p = os.path.realpath(os.path.join(base, rel))
                        if p.startswith(os.path.realpath(base) + os.sep) and os.path.isfile(p):
                            with open(p, "rb") as fh:
                                return self.send(200, fh.read(), mimetypes.guess_type(p)[0] or "font/otf")
                return self.send(404, "{}")
            if u.path == "/api/folder/pick":
                last["ping"] = time.time() + 600  # 대화상자 동안 꺼지지 않게
                path = pick_folder_dialog()
                last["ping"] = time.time()
                if not path:
                    return self.send(200, json.dumps({"cancel": True}))
                folders = load_folders()
                path = path.rstrip("/") or path
                if path not in folders:
                    folders.append(path)
                    save_folders(folders)
                return self.send(200, json.dumps({"ok": True, "path": path}))
            if u.path == "/api/folder/remove":
                fid = (qs.get("fid") or [""])[0]
                save_folders([p for p in load_folders() if fid_of(p) != fid])
                return self.send(200, json.dumps({"ok": True}))
            if u.path == "/api/user":
                try:
                    with open(USER_JSON, encoding="utf-8") as f:
                        return self.send(200, f.read())
                except Exception:
                    return self.send(200, "{}")
            if u.path == "/api/refresh":
                last["ping"] = time.time() + 120
                with lock:
                    collect_installed(refresh=True)
                last["ping"] = time.time()
                return self.send(200, json.dumps({"ok": True}))
            return self.send(404, "{}")

    H.do_POST = _do_post
    try:
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H)
    except OSError:
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    port = srv.server_address[1]
    url = f"http://127.0.0.1:{port}/"
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(SERVER_JSON, "w", encoding="utf-8") as f:
        json.dump({"url": url, "pid": os.getpid()}, f)

    def watchdog():
        while True:
            time.sleep(5)
            now = time.time()
            if last["ping"] is None and now - last["start"] > 180:
                break
            if last["ping"] is not None and now - last["ping"] > 60:
                break
        log("브라우저 탭이 닫혀 서버를 종료합니다.")
        try:
            os.remove(SERVER_JSON)
        except OSError:
            pass
        srv.shutdown()

    threading.Thread(target=watchdog, daemon=True).start()
    log(f"폰트 미리보기: {url}  (탭을 닫으면 1분 뒤 자동 종료, Ctrl+C 로 즉시 종료)")
    if open_browser:
        webbrowser.open(url)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


# ──────────────────────────── main ────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="맥 폰트 미리보기")
    ap.add_argument("paths", nargs="*", help="등록할 폰트 폴더 (설치 안 된 폰트)")
    ap.add_argument("--refresh", action="store_true", help="설치 폰트 목록 캐시를 다시 읽는다")
    ap.add_argument("--out", help="정적 HTML 로 저장하고 브라우저는 열지 않는다")
    ap.add_argument("--no-open", action="store_true", help="브라우저를 열지 않는다")
    a = ap.parse_args()

    if a.paths:
        folders = load_folders()
        for p in a.paths:
            p = os.path.abspath(os.path.expanduser(p))
            if os.path.isfile(p):
                p = os.path.dirname(p)
            if os.path.isdir(p) and p not in folders:
                folders.append(p)
                log(f"폴더 등록: {p}")
        save_folders(folders)

    if a.refresh:
        collect_installed(refresh=True)

    if a.out:
        fonts, meta = gather()
        with open(a.out, "w", encoding="utf-8") as f:
            f.write(build_html(fonts, meta, server=False))
        log(f"저장: {a.out}")
        return

    url = running_server()
    if url:
        log(f"이미 떠 있는 서버를 연다: {url}")
        if not a.no_open:
            webbrowser.open(url)
        return
    gather()  # 첫 실행이면 여기서 20초 걸린다 (브라우저 열기 전에 끝내 둔다)
    serve(open_browser=not a.no_open)


if __name__ == "__main__":
    main()
