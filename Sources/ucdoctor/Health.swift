import Foundation

/// Daemons in the Universal Clipboard path. bluetoothd runs as root; the rest run as you.
let watchedDaemons = ["useractivityd", "sharingd", "pboard", "rapportd", "bluetoothd"]

struct Health {
    var bluetoothOn: Bool?
    var wifiOn: Bool?
    var awdlUp: Bool?
    var handoffSend = true
    var handoffReceive = true
    var uptime: [String: TimeInterval] = [:] // missing = not running
    var checked = false
}

struct Verdict {
    let level: Level
    let headline: String
    let detail: String
}

private let wifiDevice: String = {
    let lines = sh("/usr/sbin/networksetup", ["-listallhardwareports"]).out.components(separatedBy: "\n")
    for (i, line) in lines.enumerated() where line.contains("Wi-Fi") && i + 1 < lines.count {
        if let r = lines[i + 1].range(of: "Device: ") { return lines[i + 1][r.upperBound...].trimmingCharacters(in: .whitespaces) }
    }
    return "en0"
}()

/// Reads the same per-Mac switch as System Settings → AirDrop & Handoff. Missing means on.
func handoffPref(_ key: String) -> Bool {
    let v = CFPreferencesCopyValue(key as CFString, "com.apple.coreservices.useractivityd" as CFString,
                                   kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    return (v as? Bool) ?? true
}

/// system_profiler needs no Bluetooth permission, unlike IOBluetooth.
func bluetoothPowered() -> Bool? {
    let out = sh("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]).out
    guard let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
          let first = (obj["SPBluetoothDataType"] as? [[String: Any]])?.first,
          let ctl = first["controller_properties"] as? [String: Any],
          let state = ctl["controller_state"] as? String else { return nil }
    return state == "attrib_on"
}

/// ps etime is [[dd-]hh:]mm:ss
private func parseEtime(_ s: Substring) -> TimeInterval? {
    var rest = s, days = 0.0
    if let dash = rest.firstIndex(of: "-") {
        days = Double(rest[..<dash]) ?? 0
        rest = rest[rest.index(after: dash)...]
    }
    let parts = rest.split(separator: ":").compactMap { Double($0) }
    guard !parts.isEmpty else { return nil }
    return days * 86400 + parts.reduce(0) { $0 * 60 + $1 }
}

func daemonUptimes() -> [String: TimeInterval] {
    let me = getuid()
    var result: [String: TimeInterval] = [:]
    for line in sh("/bin/ps", ["-axo", "uid=,etime=,comm="]).out.split(separator: "\n") {
        let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard f.count == 3, let uid = UInt32(f[0]) else { continue }
        let name = (String(f[2]) as NSString).lastPathComponent
        guard watchedDaemons.contains(name), result[name] == nil,
              uid == me || name == "bluetoothd", let up = parseEtime(f[1]) else { continue }
        result[name] = up
    }
    return result
}

func checkHealth() -> Health {
    var h = Health()
    h.bluetoothOn = bluetoothPowered()
    let wifi = sh("/usr/sbin/networksetup", ["-getairportpower", wifiDevice]).out.trimmingCharacters(in: .whitespacesAndNewlines)
    h.wifiOn = wifi.hasSuffix(": On") ? true : wifi.hasSuffix(": Off") ? false : nil
    let awdl = sh("/sbin/ifconfig", ["awdl0"])
    h.awdlUp = awdl.status == 0 ? awdl.out.contains("<UP") : nil
    h.handoffSend = handoffPref("ActivityAdvertisingAllowed")
    h.handoffReceive = handoffPref("ActivityReceivingAllowed")
    h.uptime = daemonUptimes()
    h.checked = true
    return h
}

/// The single most likely reason it isn't working right now, in priority order.
func diagnose(_ h: Health, _ m: Monitor) -> Verdict {
    let now = Date()
    func bad(_ headline: String, _ detail: String) -> Verdict { Verdict(level: .bad, headline: headline, detail: detail) }

    if h.bluetoothOn == false {
        return bad("Bluetooth is off on this Mac", "Universal Clipboard finds your devices over Bluetooth. Turn it on.")
    }
    if h.wifiOn == false {
        return bad("Wi-Fi is off on this Mac", "The clipboard itself travels over Wi-Fi. Turn it on (no network needed).")
    }
    if !h.handoffSend || !h.handoffReceive {
        return bad("Handoff is off on this Mac", "System Settings → General → AirDrop & Handoff → Allow Handoff.")
    }
    if h.awdlUp == false {
        return bad("Peer-to-peer Wi-Fi (awdl0) is down", "Something disabled AWDL. AirDrop and Universal Clipboard both need it.")
    }
    if m.screenSharing {
        return bad("Screen sharing is active", "macOS turns Universal Clipboard off during screen sharing. It comes back when that ends.")
    }
    if h.checked {
        let down = ["useractivityd", "sharingd", "pboard"].filter { h.uptime[$0] == nil }
        if !down.isEmpty { return bad("\(down.joined(separator: ", ")) not running", "Press Kick to start it.") }
    }
    if let broke = m.brokenAt {
        // Only counts if useractivityd hasn't restarted since.
        let started = h.uptime["useractivityd"].map { now.addingTimeInterval(-$0) } ?? .distantPast
        if started < broke {
            return bad("Clipboard service is wedged",
                       "Since \(clockFmt.string(from: broke)) useractivityd has lost its link to pboard. Press Kick.")
        }
    }
    if let off = m.sharingDisabledAt, now.timeIntervalSince(off) < 1800, (m.last[.macSent] ?? .distantPast) < off {
        return bad("macOS says clipboard sharing is disabled", "Seen \(ago(off)). Check Handoff on both devices, then Kick.")
    }
    if m.phonePresence() == .away, let p = m.phone {
        return Verdict(level: .warn, headline: "Your iPhone isn't nearby",
                       detail: "\(p.name) was last heard \(ago(p.lastSeen)). It needs to be within Bluetooth range (about 10 m) and awake.")
    }
    if let e = m.lastError, now.timeIntervalSince(e.date) < 900 {
        return Verdict(level: .warn, headline: "A transfer failed recently", detail: "\(ago(e.date)): \(e.text)")
    }
    return Verdict(level: .ok, headline: "No faults detected on this Mac",
                   detail: "If a copy still doesn't cross over, run a Test to see which side drops it.")
}

func checkLines(_ h: Health, _ m: Monitor) -> [(ok: Bool?, text: String)] {
    let ua = h.uptime["useractivityd"]
    let servicesUp = h.checked ? ["useractivityd", "sharingd", "pboard"].allSatisfy { h.uptime[$0] != nil } : nil
    return [
        (h.bluetoothOn, h.bluetoothOn == false ? "Bluetooth OFF" : "Bluetooth on"),
        (h.wifiOn, h.wifiOn == false ? "Wi-Fi OFF" : "Wi-Fi on"),
        (h.awdlUp, h.awdlUp == false ? "Peer-to-peer Wi-Fi (awdl0) DOWN" : "Peer-to-peer Wi-Fi (awdl0) up"),
        (h.handoffSend && h.handoffReceive, h.handoffSend && h.handoffReceive ? "Handoff on" : "Handoff OFF"),
        (servicesUp, servicesUp == false ? "Clipboard services not all running"
            : "Clipboard services running" + (ua.map { " (useractivityd up \(duration($0)))" } ?? "")),
        (nil, "Heard your devices' Handoff beacons: \(ago(m.last[.beacon], orNoneSince: m.historySince))"),
    ]
}

struct Chip: Identifiable {
    let id: String
    let ok: Bool?
    let help: String
}

func checkChips(_ h: Health) -> [Chip] {
    let services = h.checked ? ["useractivityd", "sharingd", "pboard"].allSatisfy { h.uptime[$0] != nil } : nil
    return [
        Chip(id: "Bluetooth", ok: h.bluetoothOn, help: "Universal Clipboard finds your devices over Bluetooth."),
        Chip(id: "Wi-Fi", ok: h.wifiOn, help: "The clipboard itself travels over Wi-Fi (no network needed)."),
        Chip(id: "AWDL", ok: h.awdlUp, help: "Peer-to-peer Wi-Fi (awdl0). AirDrop uses it too."),
        Chip(id: "Handoff", ok: h.handoffSend && h.handoffReceive, help: "System Settings → General → AirDrop & Handoff."),
        Chip(id: "Services", ok: services,
             help: h.uptime["useractivityd"].map { "useractivityd up \(duration($0)); sharingd and pboard checked too." }
                ?? "useractivityd, sharingd, pboard"),
    ]
}
