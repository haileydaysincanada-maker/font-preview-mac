# 폰트뷰어 변경 이력

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
