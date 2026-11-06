// UC Doctor: finds out why Universal Clipboard (iPhone ↔ Mac copy/paste) isn't working, and kicks it.
//
//   ucdoctor                 the app window (default)
//   ucdoctor --background    start without a window (used at login)
//   ucdoctor status          checks + diagnosis + last 2 hours of clipboard events
//   ucdoctor watch           print clipboard events live
//   ucdoctor kick [--hard]   restart the services (hard: also Bluetooth)

import AppKit

let appVersion = "1.4"
let args = Array(CommandLine.arguments.dropFirst())

func printStatus() {
    let monitor = Monitor()
    monitor.writeToFile = false
    monitor.loadHistory(minutes: 120)
    let health = checkHealth()
    let verdict = diagnose(health, monitor)
    print("\(verdict.level.rawValue) \(verdict.headline)")
    print("  \(verdict.detail)")
    print("\nChecks")
    for c in checkLines(health, monitor) { print("  \(c.ok == nil ? "·" : c.ok! ? "✓" : "✗") \(c.text)") }
    let since = monitor.historySince
    print("\nYour iPhone")
    if let p = monitor.phone {
        let presence = monitor.phonePresence()
        print("  \(p.name) (\(p.model)): \(presence == .nearby ? "nearby" : "NOT nearby"), last heard \(ago(p.lastSeen))")
        if let b = monitor.lastPhoneBeacon {
            print("  Last Handoff broadcast \(ago(b.date)): \(b.clipboard ? "offering its clipboard" : "no clipboard in it")")
        } else {
            print("  No Handoff broadcast from it matched yet")
        }
    } else {
        print("  not seen since \(clockFmt.string(from: since))")
    }
    print("\nTraffic")
    print("  iPhone → Mac: offered \(ago(monitor.last[.phoneOffered], orNoneSince: since)), received \(ago(monitor.last[.macReceived], orNoneSince: since))")
    print("  Mac → iPhone: delivered \(ago(monitor.last[.macSent], orNoneSince: since))")
    print("\nRecent events (last 2 hours)")
    let recent = monitor.recent.suffix(25)
    if recent.isEmpty { print("  none") }
    for e in recent {
        print("  \(clockSecFmt.string(from: e.date))  \(e.level.rawValue)  \(e.lane.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0))  \(e.text)")
    }
}

switch args.first {
case nil, "--background", "app":
    // Only one copy should watch and log.
    if let id = Bundle.main.bundleIdentifier,
       let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != getpid() }) {
        other.activate()
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate(startHidden: args.first == "--background")
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
case "status":
    printStatus()
case "watch":
    let monitor = Monitor()
    monitor.echo = true
    monitor.writeToFile = false
    print("Watching Universal Clipboard events (Ctrl-C to stop)…")
    monitor.start(historyMinutes: 0)
    dispatchMain()
case "kick":
    performKick(hard: args.contains("--hard")) { print("• \($0)") }
case "snapshot":
    snapshotWindow(to: URL(fileURLWithPath: args.count > 1 ? args[1] : "snapshot.png"), dark: args.contains("dark"),
                   demoFixPlan: args.contains("fixplan"))
case "make-icon":
    try makeIconSet(at: URL(fileURLWithPath: args.count > 1 ? args[1] : "AppIcon.iconset"))
case "version", "--version":
    print(appVersion)
default:
    print("usage: ucdoctor [--background | status | watch | kick [--hard] | version]")
    exit(2)
}
