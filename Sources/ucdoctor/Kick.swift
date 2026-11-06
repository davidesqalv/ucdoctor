import AppKit

// IOBluetooth's private power switch (what `blueutil` uses). Needs Bluetooth permission.
private typealias BTSetPower = @convention(c) (Int32) -> Void
private let btSetPower: BTSetPower? = {
    guard let h = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW),
          let sym = dlsym(h, "IOBluetoothPreferenceSetControllerPowerState") else { return nil }
    return unsafeBitCast(sym, to: BTSetPower.self)
}()

/// Turn Bluetooth off, wait, and turn it back on. Blocking: call off the main thread.
private func cycleBluetooth(_ log: (String) -> Void) {
    guard let setPower = btSetPower else { log("Bluetooth toggle isn't available on this macOS"); return }
    setPower(0)
    let wentOff = waitFor(6) { bluetoothPowered() == false }
    if wentOff { Thread.sleep(forTimeInterval: 2) }
    setPower(1) // always, even if "off" didn't take
    let backOn = waitFor(12) { bluetoothPowered() == true }
    if !wentOff {
        log("Bluetooth didn't switch off. Allow it in System Settings → Privacy & Security → Bluetooth → UC Doctor")
    } else {
        log(backOn ? "Bluetooth restarted" : "Bluetooth is still coming back on; check the menu bar")
    }
}

private func snapshotPasteboard() -> [[(NSPasteboard.PasteboardType, Data)]] {
    (NSPasteboard.general.pasteboardItems ?? []).map { item in
        item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
    }
}

private func restorePasteboard(_ items: [[(NSPasteboard.PasteboardType, Data)]]) {
    let pbItems = items.map { pairs -> NSPasteboardItem in
        let item = NSPasteboardItem()
        for (type, data) in pairs { item.setData(data, forType: type) }
        return item
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects(pbItems)
}

/// launchd labels for the per-user Continuity agents.
private let softKick = [("useractivityd", "com.apple.coreservices.useractivityd"), ("sharingd", "com.apple.sharingd")]
private let hardKickExtra = [("rapportd", "com.apple.rapportd"), ("pboard", "com.apple.pboard")]

/// Kick: restart useractivityd (runs Universal Clipboard) and sharingd (Bluetooth discovery).
/// Hard: also re-assert Handoff, power-cycle Bluetooth, restart rapportd + pboard (clipboard preserved).
/// Blocking. `log` gets one line per step.
func performKick(hard: Bool, log: (String) -> Void) {
    if hard {
        // Same switch System Settings flips; sets it on for this Mac's hardware ID.
        for key in ["ActivityAdvertisingAllowed", "ActivityReceivingAllowed"] {
            CFPreferencesSetValue(key as CFString, kCFBooleanTrue, "com.apple.coreservices.useractivityd" as CFString,
                                  kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
        CFPreferencesSynchronize("com.apple.coreservices.useractivityd" as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        log("Handoff switched on for this Mac")
        cycleBluetooth(log)
    }

    let services = softKick + (hard ? hardKickExtra : [])
    let saved = hard ? onMain { snapshotPasteboard() } : []
    for (name, label) in services {
        let ok = sh("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"]).status == 0
        if !ok { sh("/usr/bin/killall", [name]) } // launchd respawns it
    }
    if hard, !saved.isEmpty {
        Thread.sleep(forTimeInterval: 0.7)
        onMain { restorePasteboard(saved) }
        log("Clipboard contents restored")
    }

    let names = services.map(\.0)
    let back = waitFor(10) {
        let up = daemonUptimes()
        return names.allSatisfy { (up[$0] ?? .infinity) < 60 }
    }
    let up = daemonUptimes()
    let missing = names.filter { up[$0] == nil }
    if back {
        log("Restarted \(names.joined(separator: ", "))")
    } else if missing.isEmpty {
        log("Restart sent to \(names.joined(separator: ", ")); some may start on demand")
    } else {
        log("Not back yet: \(missing.joined(separator: ", ")). They usually start on first use")
    }
}
