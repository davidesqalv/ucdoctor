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

/// `ucdoctor snapshot out.png [dark] [demo]`: render the window offscreen (no screen access needed).
/// `demo` swaps in made-up devices and events and draws a window frame, for the README.
func snapshotWindow(to url: URL, dark: Bool, demo: Bool) {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let model = AppModel()
    model.monitor.writeToFile = false
    if demo {
        model.loadDemo(phoneName: "Alex’s iPhone")
    } else {
        model.start()
        RunLoop.main.run(until: Date().addingTimeInterval(7)) // history + first health check
    }

    let size = NSSize(width: 860, height: demo ? 904 : 860) // demo: end the activity list on a whole row
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    let host = NSHostingView(rootView: ContentView(model: model))
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(1))

    guard let content = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: content)
    model.stop()
    let image = demo ? framed(content, size: size, appearance: appearance, dark: dark) : content
    try? image.representation(using: .png, properties: [:])?.write(to: url)
}

/// Wraps a rendered window body in macOS-style chrome (title bar, traffic lights, shadow) on a transparent canvas.
private func framed(_ content: NSBitmapImageRep, size: NSSize, appearance: NSAppearance, dark: Bool) -> NSBitmapImageRep {
    let scale = CGFloat(content.pixelsWide) / size.width
    let titleBar: CGFloat = 32, pad: CGFloat = 44, radius: CGFloat = 12
    let canvas = NSSize(width: size.width + pad * 2, height: size.height + titleBar + pad * 2)
    let win = NSRect(x: pad, y: pad + 6, width: size.width, height: size.height + titleBar)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = canvas
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    appearance.performAsCurrentDrawingAppearance {
        let shape = NSBezierPath(roundedRect: win, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.55 : 0.28)
        shadow.shadowBlurRadius = 28
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor.windowBackgroundColor.setFill()
        win.fill()
        content.draw(in: NSRect(x: win.minX, y: win.minY, width: size.width, height: size.height))
        NSColor.separatorColor.setFill()
        NSRect(x: win.minX, y: win.maxY - titleBar, width: size.width, height: 1 / scale).fill()

        let lights = [NSColor(srgbRed: 1.00, green: 0.37, blue: 0.34, alpha: 1),
                      NSColor(srgbRed: 1.00, green: 0.74, blue: 0.18, alpha: 1),
                      NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1)]
        for (i, color) in lights.enumerated() {
            let dot = NSRect(x: win.minX + 14 + CGFloat(i) * 20, y: win.maxY - titleBar / 2 - 6, width: 12, height: 12)
            color.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        let title = NSAttributedString(string: "UC Doctor", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ])
        let t = title.size()
        title.draw(at: NSPoint(x: win.midX - t.width / 2, y: win.maxY - titleBar / 2 - t.height / 2))
        NSGraphicsContext.restoreGraphicsState()

        (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.14)).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
