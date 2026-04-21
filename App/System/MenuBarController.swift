import AppKit

final class MenuBarController: NSObject {

    private let statusItem: NSStatusItem
    private let onQuickCapture: () -> Void
    private let onShowMain: () -> Void

    init(onQuickCapture: @escaping () -> Void, onShowMain: @escaping () -> Void) {
        self.onQuickCapture = onQuickCapture
        self.onShowMain = onShowMain
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "circle.hexagongrid", accessibilityDescription: "Slip")
            button.image?.isTemplate = true
            button.toolTip = "Slip"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem.withAction(title: "Quick Capture  ⌥⌘Space", target: self, action: #selector(quickCapture)))
        menu.addItem(NSMenuItem.withAction(title: "Open Slip", target: self, action: #selector(showMain)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Slip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func quickCapture() { onQuickCapture() }
    @objc private func showMain() { onShowMain() }
}

private extension NSMenuItem {
    static func withAction(title: String, target: AnyObject, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        return item
    }
}
