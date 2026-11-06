import Foundation

// Universal Clipboard lives in useractivityd (subsystem com.apple.useractivity).
// These rules turn its log lines into plain-English events. Needles come from the
// daemon's own format strings, which don't change with redaction.

enum Lane: String {
    case toPhone = "Mac → iPhone"
    case toMac = "iPhone → Mac"
    case service = "Service"
    case nearby = "Nearby"
    case doctor = "UC Doctor"
}

enum Level: String {
    case ok = "✓", info = "·", warn = "!", bad = "✗"
}

enum Signal {
    case macCopied, phonePeeked, phonePasted, macSent, macOfferExpired
    case phoneOffered, phoneOfferGone, macPasting, macReceived
    case transferError, serviceBroken, serviceInterrupted, sharingDisabled, screenShareOn, screenShareOff
    case deviceFound, deviceLost, beacon, peersChanged
    case phoneBeacon, phoneClipboard, phoneNearby, phoneAway
    case kicked, note
}

struct Event: Identifiable {
    let id = UUID()
    let date: Date
    let signal: Signal
    let lane: Lane
    let level: Level
    let text: String
    let raw: String

    /// Worth showing in the default ("Important") activity view.
    var isNotable: Bool { level != .info || lane == .doctor }

    var line: String {
        let lane = self.lane.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
        var s = "\(fileStampFmt.string(from: date))  \(level.rawValue)  \(lane)  \(text)"
        if !raw.isEmpty { s += "\n                         ↳ \(raw.prefix(300))" }
        return s
    }
}

private struct Rule {
    let needle: String, signal: Signal, lane: Lane, level: Level, text: String
    init(_ needle: String, _ signal: Signal, _ lane: Lane, _ level: Level, _ text: String) {
        (self.needle, self.signal, self.lane, self.level, self.text) = (needle, signal, lane, level, text)
    }
}

private let rules: [Rule] = [
    // Things that switch it off or wedge it
    Rule("remote copy/paste will no longer work", .serviceBroken, .service, .bad,
         "Clipboard service lost its link to pboard. Nothing crosses devices until it restarts"),
    Rule("Client Notification Connection interrupted", .serviceInterrupted, .service, .warn,
         "Clipboard service's link to pboard was interrupted"),
    Rule("Screen sharing session started", .screenShareOn, .service, .bad,
         "Screen sharing started, so macOS switched Universal Clipboard off"),
    Rule("Ignoring type updates, screen sharing session in progress", .screenShareOn, .service, .bad,
         "Copy not shared: a screen-sharing session is active"),
    Rule("No more screen sharing sessions", .screenShareOff, .service, .ok,
         "Screen sharing ended; Universal Clipboard is back on"),
    Rule("Ignoring type updates, clipboard sharing disabled", .sharingDisabled, .service, .bad,
         "Copy not shared: clipboard sharing is disabled on this Mac"),

    // Mac → iPhone
    Rule("Got type update from client", .macCopied, .toPhone, .info, "You copied on the Mac; offering it to your devices"),
    Rule("Types Requested from remote", .phonePeeked, .toPhone, .info, "A device looked at what the Mac is offering"),
    Rule("Paste V2 Requested from remote", .phonePasted, .toPhone, .info, "A device is pasting the Mac clipboard…"),
    Rule("Paste Requested from remote", .phonePasted, .toPhone, .info, "A device is pasting the Mac clipboard…"),
    Rule("Pasteboard Sent Info", .macSent, .toPhone, .ok, "Mac clipboard delivered"),
    Rule("Remove Local Types Fired", .macOfferExpired, .toPhone, .info, "Mac stopped offering its clipboard (offers last ~2 min)"),
    Rule("Error sending types", .transferError, .toPhone, .bad, "Couldn't send the Mac clipboard's types"),
    Rule("Timeout getting local pasteboard", .transferError, .toPhone, .bad, "Timed out reading the Mac clipboard"),
    Rule("Failed to create local pasteboard data file", .transferError, .toPhone, .bad, "Couldn't stage the Mac clipboard for sending"),
    Rule("Error writing pasteboard data blob", .transferError, .toPhone, .bad, "Couldn't stage the Mac clipboard for sending"),

    // iPhone → Mac
    Rule("UARemotePasteboardBecameAvailableEvent", .phoneOffered, .toMac, .ok, "Another device's clipboard is ready to paste here"),
    Rule("Received pboard available advertisement", .phoneOffered, .toMac, .ok, "A device announced a new clipboard"),
    Rule("Ad is from new device, notify client", .phoneOffered, .toMac, .ok, "A device announced a new clipboard"),
    Rule("Pboard version bit flipped", .phoneOffered, .toMac, .ok, "A device announced a new clipboard"),
    Rule("Notify client of new remote pboard", .phoneOffered, .toMac, .ok, "A device announced a new clipboard"),
    Rule("UARemotePasteboardBecameUnavailableEvent", .phoneOfferGone, .toMac, .info, "The other device's clipboard offer ended"),
    Rule("Recived add w/o remote pboard", .phoneOfferGone, .toMac, .info, "The other device withdrew its clipboard"),
    Rule("Pasteboard data fetch requested", .macPasting, .toMac, .info, "Pasting from another device…"),
    Rule("Requesting data from remote device", .macPasting, .toMac, .info, "Pasting from another device…"),
    Rule("Calling pasteboard received handler", .macReceived, .toMac, .ok, "Clipboard data received"),
    Rule("Opened streams with error", .transferError, .toMac, .bad, "Couldn't open a connection to the other device"),
    Rule("Payload fetch error", .transferError, .toMac, .bad, "Fetching the other device's clipboard failed"),
    Rule("Received error from remote", .transferError, .toMac, .bad, "The other device reported an error"),
    Rule("Error receiving pboard info", .transferError, .toMac, .bad, "Didn't get the other device's clipboard info"),
    Rule("Error receiving pasteboard info", .transferError, .toMac, .bad, "Didn't get the other device's clipboard info"),
    Rule("Pasteboard Fetch Cancelled", .transferError, .toMac, .warn, "Paste was cancelled before the data arrived"),
    Rule("with fail:", .transferError, .toMac, .bad, "Transfer failed"),
    Rule("Could not create data file for remote pasteboard", .transferError, .toMac, .bad, "Couldn't save the incoming clipboard"),
    Rule("Error creating remote data file", .transferError, .toMac, .bad, "Couldn't save the incoming clipboard"),
    Rule("ERROR creating shared pasteboard dir", .transferError, .service, .bad, "Couldn't create the shared clipboard folder"),

    // Nearby devices (Bluetooth)
    Rule("foundDevice, deviceIdentifier=%{private}@ scanner", .deviceFound, .nearby, .info, "A device on your Apple ID came into Bluetooth range"),
    Rule("lostDevice, deviceIdentifier=%{private}@ scanner", .deviceLost, .nearby, .warn, "A device on your Apple ID dropped out of Bluetooth range"),
    Rule("RECEIVED advertisement", .beacon, .nearby, .info, "Heard a Handoff beacon from one of your devices"),
    Rule("PEERS: Our peers ability", .peersChanged, .nearby, .info, "Nearby devices' Handoff/clipboard ability changed"),
]

/// Only pulls the lines the rules care about, so the stream stays light.
let streamPredicate = """
subsystem == "com.apple.useractivity" AND (category BEGINSWITH "pasteboard" OR category == "Diagnostic" \
OR composedMessage CONTAINS "PBOARD" OR composedMessage CONTAINS "CODER" \
OR composedMessage CONTAINS "RECEIVED advertisement" OR composedMessage CONTAINS "Device, deviceIdentifier" \
OR composedMessage BEGINSWITH "PEERS") \
OR (subsystem == "com.apple.sharing" AND category == "TetheringAgent" AND composedMessage CONTAINS "SFRemoteHotspotDevice") \
OR (subsystem == "com.apple.sharing" AND category == "Handoff" \
    AND (composedMessage BEGINSWITH "Received a new advertisement" OR composedMessage BEGINSWITH "Handoff active for device"))
"""

func classify(format: String, message: String, date: Date) -> Event? {
    guard let rule = rules.first(where: { format.contains($0.needle) }) else { return nil }
    // "Hide progress … with fail: NO" (or "(null)") is the success path.
    if rule.needle == "with fail:", message.hasSuffix(" NO") || message.hasSuffix("(null)") { return nil }
    var text = rule.text
    if rule.signal == .transferError, let detail = publicDetail(message) { text += " (\(detail))" }
    if rule.signal == .beacon, message.contains("CopyPasteKey = 1") { text = "Heard a Handoff beacon carrying a clipboard flag" }
    return Event(date: date, signal: rule.signal, lane: rule.lane, level: rule.level, text: text, raw: message)
}

/// The non-redacted tail of an error line, e.g. "Error Domain=... Code=-1".
private func publicDetail(_ message: String) -> String? {
    guard let r = message.range(of: ": ", options: .backwards) else { return nil }
    let d = message[r.upperBound...].trimmingCharacters(in: .whitespaces)
    if d.isEmpty || d.contains("<private>") || d == "(null)" { return nil }
    return String(d.prefix(160))
}

/// Watches the unified log live (`log stream`) and keeps a picture of what Universal Clipboard is doing.
final class Monitor {
    private(set) var recent: [Event] = []
    private(set) var last: [Signal: Date] = [:]
    private(set) var lastError: Event?
    private(set) var screenSharing = false
    private(set) var brokenAt: Date?
    private(set) var sharingDisabledAt: Date?
    private(set) var historySince = Date()

    var onEvent: ((Event) -> Void)?
    var onReady: (() -> Void)?
    var echo = false       // `ucdoctor watch` prints every event
    var writeToFile = true

    private var proc: Process?
    private var partial = Data()
    private var stopping = false

    /// Load recent history, then follow the live stream. Callbacks arrive on the main thread.
    func start(historyMinutes: Int = 60) {
        DispatchQueue.global(qos: .utility).async {
            let items = historyMinutes > 0 ? Monitor.history(minutes: historyMinutes) : []
            DispatchQueue.main.async {
                self.historySince = Date().addingTimeInterval(-Double(historyMinutes) * 60)
                items.forEach { self.take($0, live: false) }
                self.launchStream()
                self.onReady?()
            }
        }
    }

    func stop() {
        stopping = true
        proc?.terminate()
    }

    func loadHistory(minutes: Int) {
        historySince = Date().addingTimeInterval(-Double(minutes) * 60)
        Monitor.history(minutes: minutes).forEach { take($0, live: false) }
    }

    private func take(_ item: Parsed, live: Bool) {
        switch item {
        case .event(let e): ingest(e, live: live)
        case .sharing(let obs, let date): ingestSharing(obs, date: date, live: live)
        }
    }

    static func history(minutes: Int) -> [Parsed] {
        let out = sh("/usr/bin/log", ["show", "--last", "\(minutes)m", "--style", "ndjson", "--info", "--debug",
                                      "--predicate", streamPredicate]).out
        return out.split(separator: "\n").compactMap { parse(Data($0.utf8)) }
    }

    enum Parsed {
        case event(Event)
        case sharing(SharingObs, Date)
    }

    static func parse(_ line: Data) -> Parsed? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = obj["eventMessage"] as? String else { return nil }
        let date = (obj["timestamp"] as? String).flatMap { logStampFmt.date(from: $0) } ?? Date()
        if (obj["subsystem"] as? String) == "com.apple.sharing" {
            return parseSharing(message).map { .sharing($0, date) }
        }
        let format = (obj["formatString"] as? String) ?? message
        return classify(format: format, message: message, date: date).map { .event($0) }
    }

    private func launchStream() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "ndjson", "--level", "debug", "--predicate", streamPredicate]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.consume(data)
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard let self, !self.stopping else { return }
                self.note(.note, .warn, "Log stream stopped; restarting it")
                self.launchStream()
            }
        }
        do { try p.run(); proc = p } catch { note(.note, .bad, "Couldn't start `log stream`: \(error.localizedDescription)") }
    }

    private func consume(_ data: Data) { // readabilityHandler calls are serial
        partial.append(data)
        while let nl = partial.firstIndex(of: 0x0A) {
            let line = partial.subdata(in: partial.startIndex..<nl)
            partial.removeSubrange(partial.startIndex...nl)
            if let item = Monitor.parse(line) { DispatchQueue.main.async { self.take(item, live: true) } }
        }
    }

    /// Record something UC Doctor itself did (kicks, tests, status changes).
    func note(_ signal: Signal, _ level: Level, _ text: String) {
        ingest(Event(date: Date(), signal: signal, lane: .doctor, level: level, text: text, raw: ""), live: true)
    }

    func ingest(_ e: Event, live: Bool) {
        let repeatable: Set<Signal> = [.transferError, .kicked, .note]
        // Most daemon messages come in bursts of 2-3 for one action.
        if !repeatable.contains(e.signal), let prev = last[e.signal], abs(e.date.timeIntervalSince(prev)) < 2 { return }
        if (last[e.signal] ?? .distantPast) < e.date { last[e.signal] = e.date }

        switch e.signal {
        case .screenShareOn: screenSharing = true
        case .screenShareOff: screenSharing = false
        case .serviceBroken: brokenAt = e.date
        case .macSent, .macReceived, .phoneOffered: brokenAt = nil // evidence it works again
        case .kicked: brokenAt = nil; lastError = nil; sharingDisabledAt = nil
        case .transferError: lastError = e
        case .sharingDisabled: sharingDisabledAt = e.date
        default: break
        }

        let noisy = e.signal == .beacon && !e.text.contains("clipboard flag")
        if !noisy {
            recent.append(e)
            if recent.count > 100 { recent.removeFirst(recent.count - 100) }
        }
        guard live else { return }
        if !noisy && writeToFile { EventLog.shared.append(e.line) }
        if echo { print(e.line); fflush(stdout) }
        onEvent?(e)
    }
    // MARK: Your iPhone (from sharingd)

    private(set) var phone: PhoneInfo?
    /// Latest Handoff broadcast from the iPhone and whether it carried the clipboard flag.
    private(set) var lastPhoneBeacon: (date: Date, clipboard: Bool)?
    var onPhoneChange: (() -> Void)?

    private var phoneHash: String?                       // sharingd's per-launch anonymised ID for the iPhone
    private var handoffActive: [(hash: String, date: Date)] = []
    private var phoneTetherActive: [Date] = []
    private var lastAd: [String: (date: Date, clipboard: Bool)] = [:]

    func phonePresence(now: Date = Date()) -> PhonePresence {
        guard let p = phone else { return .unknown }
        if let removed = p.removedAt, removed > p.lastSeen, now.timeIntervalSince(removed) > 120 { return .away }
        return now.timeIntervalSince(p.lastSeen) <= 15 * 60 ? .nearby : .away
    }

    private func ingestSharing(_ obs: SharingObs, date: Date, live: Bool) {
        switch obs {
        case .hotspot(let devices, let kind):
            // group 1 = your own Apple ID (family devices are group 2)
            for d in devices where d.group == 1 && d.model.hasPrefix("iPhone") {
                guard phone == nil || phone?.id == d.id else { continue }
                var p = phone ?? PhoneInfo(id: d.id, name: d.name, model: d.model, lastSeen: .distantPast)
                p.name = d.name
                p.model = d.model
                if kind == .removed {
                    if (p.removedAt ?? .distantPast) < date { p.removedAt = date }
                } else if p.lastSeen < date {
                    p.lastSeen = date
                }
                phone = p
                if kind == .handoffActive {
                    phoneTetherActive.append(date)
                    if phoneTetherActive.count > 20 { phoneTetherActive.removeFirst() }
                    if let match = handoffActive.last(where: { abs($0.date.timeIntervalSince(date)) < 0.25 }) {
                        learnPhoneHash(match.hash, live: live)
                    }
                }
            }
        case .handoffActive(let hash, let active):
            guard active else { break }
            handoffActive.append((hash, date))
            if handoffActive.count > 40 { handoffActive.removeFirst() }
            if phoneTetherActive.contains(where: { abs($0.timeIntervalSince(date)) < 0.25 }) { learnPhoneHash(hash, live: live) }
        case .ad(let hash, let goodbye, let clipboard):
            guard !goodbye else { break }
            lastAd[hash] = (date, clipboard)
            if hash == phoneHash { phoneBeacon(date: date, clipboard: clipboard, live: live) }
        }
        if live { onPhoneChange?() }
    }

    private func learnPhoneHash(_ hash: String, live: Bool) {
        guard phoneHash != hash else { return }
        phoneHash = hash
        if let ad = lastAd[hash] { phoneBeacon(date: ad.date, clipboard: ad.clipboard, live: live) }
    }

    private func phoneBeacon(date: Date, clipboard: Bool, live: Bool) {
        if (lastPhoneBeacon?.date ?? .distantPast) < date { lastPhoneBeacon = (date, clipboard) }
        if var p = phone, p.lastSeen < date { p.lastSeen = date; phone = p }
        let name = phone?.name ?? "Your iPhone"
        ingest(Event(date: date, signal: clipboard ? .phoneClipboard : .phoneBeacon, lane: .toMac,
                     level: clipboard ? .ok : .info,
                     text: clipboard ? "\(name) is offering its clipboard" : "Heard \(name); no clipboard in its broadcast",
                     raw: ""), live: live)
    }

    /// For status changes computed elsewhere (e.g. the iPhone coming and going).
    func post(_ signal: Signal, _ lane: Lane, _ level: Level, _ text: String) {
        ingest(Event(date: Date(), signal: signal, lane: lane, level: level, text: text, raw: ""), live: true)
    }
}

enum PhonePresence { case unknown, nearby, away }

struct PhoneInfo {
    let id: String
    var name: String
    var model: String
    var lastSeen: Date
    var removedAt: Date?
}

enum HotspotKind { case seen, removed, handoffActive }

/// What sharingd says about nearby devices on your Apple ID.
enum SharingObs {
    case hotspot([(id: String, name: String, model: String, group: Int)], HotspotKind)
    case handoffActive(hash: String, active: Bool)
    case ad(hash: String, goodbye: Bool, clipboard: Bool)
}

private let hotspotRe = try! NSRegularExpression(
    pattern: #"name: (.+?), identifier: ([0-9A-Fa-f-]{36}),.*?group: (\d+), model ([A-Za-z]+[0-9]+,[0-9]+)"#)
private let handoffActiveRe = try! NSRegularExpression(pattern: #"^Handoff active for device ([A-Za-z0-9]+) : (yes|no)"#)
private let adRe = try! NSRegularExpression(
    pattern: #"deviceUniqueID:([A-Za-z0-9]+), advertisementPayload:([A-Za-z0-9]+), options:\{[^}]*CopyPasteKey = (\d)"#)

private func groups(_ re: NSRegularExpression, _ s: String) -> [[String]] {
    re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
        (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
    }
}

func parseSharing(_ message: String) -> SharingObs? {
    if message.contains("SFRemoteHotspotDevice") {
        if message.contains("family disabled") { return nil }
        let kind: HotspotKind = message.hasPrefix("Removing hotspot device") ? .removed
            : message.hasPrefix("Handoff active for") ? .handoffActive : .seen
        let devices = groups(hotspotRe, message).compactMap { g -> (id: String, name: String, model: String, group: Int)? in
            guard g.count == 4, let group = Int(g[2]) else { return nil }
            return (g[1], g[0], g[3].trimmingCharacters(in: .whitespaces), group)
        }
        return devices.isEmpty ? nil : .hotspot(devices, kind)
    }
    if let g = groups(handoffActiveRe, message).first, g.count == 2 {
        return .handoffActive(hash: g[0], active: g[1] == "yes")
    }
    if message.hasPrefix("Received a new advertisement"), let g = groups(adRe, message).first, g.count == 3 {
        return .ad(hash: g[0], goodbye: g[1] == "GOODBYE", clipboard: g[2] == "1")
    }
    return nil
}
