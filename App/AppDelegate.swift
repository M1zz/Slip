import AppKit
import Carbon.HIToolbox
import SlipCore

final class AppDelegate: NSObject, NSApplicationDelegate {

    weak var appState: AppState?

    private var hotkey: GlobalHotkey?
    private var quickCapturePanel: QuickCapturePanel?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar status item — always visible even when main window is closed.
        menuBar = MenuBarController(
            onQuickCapture: { [weak self] in self?.showQuickCapture() },
            onShowMain: { [weak self] in self?.activateMainWindow() }
        )

        // Global hotkey: ⌥⌘Space → Quick Capture. Tune in Settings later.
        hotkey = GlobalHotkey(keyCode: UInt32(kVK_Space), modifiers: [.command, .option]) { [weak self] in
            self?.showQuickCapture()
        }
        hotkey?.register()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.unregister()
    }

    // Re-open the main window when the user clicks the dock icon after closing it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { activateMainWindow() }
        return true
    }

    func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.title == "Slip" {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    func showQuickCapture() {
        if quickCapturePanel == nil {
            quickCapturePanel = QuickCapturePanel(onCommit: { [weak self] text in
                self?.appState?.appendToDailyNote(text)
            })
        }
        quickCapturePanel?.present()
    }
}
