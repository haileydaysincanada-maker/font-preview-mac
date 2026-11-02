# 폰트뷰어 변경 이력

## 2026-11-01 — v1.3.0: Typeface Scout (Muse Spark 비전 태깅 + 브리프·사진 검색)

Meta Global AI Developer Hackathon 2026 출품분. 새 파일 `native/Sources/Scout.swift`(≈1,400줄)·`WebFont.swift`(눈누 목록·WOFF 디코드·woff2 웹뷰 렌더), 사이드바 「AI 로 찾기 → ✦ Typeface Scout」, 파일 메뉴 ⌘⇧O·⌘⇧V.
- **태깅**: 패밀리 대표 1벌 × 설치 폰트(불러오기 실패 제외) → 896×280 RGB JPEG(영문 팬그램 + 한글 팬그램, 글리프 없는 글자는 빼고 그림) → `muse-spark-1.3` Chat Completions + `json_schema`. 동시 4개, 429/5xx 지수 백오프. 캐시 `~/Library/Application Support/fontviewer/scout_tags_v1.json`. 실측 663 패밀리 10분 $3.13.
- **검색**: 태그 1줄/패밀리 카탈로그(≈60k 토큰)를 system 에 고정 → 프롬프트 캐시 적중(첫 $0.08 → $0.01). 결과 ≤12 + score + why(브리프 언어). 키 없음·실패 시 로컬 키워드 폴백.
- **사진→브리프**: 사진(긴 변 1024 JPEG) → `describe`(brief/scripts/notes) → 브리프 칸 채우고 바로 검색. 진입 = 📷 메뉴(열기 패널/클립보드)·창 드롭·파일 메뉴. 사진 1장 ≈$0.005.
- **보드**(11/1 낮, 헤일리 «폰트 조합으로 샘플 이미지가 보이면 브레인스토밍에 좋겠다» + 자막 모션 판매 페이지의 샘플 타일 그리드 참고): 검색 응답 스키마에 `copy`(headline/sub/body + _en 짝, 가상 이름), 결과별 `palette`(12색 이름 enum), `pairs`(headline_id/sub_id/body_id/why ≤3) 추가 — 호출 수 그대로(max_tokens 6000). 앱이 카피를 실제 폰트로 렌더해 4:3 포스터 타일 + 조합 카드 3장(`ScoutBoard`·`ScoutTile`·`ScoutPairCard`). 영문 전용 폰트엔 _en 카피. 보드/목록 토글, 타일 클릭 = 기존 줄 팝오버. 빈 상태에 예시 브리프 칩 6개(`ScoutView.examples`). 🔴 이미지 생성 모델로 목업 만들지 않는다 — 글자가 가짜가 된다.
- **장르 인식 카피 + Muse Image 배경 + 레이아웃 6종**(11/1 낮, 헤일리 «세일 POP 인데 가게 이름이 제목이면 안 되고 상품·가격이 메인이어야» + «캔바처럼 이미지·다양한 레이아웃이 있어야 스카우트가 의미 있다»): `copy` 가 `{genre, align, lines[2~4]{role,size(xl/l/m/s),text,text_en}}` 로 바뀜 — 모델이 브리프 장르를 먼저 판단해 세일 POP 은 kicker/상품명/가격(xl)/조건, 로고는 이름(xl)/태그라인/문장, 표지는 제목/부제/바이라인 식으로 줄 구조를 짠다. `ScoutCopyStack` 이 줄 크기별 폰트로 렌더(조합 카드 = xl·l 제목폰트, m 부제폰트, s 본문폰트). 조합마다 `layout`(overlay·split·band·badge·frame·poster)과 `image_prompt` 를 받고, 앱이 `POST /v1/images/generations`(`muse-image-1.0`, 1536×1024 jpeg, reasoning low, 검색 도구 off)로 배경 1장씩 병렬 생성(장당 $0.01·7~10초, 도착 순 표시, 「배경 이미지」 체크로 끄기). 글자는 전부 앱이 실제 폰트로 얹으므로 이미지 생성이어도 글자가 가짜일 수 없다. 팔레트에 sale-red·yellow-black·cream-red 추가. `ScoutUsage.images` 추가(구 캐시 파일 호환 위해 decodeIfPresent). 실측(정육 세일 포스터): «주말 한정 3일 특가 / LA갈비 & 삼겹살 / $9.99/lb / 토·일 한정 · 소진 시 종료», badge·band·poster + 고기 사진 2·레트로 일러스트 1, 검색 $0.09 + 이미지 $0.03.
- **아트디렉터 2차 심사 + 가격 슬롯**(11/1 오후, 헤일리 «디자인 감각 없는 사람이 추천한 느낌 — 너무 두껍고 장식적이라 글자·숫자가 안 읽힌다. 나라면 제목은 더 rough 한 걸(티몬체·연제오방맛길체류)»): 1차 검색이 뽑은 후보 12개를 **실제 카피(제목 줄 + 가격 줄)로 렌더**(`ScoutRender.copyCard`)해 Muse Spark 에 다시 보여주고(`ScoutAPI.direct`, 시스템 프롬프트 = AD 원칙: 한눈에 읽히는 글은 가독성 > 개성, 숫자 명확성, 두꺼움 OK·장식 NO, 거친 질감 제목 환영, 2000년대 무료 폰트 클리셰 회피, 한글 완성도, 역할 대비) ① 재순위 + 가독성 1~5 + role_fit(headline/price/sub/body/avoid) + 디자이너 납득 한 줄 ② **방향 2~3개**(이름·분위기·팔레트·레이아웃·제목/가격/부제/본문 폰트·배경 프롬프트). 보조 역할은 중립 산세리프 목록(태그 기반 ≤40)에서 골라도 됨. 조합 카드가 방향 카드로(이름·분위기 표시, 가격 줄은 `price` 폰트), 타일엔 가독성 ●●●○○ + 역할 배지, avoid 는 뒤로·흐리게. 1차 실패와 독립(2차 실패 시 1차 결과 유지). 비용 = 2차 호출 ≈ $0.06~0.08(후보 이미지 12장 ≈ 5k 토큰 + 추론), 검색+심사 합 ≈ $0.10, +6~8초. 실측: 방향 «주말 고기 대잔치 / 정겨운 동네 정육점 / 깔끔한 주말 특가», 가격 폰트 210 수퍼사이즈·배민 도현·강원교육튼튼 으로 «30% OFF» 전부 판독 가능.
- **타일에도 방향 배경 + 👍/👎 취향 학습**(11/1 오후, 헤일리 «그림·이미지는 왜 다 빠졌어» → 타일이 단색이었음 / «👍/👎 로 선호·기피를 쌓아 다음 심사에 넣는 것 필요»): 2차 심사 ranking 에 `direction`(1-based 소속 방향) 추가 → 타일은 그 방향의 배경 이미지·레이아웃·팔레트를 **재사용**(추가 비용 0, 「배경 이미지」 끄면 단색). 레이아웃 6종 렌더를 `ScoutMockup` 하나로 합쳐 조합 카드(역할별 폰트)·타일(폰트 1벌)이 공유. 👍/👎 = `ScoutPrefButtons`(타일·목록 줄), 패밀리 대표 id 로 `scout_tags_v1.json` 의 `prefs` 에 저장(같은 버튼 재클릭 = 해제, 「더 보기 → 👍/👎 기록 지우기」). 프롬프트 반영: `tasteText()` 가 LIKED/DISLIKED 를 태그 요약과 함께 1차 검색 user 턴(캐시 프리픽스 보존)과 2차 심사에 넣어 모델이 «결»을 일반화하게, 👎 폰트는 결과에서 코드로도 제외. 실측: 👎 클릭 → 상태줄 «기억했어요 — 다음 검색부터 이 폰트는 빼고, 비슷한 결도 피해요 (👍0 · 👎1)».
- **눈누(noonnu.cc) 통합**(11/1 오후, 헤일리 «추천 폰트에 미리보기 안 되는 게 너무 많고 신규도 없다 — 한글 폰트는 눈누에서 못 불러와?»): `native/build_noonnu.py` 가 눈누 목록 전 페이지(24장/페이지·약 50페이지)와 상세를 긁어 `noonnu.json`(1,232개: woff2 682·woff 511·기타 39, 굵기별 웹폰트 URL·라이선스 요약표 허용 항목·배포처 다운로드 링크·썸네일) → 앱 번들 + `CONF_DIR/noonnu.json`(앱의 「눈누 새로고침」이 목록만 다시 받아 새 폰트 추가, 상세는 기존 유지). 카탈로그 로더가 눈누 개별 폰트를 합치고 구 «묶음 링크» 22항목을 치운다(Google/GitHub 에 이미 있는 이름은 중복 제외). 미리보기: **woff → 앱이 zlib 풀어 sfnt 복원(`WOFF.decode`) → CoreText 라이브** / **woff2 → 숨은 WKWebView 캔버스(`WebFontRenderer`, FontFace API → canvas → PNG, 2x)** — 글자는 진짜 폰트, 이미지라 선택만 안 됨. 🔴 `document.fonts.check()` 는 모르는 패밀리에 true 라 로드 여부를 직접 기록해야 한다(처음엔 전부 명조 폴백으로 그려졌음). 추천 줄에 눈누 배지·허용 용도 N/7·다운로드 페이지·눈누 페이지 버튼. 새 파일 `Sources/WebFont.swift`.
- **Scout × 눈누**: 미설치 눈누 폰트 중 woff/otf/ttf(CoreText 가능, ≈516개)를 Scout 후보로 — 「더 보기 → 눈누 폰트 태깅」이 **썸네일(이름을 그 폰트로 그린 PNG)로 태깅**(폰트 파일 안 받음, 개당 ≈$0.004, «(thumb)» 표기), 검색 카탈로그에 «NOT INSTALLED (Noonnu, free)» 줄로 들어가 최대 4개까지 결과·조합에 섞인다. 뽑히면 그때 woff 를 받아 가상 `FontItem`(source .folder, id nn:…)으로 타일·조합 카드·2차 심사까지 똑같이 렌더. 타일·줄에 «미설치 · 눈누» 배지 + ↓다운로드·눈누 버튼. woff2 는 Scout 제외(추천 탭 미리보기만). 11/1 전체 태깅 실행: 405개 $1.34 → 태그 총 1,068.
- 🐛 **추천 탭 Google 미리보기가 이름 글자만 그 폰트로 그려지던 버그**(11/1 헤일리 발견): 문구가 한글뿐이면 영문 폰트 줄엔 폴백 팬그램이 *표시*되는데 서브셋 요청엔 원문(한글)+이름+숫자만 넣어서 팬그램 글자가 서브셋에 없었다. `subsetText(c)` = 그 줄에 실제 그려질 문구(`latinOnly` 적용·폴백 포함)로 요청·캐시 키 구성, 「영문 전용」 토글 변경 시에도 다시 받음. 기본 문구에 영문이 섞여 있어 10/16엔 안 보였던 것.
- 한글 폰트인데 샘플이 영문뿐이면 결과 미리보기 앞에 한글 기본 문구를 붙인다(`previewText`). 키 = Keychain(`com.haileydayz.fontviewer.scout`), 개발 폴백 `MODEL_API_KEY`, 테스트 훅 `SCOUT_TEST_PHOTO`.
- 🔴 **Muse Spark 는 추론 토큰을 먼저 쓰고 그게 `max_tokens` 에 포함된다** — 60 주면 본문이 빈 채 끝난다(태깅 1600·검색 4000·`reasoning_effort: low`; `none` 은 400). minimal 은 flared serif 를 놓쳐 low 로 고정.
- 🔴 **`-contributor` 모델 금지**(이미지가 학습에 제공됨). 키 값은 채팅·로그·커밋에 절대 출력 금지.
- 자동화 한계: 열기 패널(별도 프로세스)·클립보드·드래그는 컴퓨터 제어 도구가 막아서 사진 진입 3개는 공통 함수를 `SCOUT_TEST_PHOTO` 로 검증 — 실제 패널·드롭·붙여넣기는 손 검증 필요.
- Store: `representatives(installedOnly:)`·`representative(of:)`·`item(id:)` 추가, nav `scout`. 빌드 27.
- **릴리스**: GitHub `v1.3.0` + `FontPreview-1.3.0.zip`(처음 빌드 27 → 같은 날 밤 **빌드 30 으로 교체** = 아래 ⌘V 붙여넣기 수정, 애드혹 서명, 압축 해제본 `codesign --verify --deep --strict` 통과). 해커톤 제출 폼이 공개 레포를 요구해 제출 전에 올림. README 정정 2곳(«이미지 생성 없음» → 글자만 생성 안 함·배경 장면 설명도 API 로 나감 / 눈누 태깅 ≈500 → ≈400개·$0.003).
- 🐛 **클립보드 사진 붙여넣기 2건**(11/1 저녁 헤일리 손 검증 «텍스트 칸에 클립보드 이미지를 붙이면 안 보인다 / 사진 넣는 곳에 에러가 있는 듯»): ① 브리프 칸에서 ⌘V 하면 글자 칸이 이미지를 버려 아무 일도 안 일어났다 → Scout 화면에서 ⌘V 를 가로채 클립보드에 사진이 있고 같이 실린 글자가 없거나 URL·파일 이름뿐이면 사진 찾기로 보낸다(본문 글자가 같이 있으면 평소처럼 글자 붙이기). ② Finder 에서 이미지 파일을 복사해 붙이면 `NSImage(pasteboard:)` 가 사진 대신 **파일 아이콘**(1024×1024)을 돌려줬다 → 파일 URL 을 먼저 읽어 실제 사진을 쓰고, 이미지가 아닌 파일이면 무시(`clipboardPhoto`). 모의 클립보드 7종(일반 JPEG·Finder JPEG·Finder txt·Safari·Chrome·글+이미지·글만) 판정 확인. 📷 메뉴 항목에 «(⌘V)», 빈 화면 안내에 «복사해서 ⌘V». 빌드 29.
  - 빌드 29 에서도 ⌘V 가 안 됐다(헤일리 «커맨드 V 붙여넣기가 안 돼», 크롬에서 끌어다 놓기는 됨): **한글 2벌식 입력 중엔 V 키의 `charactersIgnoringModifiers` 가 «ㅍ»**(현재 자판 `2SetHangul`, UCKeyTranslate 로 확인)라 «v» 비교가 늘 실패. → `ScoutView.isPasteKey` — 라틴 글자가 오면 그 글자로, 아니면 물리 키 위치(V = keyCode 9)로 판단. 합성 이벤트 6종(한글 ⌘ㅍ·ABC ⌘v·드보락 ⌘k·⌘⇧V·⌘ 없는 ㅍ·한글 ⌘ㅊ) 판정 OK. 빌드 30.
- 🔧 `build.sh` 서명: 데스크톱이 iCloud 파일 프로바이더로 동기화돼 번들에 FinderInfo 가 즉시 다시 붙으면서 제자리 서명이 «detritus not allowed» 로 실패(빌드 28). → 임시 폴더 사본에서 서명·검증하고 그 사본으로 `FontPreview-<버전>.zip` 을 만든 뒤 제자리에 되돌린다. 릴리스 zip 은 이제 빌드가 직접 만든다.

## 2026-10-17 — 릴리스 zip 서명 수정(같은 v1.2.1, 빌드 6으로 재업로드) + macOS 15 여는 법

- 블로그 검수 중 발견: 배포 zip 의 앱이 **서명이 아예 없었다**(arm64 링커 서명만). 애플 실리콘 맥에서 «손상되었기 때문에 열 수 없습니다»가 뜨고 우클릭·「그래도 열기」로도 안 풀릴 수 있는 상태. 인텔 맥(헤일리)에서는 그냥 열려서 몰랐다.
- 원인: `build.sh` 의 `codesign ... >/dev/null 2>&1 || true` 가 «resource fork, Finder information, or similar detritus not allowed»(폴더 xattr 찌꺼기)로 실패하는 걸 숨기고 있었다.
- 수정: 서명 전 `xattr -cr`, 서명 뒤 `codesign --verify --deep --strict` 실패 시 빌드 중단. zip 은 `ditto -c -k --norsrc --noextattr --keepParent` 로(xattr 안 싣기). 압축 해제본 검증 통과(universal 두 슬라이스 모두 adhoc, sealed resources).
- 코드 변경은 없어서 버전은 1.2.1 그대로, 릴리스 자산만 교체(911,603바이트). 블로그 캡처·본문이 1.2.1 기준이라 버전을 올리지 않음.
- README: macOS 15 세쿼이아부터 우클릭 우회가 막혀 시스템 설정 → 개인정보 보호 및 보안 → 「그래도 열기」 경로를 추가(애플 지원 102445·개발자 공지 2024-08-06).

## 2026-10-16 (밤) — v1.2.1: 어두운 배경에서 폰트 이름 줄이 안 보이던 버그

- 블로그용 캡처 중 발견: 글자/배경 색을 바꿔 **검은 배경**으로 두면 각 줄의 폰트 이름·스타일·분류 칩이 시스템 글자색(어두운 회색) 그대로라 거의 안 보였다.
- 수정: `Store.bgIsDark`(배경 휘도 < 0.5) → 목록·추천 목록에 `.environment(\.colorScheme, .dark/.light)`, 행 안의 `Color(nsColor: .labelColor)` → `Color.primary`. 배경이 밝으면 그대로, 어두우면 이름·칩·팝오버가 밝게.
- 헤일리 «버그 발견했으면 깃허브에도 수정한 거 올려» → 커밋·푸시·릴리스 v1.2.1.

## 2026-10-17 — 홍보: 링크드인(영어)·헤일리데이즈 스레드

- 링크드인 영어 글(사진 3장, 링크는 첫 댓글) https://www.linkedin.com/feed/update/urn:li:activity:7517051621013458944/
- 스레드 @haileydayz_ https://www.threads.com/@haileydayz_/post/DelEqMHgJ8B — 한국어 화면 캡처 3장(docs/ko-*.jpg, 저장소 raw URL 로 캐러셀), 주제 「폰트」, 첫 답글에 깃허브 링크. 캡처 때 마우스 포인터가 분류 이름을 가려서 빈 곳에 두고 키보드로 이동해 다시 찍음.
- 인스타 릴스는 보류(피드 타겟 = 아이패드 기록러, 맥 전용 앱이라 거리) → 떡상이 조사부터 하는 기획 세션 카드만 올림.

## 2026-10-16 (밤 4) — v1.2: 영어 UI · 유니버설 빌드 · 영문 README

헤일리 «한글 UI면 외국인 못 쓰잖아, 언어 선택 — 영어는 필수».
- `Sources/L10n.swift`: `T("한국어","English")` 한 함수로 전 화면 문구 이중화. 기본 = 시스템 언어(한국어면 ko, 아니면 en), 🌐 메뉴(상단 오른쪽)·도움말 → Language 로 전환, `user.json state2.ui` 에 기억. `ContentView.id(uiLang)` 로 전환 즉시 전체 재구성.
- 분류·굵기 이름 `Cat.name()`(ko/en), 라이선스 표기 `licenseText()`, 카탈로그 설명 139개 영문(`catalog_src.DESC_EN` → `descEN`), 영어 UI 에선 영문명을 앞에·한글명을 뒤에.
- 맥 메뉴바 제목(파일·편집·보기…)은 시스템 언어를 따른다 — 앱이 바꾸지 않음.
- `build.sh` 유니버설: x86_64·arm64 따로 컴파일 후 `lipo -create`. 인텔 맥에서 arm64 크로스컴파일 OK(CLT swiftc).
- README 를 영문 사용법 + 스크린샷 3장(docs/) 앞세우고 한국어 노트는 뒤로.

## 2026-10-16 (밤 3) — GitHub 공개

- https://github.com/haileydaysincanada-maker/font-preview-mac (public, MIT). 이 폴더가 git 저장소(main). `.app`·zip·linkedin 초안·.DS_Store 는 .gitignore. 릴리스 v1.1 에 `FontPreview-1.1.zip`(빌드 2, 미공증 → 우클릭 열기). 커밋 이메일은 hello@haileydayz.com(로컬 설정). 빌드 후 배포 절차: `native/build.sh` → `ditto -c -k --keepParent "폰트 미리보기.app" FontPreview-<ver>.zip` → `gh release create v<ver> <zip>` → 커밋·푸시.

## 2026-10-16 (밤 2) — 버전·빌드 번호·제작자 표기

- 문의 메일 `CONTACT="hello@haileydayz.com"`(build.sh) → 사이드바 아래 「문의 · 주소」 링크(mailto, 제목에 버전·빌드 자동), 정보 창 저작권 줄, 도움말 메뉴 「문의 메일 보내기」·「사용법 (README)」. 비즈니스 주소를 쓴 이유 = 대외 표기엔 지메일 금지 규칙.
- `build.sh` 가 `native/BUILD_NUMBER` 를 빌드마다 +1 해서 `CFBundleVersion` 에, 버전은 `VERSION` 변수(지금 1.1), 제작자 `AUTHOR="Hailey (haileydayz)"`. 정보 창(⌘ 폰트 미리보기 정보)의 저작권 줄 = «© 2026 Hailey (haileydayz) · 빌드 N (날짜)», 사이드바 맨 아래에도 «폰트 미리보기 v1.1 · 빌드 N (날짜) · Hailey». 이름 바꾸려면 build.sh 의 AUTHOR 한 줄.

## 2026-10-16 (밤) — 추천 미리보기 + 한글 없는 폰트는 영문 문구만

- **추천 미리보기**: 설치 안 하고 `~/Library/Caches/fontviewer/preview/` 에 파일을 받아 `CGDataProvider → CGFont → CTFontCreateWithGraphicsFont` 로 그린다(어디에도 등록하지 않아 설치 목록에 안 섞임). 프리텐다드·SUIT 는 jsDelivr 직링크(catalog `preview`, 빌드 때 검증 — URL 의 `@` 를 퍼센트 인코딩하면 404 나므로 safe 에 포함).
- 🔴 **Google Fonts 함정**: `css?family=X` 를 브라우저 아닌 UA 로 받으면 TrueType 직링크가 오지만 **영문 글자만 든 축소판**이다(도현체 23KB, cmap 에 한글 없음) → 한글이 시스템 폰트로 대체돼 «적용 안 된» 것처럼 보였다(헤일리가 바로 잡아냄). 해결 = `&text=<문구>` 로 **문구 글자만 든 서브셋**(한글 포함, 50~60KB) 요청. 이 URL 은 `fonts.gstatic.com/l/font?kit=…` 꼴이라 `.ttf` 로 끝나지 않는다(정규식 함정 2). 캐시 키 = 폰트 + 문구 해시, 문구 입력 0.6초 디바운스.
- **영문 문구 규칙 확장**: 영문 전용 토글뿐 아니라 「영문 전용 폰트」 그룹에서, 그리고 어느 보기에서든 **그 폰트에 한글 글리프가 없으면** 영문·숫자만 그린다.
- 폴더 모드로 프로세스에 등록한 폰트가 「전체 설치 폰트」에 섞이던 것 수정(등록 폴더 경로 아래 파일은 설치 목록에서 제외).

## 2026-10-16 — 추천 폰트 + 내 취향 추천 + 원클릭 설치

헤일리 «설치하면 좋을 폰트 추천… 1,2 둘 다».
- **카탈로그 139개**(한글 Google 35·GitHub 2·배포처 22, 영문 Google 64, Adobe 16). `catalog_src.py` 에서 고르고 `build_catalog.py` 가 **링크를 전부 실제 접속해 검증**(Google 슬러그는 google/fonts 레포 트리 2,064개와 대조, GitHub 릴리스는 latest 에셋 정규식 매칭, 배포처는 HTTP 200, 실패하면 눈누 검색 URL 로 폴백·그것도 안 열리면 제외). 에스코어 사이트는 SSL 인증서 불일치로 눈누 검색으로 폴백됨.
- **원클릭 설치**: Google = `api.github.com/repos/google/fonts/contents/<dir>/<slug>` 의 ttf/otf 내려받기 · GitHub 릴리스 = latest zip → `ditto -xk` → otf 우선(없으면 ttf), web/woff/variable 제외. `~/Library/Fonts/<영문명>/` 에 넣고 `CTFontManagerRegisterFontsForURL(.user)` 후 목록 재로딩. 실측: 독도체 2.1MB 설치 → 목록 664벌로 즉시 반영·추천에서 사라짐(테스트 후 삭제).
- **설치 여부 판정** = 카탈로그 `match` 문자열이 설치 폰트의 패밀리(한글·영문)·PS 이름에 포함되는지. 그래서 배민·카페24 같은 묶음 항목은 한 벌만 있어도 「설치됨」.
- **취향 점수** = (★ ∪ 세트) 폰트들의 태그 빈도(분류 9종 + 굵기) 합 + 한글/영문 비율 보너스 0.5. 3개 미만이면 안내만. 이유 문구는 상위 태그 2개.
- 🔴 GitHub API 는 비로그인 시간당 60회 — 설치 한 번에 1~2회라 보통 문제없지만, 한 번에 수십 개 깔면 403 이 날 수 있다(그땐 1시간 뒤).

## 2026-10-15 (밤 2) — 언어 토글

- 「영문 전용」일 땐 미리보기 문구에서 한글·한자·가나를 빼고 영문·숫자만 그린다(남는 글자가 없으면 영문 기본 문장). 헤일리 «영문 전용 눌렀을 때 샘플 텍스트가 영어만 보이게».
헤일리 «분류 보다가 한글 안 되는 게 많다» → 분류 헤더 줄 오른쪽에 **전체/한글/영문 전용** 세그먼트. 어느 보기(분류·세트·폴더·즐겨찾기)에서든 기본 필터로 겹쳐 걸리고 사이드바 카운트에도 반영, `user.json` state2.lang 에 기억. 「붓글씨·캘리」 44 → 한글 눌렀을 때 영문 스크립트 폰트가 빠지는 것 확인.

## 2026-10-15 (밤) — v3: 네이티브 맥 앱 (SwiftUI, Xcode 없이 swiftc 빌드)

헤일리 «네이티브앱으로 해줘. 그리고 어도비 폰트도 보이는거야?» → `native/` 에 Swift 소스 5개(Models·Measure·FontLoader·Store·Views+App), `build.sh` 로 `폰트 미리보기.app` 빌드. 웹판은 `web/` 로 이동(보존).
- 폰트 목록 = `CTFontCollectionCreateFromAvailableFonts` → 1,870벌 0.2초(system_profiler 20초 대기 소멸). **Adobe Fonts 835벌 포함** 확인. 🔴 `CTFontManagerCopyAvailableFontDescriptors` 는 Swift 에서 이름이 안 보인다(컬렉션 API 로).
- 패밀리명 = `CTFontCopyLocalizedName`(한글), 영문명은 `CTFontCopyName` 으로 따로 보여준다.
- 생김새 측정은 웹판 알고리즘을 CoreGraphics 알파 비트맵으로 포팅(픽셀 기준·임계값 동일). 글리프 유무는 폴백 비교 대신 `CTFontGetGlyphsForCharacters`. 분류 수 — 웹 vs 네이티브 — 두꺼운 106→94, 고딕 263→238 등 10% 안쪽 차이(래스터라이저 차이).
- 폴더 폰트는 `CTFontManagerRegisterFontsForURL(.process)` 로 이 프로세스에만 등록 → `.ttc` 전 서체가 다 보인다(웹판은 첫 서체만).
- 사용자 데이터는 웹판과 **같은 `user.json`** 을 읽고 쓴다(즐겨찾기·세트·문구·수동 분류 이어받음). 검색어는 다음 실행에 안 이어받음.
- 함정: `CGContext(data:…)` 는 Swift 에서 `space: nil as CGColorSpace?`, `bitmapInfo: CGBitmapInfo(rawValue:)` 로 써야 컴파일된다 · SwiftUI 컴파일은 CLT swiftc 로 20~40초 · 사이드바 `List(selection:)` 에 `String?` 바인딩.
- 앱 아이콘은 Pillow 로 「가A」 1024px → `iconutil` (native/AppIcon.icns).

## 2026-10-15 (저녁) — v2: 윈도우판 레이아웃 + 생김새 자동 분류 + 서버 통합

헤일리 «폰트 생김새로 스타일별로 고를 수 있게, 왼쪽에 인덱스 메뉴» → 윈도우 회사 컴퓨터의 「폰트 미리보기 v1.1」 스크린샷 구도 그대로.
- **생김새 측정(캔버스)**: 굵기=`ㅣ`/`l` 획 두께(em) · 명조=획 끝 발 비율≥1.7 또는 획 대비≥2.2 · 둥근=`ㅡ`/`-` 모서리 채움≤0.5 · 손글씨=`가나다라마바사아자하` 상하 들쭉날쭉(한글 ≥0.015em, 영문 ≥0.02em) 또는 직선 비율<0.5 · 붓글씨=이름 힌트 또는 직선 비율<0.3 · 장평=`한`/`H` 가로세로비. 기준값은 설치 폰트 50여 개(Pretendard·나눔·배민·카페24·Apple 계열) 실측으로 보정.
- 🔴 **안 되는 것 확인**: 획 두께 분산(런 길이 CV·국소 두께 CV)으로 붓/펜 구분 — 나눔붓 0.51 vs 나눔펜 0.49 로 변별 0. 얇은 폰트가 픽셀 양자화 때문에 오히려 높게 나옴. 그래서 붓글씨는 이름 힌트 중심.
- 숨은 함정: `system_profiler` 스타일명이 **한글 현지화**(가는체·일반체·볼드체·진한 볼드체)라 영문 regex 만으론 못 잡는다 → 추가. `<button>` 안에 `<button>` 을 넣으면 파서가 깨뜨려 `querySelector` 가 null 이 된다(사이드바 ✕ 는 span). 폴더 폰트가 설치 폰트와 같은 패밀리명이면 「패밀리 묶기」에 가려진다 → 패밀리 키에 폴더 id 포함.
- **서버 통합**: 설치 폰트 + 등록 폴더를 한 페이지로. `/api/folder/pick`(osascript `choose folder`) · `/api/folder/remove` · `/api/refresh` · `/ping`(15초, 60초 끊기면 종료). 중복 실행 방지 = `~/Library/Caches/fontviewer/server.json` 의 URL 에 ping 되면 그 창만 연다. `.app` 은 `nohup … &` 로 띄워 바로 빠진다(서버가 계속 돌아야 하므로 `do shell script` 를 블로킹으로 두면 앱이 멈춘다).
- 🔴 **포트가 매번 바뀌면 브라우저 저장소가 실행마다 초기화된다**(origin 이 달라짐 — 검증 중 즐겨찾기·분석이 날아가는 걸로 발견). → 포트 **48721 고정**(막혀 있으면 랜덤 폴백) + 즐겨찾기·세트·문구·수동 분류·화면 상태는 `/api/user`(GET/POST) 로 `~/Library/Application Support/fontviewer/user.json` 에 저장. 분석 결과(prof)만 localStorage.

## 2026-10-15 — 신설 (헤일리 «회사에서 쓰는 NexusFont 를 맥에서도»)

- 구조 결정: 네이티브 앱 대신 **파이썬 → HTML 한 장 → 브라우저**. 의존성 0, 한글 안 깨짐, 검색·크기·문장 변경이 즉시.
- 폰트 목록 = `system_profiler SPFontsDataType -json`(20초) + 캐시. 캐시 무효화는 폰트 폴더(시스템·/Library·~/Library·Adobe CoreSync)의 파일 수·mtime 서명으로.
- 폰트 지정은 `font-family` 이름이 아니라 `@font-face { src: local("PS이름"), local("풀네임") }` — 스타일별로 정확히 잡힌다. 실측 1,870/1,870 로드.
- **한글 지원 검사**는 캔버스 픽셀 비교: `"폰트", AppleMyungjo` 와 `"폰트", "Apple SD Gothic Neo"` 로 «한글»을 그려 같으면 글리프 있음. Helvetica·Arial = 없음, 나눔·Pretendard·Rix = 있음 확인.
- 숨김 시스템 폰트(`.`으로 시작, 1,367개)는 제외 — 브라우저가 못 쓴다. PS 이름 중복 58개는 1개만.
- 폴더 모드(미설치 폰트): 크롬이 `file://` 폰트를 CORS 로 막아서 로컬 HTTP 서버로 서빙. 페이지가 15초마다 `/ping`, 60초 끊기면 서버 자동 종료. name 테이블 직접 파싱(ttf/otf/ttc, 한국어 이름 우선)으로 패밀리·스타일 표시.
- `폰트뷰어.app`: osacompile 결과엔 폴더 드롭 타입이 없어 Info.plist 에 `public.folder`·`public.font` 추가. 수정 후 `xattr -cr` 안 하면 codesign 이 «detritus» 로 실패한다.
- 🔴 되돌리지 말 것: ①`.app` 은 폴더 안 `.command` 를 부르므로 폴더 구조 유지 ②캐시 경로는 `~/Library/Caches/fontviewer` (작업 폴더에 산출물 안 남김).
