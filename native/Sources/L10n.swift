import Foundation

/// 화면 언어. 기본은 맥 시스템 언어(한국어면 ko, 아니면 en). 메뉴/🌐 에서 바꾸면 user.json 에 기억.
enum UILang: String, CaseIterable {
    case ko, en
    static var current: UILang = systemDefault()
    static func systemDefault() -> UILang {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("ko") ? .ko : .en
    }
    var title: String { self == .ko ? "한국어" : "English" }
}

/// T("한국어 문구", "English text")
@inline(__always) func T(_ ko: String, _ en: String) -> String { UILang.current == .ko ? ko : en }

/// 카탈로그에 든 한국어 라이선스 표기 → 영문
func licenseText(_ s: String) -> String {
    guard UILang.current == .en else { return s }
    let map: [String: String] = [
        "SIL OFL (상업용 무료)": "SIL OFL (free, commercial OK)",
        "Apache 2.0 (상업용 무료)": "Apache 2.0 (free, commercial OK)",
        "Ubuntu Font License": "Ubuntu Font License",
        "SIL OFL": "SIL OFL",
        "상업용 무료": "Free for commercial use",
        "상업용 무료 (카페24 라이선스)": "Free for commercial use (Cafe24 license)",
        "상업용 무료 (우아한형제들)": "Free for commercial use (Woowa Bros.)",
        "상업용 무료 (교육부 공공누리)": "Free for commercial use (KR Ministry of Education, KOGL)",
        "상업용 무료 (마포구)": "Free for commercial use (Mapo-gu)",
        "폰트마다 다름 — 페이지에서 확인": "Varies per font — check each page",
        "Adobe Fonts (Creative Cloud 구독에 포함, 상업용 가능)": "Adobe Fonts (included with Creative Cloud, commercial OK)",
    ]
    return map[s] ?? s
}
