import SwiftUI
import AppKit

// GitHub README 안내: on English systems the UI starts in English; 🌐 menu switches.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in for u in urls { Store.shared.addFolder(u) } }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in Store.shared.saveUserNow() }
    }
}

@main
struct FontViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store.shared
    var body: some Scene {
        WindowGroup(T("폰트 미리보기", "Font Preview")) {
            ContentView().environmentObject(store).frame(minWidth: 920, minHeight: 560)
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(T("폰트 폴더 추가…", "Add Font Folder…")) { store.pickFolder() }.keyboardShortcut("o")
                Button(T("폰트 다시 읽기", "Reload Fonts")) { store.reloadFonts() }.keyboardShortcut("r")
            }
            CommandGroup(replacing: .help) {
                Picker(T("화면 언어", "Language"), selection: $store.uiLang) { ForEach(UILang.allCases, id: \.self) { Text($0.title).tag($0) } }
                Divider()
                Button(T("문의 메일 보내기", "Contact by Email") + " (\(AppInfo.contact))") { if let u = AppInfo.mailURL { NSWorkspace.shared.open(u) } }
                Button(T("사용법 (README)", "User Guide (README)")) {
                    let readme = URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent().appendingPathComponent("README.md")
                    if FileManager.default.fileExists(atPath: readme.path) { NSWorkspace.shared.open(readme) } else { store.showToast(T("README 를 못 찾았어요 (앱을 fontviewer 폴더 밖으로 옮겼나요?)", "README not found (was the app moved out of the fontviewer folder?)")) }
                }
            }
        }
    }
}
