import AppKit
import SwiftUI

/// Regular windowed app. Closing the window keeps it running (and logging); the Dock icon reopens it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private let startHidden: Bool
    private var window: NSWindow?
    private var sigterm: DispatchSourceSignal?

    init(startHidden: Bool) {
        self.startHidden = startHidden
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        EventLog.shared.append("──────── UC Doctor \(appVersion) started \(fileStampFmt.string(from: Date())) ────────")
        model.onVerdict = { v in NSApp.dockTile.badgeLabel = v.level == .bad ? "!" : nil }
        model.start()
        if !startHidden { showWindow() }

        // launchd and pkill stop us with SIGTERM, which skips applicationWillTerminate: clean up `log stream` children.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in
            self?.model.stop()
            exit(0)
        }
        term.resume()
        sigterm = term
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    @objc func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 860),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "UC Doctor"
            let host = NSHostingController(rootView: ContentView(model: model))
            host.sizingOptions = [.minSize]
            w.contentViewController = host
            w.setContentSize(NSSize(width: 860, height: 860))
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("UCDoctorMain")
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Menu bar (the app's own menus, not a status item)

    @objc private func kickSoft() { model.kick(hard: false) }
    @objc private func kickHard() { model.kick(hard: true) }
    @objc private func testToMac() { showWindow(); model.startTest(.toMac) }
    @objc private func testToPhone() { showWindow(); model.startTest(.toPhone) }
    @objc private func openLog() { model.openLog() }

    private func buildMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About UC Doctor", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide UC Doctor", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit UC Doctor (stops logging)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, to: main)

        let actions = NSMenu(title: "Actions")
        actions.addItem(item("Kick", #selector(kickSoft), "k"))
        actions.addItem(item("Kick Harder", #selector(kickHard), "K"))
        actions.addItem(.separator())
        actions.addItem(item("Test iPhone → Mac", #selector(testToMac), "1"))
        actions.addItem(item("Test Mac → iPhone", #selector(testToPhone), "2"))
        actions.addItem(.separator())
        actions.addItem(item("Open Log File", #selector(openLog), "l"))
        add(actions, to: main)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(item("UC Doctor", #selector(showWindow), "0"))
        add(windowMenu, to: main)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    private func add(_ menu: NSMenu, to main: NSMenu) {
        let holder = NSMenuItem()
        holder.submenu = menu
        main.addItem(holder)
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }
}

/// `ucdoctor snapshot out.png [dark]`: render the window offscreen (no screen access needed) to check the layout.
func snapshotWindow(to url: URL, dark: Bool, demoFixPlan: Bool = false) {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let model = AppModel()
    model.monitor.writeToFile = false
    model.start()
    RunLoop.main.run(until: Date().addingTimeInterval(7)) // history + first health check
    if demoFixPlan { model.showDemoFixPlan() }

    let host = NSHostingView(rootView: ContentView(model: model))
    host.frame = NSRect(x: 0, y: 0, width: 860, height: 860)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(1))

    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    model.stop()
}
