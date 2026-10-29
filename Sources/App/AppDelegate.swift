import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = GuardModel()
    var mainWindow: NSWindow!
    var statusItem: NSStatusItem!
    var toggleItem: NSMenuItem!
    var subscriptions: [AnyCancellable] = []
    var sleepObserver: NSObjectProtocol?
    var lockObserver: NSObjectProtocol?
    var localizedMenuItems: [(NSMenuItem, String)] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let root = MainScreen(model: model)
        let host = NSHostingController(rootView: root)
        mainWindow = NSWindow(contentViewController: host)
        mainWindow.title = "Don’t Touch My Mac!"
        mainWindow.styleMask = [.titled, .closable, .miniaturizable]
        mainWindow.titlebarAppearsTransparent = true
        mainWindow.backgroundColor = NSColor(red: 0.055, green: 0.065, blue: 0.065, alpha: 1)
        mainWindow.isReleasedWhenClosed = false
        mainWindow.center()
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let menu = NSMenu()
        menu.addItem(withTitle: "Don’t Touch My Mac!", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        add(menu, "menu.open", #selector(openMain), "")
        toggleItem = add(menu, "guard.enable", #selector(toggle), "g")
        toggleItem.keyEquivalentModifierMask = [.command, .option]
        add(menu, "guard.preview", #selector(preview), "")
        menu.addItem(.separator())
        add(menu, "menu.quit", #selector(quit), "q")

        HotKeyManager.shared.onTrigger = { [weak self] in
            MainActor.assumeIsolated {
                self?.model.toggle()
            }
        }
        HotKeyManager.shared.register()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "hand.raised.slash", accessibilityDescription: "Don't Touch My Mac")
        statusItem.menu = menu

        model.onChange = { [weak self] in self?.refreshMenus() }

        let appMenu = NSMenu()
        let container = NSMenuItem()
        appMenu.addItem(container)
        let sub = NSMenu()
        add(sub, "menu.about", #selector(openMain), "")
        sub.addItem(.separator())
        add(sub, "menu.quitApp", #selector(quit), "q")
        container.submenu = sub
        NSApp.mainMenu = appMenu
        refreshMenus()

        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.stop() }
        }
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.stop() }
        }

        if let option = CommandLine.arguments.firstIndex(of: "--replay-camera"), CommandLine.arguments.indices.contains(option + 1) {
            let url = URL(fileURLWithPath: CommandLine.arguments[option + 1])
            DispatchQueue.main.async { [weak self] in self?.model.replayRecordedCamera(url) }
        } else if let path = try? String(contentsOf: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("camera-replay-test.enabled"), encoding: .utf8) {
            let url = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
            DispatchQueue.main.async { [weak self] in self?.model.replayRecordedCamera(url) }
        }
    }

    @discardableResult func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: model.t(title), action: action, keyEquivalent: key)
        localizedMenuItems.append((item, title))
        item.target = self; menu.addItem(item); return item
    }

    func refreshMenus() {
        for (item, key) in localizedMenuItems { item.title = model.t(key) }
        toggleItem.title = model.t(model.enabled ? "guard.pause" : "guard.enable")
        statusItem.button?.toolTip = model.t(model.enabled ? "status.on" : "status.off")
    }

    @objc func openMain() { mainWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func toggle() { model.toggle() }
    @objc func preview() { model.preview() }
    @objc func quit() { model.stop(); NSApp.terminate(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openMain(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
}
