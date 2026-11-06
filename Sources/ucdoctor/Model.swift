import AppKit

enum TestKind { case toMac, toPhone }
enum Outcome { case passed, failed, unclear }

struct RunningTest {
    let kind: TestKind
    let started: Date
    let deadline: Date
}

struct TestResult {
    let kind: TestKind
    let outcome: Outcome
    let title: String
    let advice: String
    let capture: URL?
}

/// Fixes on the iPhone, cheapest first. The one that last worked moves to the top.
enum PhoneFix: String, CaseIterable, Identifiable {
    case handoff, bluetooth, restart

    var id: String { rawValue }

    var title: String {
        switch self {
        case .handoff: return "Turn Handoff off and on"
        case .bluetooth: return "Turn Bluetooth off and on"
        case .restart: return "Restart the iPhone"
        }
    }

    var how: String {
        switch self {
        case .handoff: return "Settings → General → AirPlay & Continuity → Handoff"
        case .bluetooth: return "Settings → Bluetooth (Control Center only disconnects, it doesn't reset)"
        case .restart: return "Hold the side button and a volume button, slide to power off, turn it back on"
        }
    }

    var time: String { self == .restart ? "about 1 min" : "10 s" }

    var pastTense: String {
        switch self {
        case .handoff: return "turning Handoff off and on"
        case .bluetooth: return "turning Bluetooth off and on"
        case .restart: return "restarting the iPhone"
        }
    }
}

/// Shown when this Mac checks out and a test proves the iPhone is the side that's stuck.
struct PhoneFixPlan {
    let kind: TestKind        // the test to re-run after each fix
    let steps: [PhoneFix]
    var tried: [PhoneFix] = []
    var pending: PhoneFix?    // the fix the user just did; it gets the credit if the next test passes

    var next: PhoneFix? { steps.first { !tried.contains($0) } }
    var exhausted: Bool { next == nil && pending == nil }
}

enum KickState {
    case idle
    case running(hard: Bool)
    case finished(at: Date, hard: Bool, summary: String)
}

/// Everything the window shows. Lives as long as the app, so logging continues with the window closed.
final class AppModel: ObservableObject {
    let monitor = Monitor()
    @Published private(set) var health = Health()
    @Published private(set) var verdict = Verdict(level: .info, headline: "Checking…",
                                                  detail: "Reading recent clipboard activity and checking this Mac.")
    @Published private(set) var events: [Event] = []
    @Published private(set) var kickState = KickState.idle
    @Published private(set) var runningTest: RunningTest?
    @Published var result: TestResult?
    @Published private(set) var tick = 0 // refreshes "3 min ago" labels
    @Published private(set) var fixPlan: PhoneFixPlan?
    @Published var autoKick: Bool {
        didSet { UserDefaults.standard.set(autoKick, forKey: "autoKick") }
    }

    var onVerdict: ((Verdict) -> Void)?

    private var ready = false
    private var lastHeadline: String?
    private var lastPresence: PhonePresence?
    private var lastAutoKick = Date.distantPast
    private var capture: (process: Process, file: URL)?

    init() {
        autoKick = UserDefaults.standard.object(forKey: "autoKick") as? Bool ?? true
    }

    var since: Date { monitor.historySince }
    func last(_ signal: Signal) -> Date? { monitor.last[signal] }

    var isKicking: Bool { if case .running = kickState { return true } else { return false } }
    var isBusy: Bool { isKicking || runningTest != nil }

    var kickLine: String? {
        switch kickState {
        case .idle: return nil
        case .running(let hard): return hard ? "Kicking harder: Bluetooth and four services…" : "Kicking: restarting useractivityd and sharingd…"
        case .finished(let at, let hard, let summary):
            return "\(hard ? "Hard kick" : "Kick") at \(clockFmt.string(from: at)): \(summary)"
        }
    }

    func start() {
        monitor.onEvent = { [weak self] in self?.handle($0) }
        monitor.onPhoneChange = { [weak self] in self?.sync() }
        monitor.onReady = { [weak self] in
            self?.ready = true
            self?.sync()
        }
        monitor.start(historyMinutes: 180)
        refreshHealth()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refreshHealth() }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.tick += 1 }
    }

    func stop() {
        monitor.stop()
        capture?.process.terminate()
    }

    func refreshHealth() {
        DispatchQueue.global(qos: .utility).async {
            let h = checkHealth()
            DispatchQueue.main.async {
                self.health = h
                self.sync()
            }
        }
    }

    /// Re-diagnose; status changes go into the event log so it shows *when* it broke and why.
    private func sync() {
        events = monitor.recent
        guard ready else { return }
        let presence = monitor.phonePresence()
        if presence != lastPresence, presence != .unknown, let p = monitor.phone {
            if presence == .nearby {
                monitor.post(.phoneNearby, .nearby, .ok, "\(p.name) is nearby")
            } else {
                monitor.post(.phoneAway, .nearby, .warn, "\(p.name) isn't nearby (last heard \(ago(p.lastSeen)))")
            }
        }
        lastPresence = presence
        guard health.checked else { return }
        var v = diagnose(health, monitor)
        if fixPlan != nil, v.level != .bad {
            v = Verdict(level: .warn, headline: "The problem is on your iPhone",
                        detail: "This Mac checks out and hears your iPhone, but the iPhone isn't sharing. Try the fixes below, most likely first.")
        }
        verdict = v
        if v.headline != lastHeadline {
            lastHeadline = v.headline
            monitor.note(.note, v.level, "Status: \(v.headline)" + (v.level == .ok ? "" : ". \(v.detail)"))
        }
        onVerdict?(v)
    }

    private func handle(_ e: Event) {
        if e.signal == .serviceBroken, autoKick, !isKicking, Date().timeIntervalSince(lastAutoKick) > 300 {
            lastAutoKick = Date()
            kick(hard: false, reason: "automatic: the service wedged")
        }
        if let t = runningTest,
           (t.kind == .toMac && e.signal == .phoneOffered) || (t.kind == .toPhone && e.signal == .macSent) {
            finishTest(started: t.started)
        }
        sync()
    }

    // MARK: Kick

    func kick(hard: Bool, reason: String = "you pressed the button") {
        guard !isKicking else { return }
        kickState = .running(hard: hard)
        let name = hard ? "Hard kick" : "Kick"
        monitor.note(.kicked, .info, "\(name) started (\(reason))")
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            performKick(hard: hard) { line in
                lines.append(line)
                DispatchQueue.main.async { self.monitor.note(.note, .info, line) }
            }
            DispatchQueue.main.async {
                self.kickState = .finished(at: Date(), hard: hard, summary: lines.last ?? "done")
                self.monitor.note(.kicked, .ok, "\(name) done")
                self.refreshHealth()
            }
        }
    }

    // MARK: Tests

    func startTest(_ kind: TestKind) {
        guard !isBusy else { return }
        result = nil
        let seconds: TimeInterval = kind == .toMac ? 30 : 60
        let started = Date()
        runningTest = RunningTest(kind: kind, started: started, deadline: started.addingTimeInterval(seconds))
        startCapture()
        monitor.note(.note, .info, "Test started: \(kind == .toMac ? "iPhone → Mac" : "Mac → iPhone")")
        if kind == .toPhone {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("UC Doctor test \(clockSecFmt.string(from: started))", forType: .string)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.finishTest(started: started) }
    }

    func cancelTest() {
        guard runningTest != nil else { return }
        runningTest = nil
        _ = stopCapture()
        monitor.note(.note, .info, "Test cancelled")
    }

    private func finishTest(started: Date) {
        guard let t = runningTest, t.started == started else { return }
        runningTest = nil
        let file = stopCapture()
        let seen = { (s: Signal) in (self.monitor.last[s] ?? .distantPast) >= started }
        let secs = { (s: Signal) in Int((self.monitor.last[s] ?? started).timeIntervalSince(started)) }
        var r: (Outcome, String, String)
        var phoneSide = false // the Mac did its part and the iPhone is in range

        switch t.kind {
        case .toMac:
            let name = monitor.phone?.name ?? "Your iPhone"
            let beacon = monitor.lastPhoneBeacon.flatMap { $0.date >= started ? $0 : nil }
            if seen(.phoneOffered) || beacon?.clipboard == true {
                let at = [monitor.last[.phoneOffered], beacon?.date].compactMap { $0 }.min() ?? started
                r = (.passed, "The Mac heard your iPhone's clipboard",
                     "It showed up \(Int(at.timeIntervalSince(started)))s after you started. Press ⌘V to paste it. If nothing pastes, press Kick.")
            } else if let b = beacon {
                phoneSide = true
                r = (.failed, "\(name) is right here but didn't offer the copy",
                     "The Mac heard \(name) \(Int(b.date.timeIntervalSince(started)))s into the test, and its broadcast said it had nothing on its clipboard to share. The copy never left the iPhone. (Copy from Notes or Safari: some apps, like password managers, block sharing.)")
            } else if monitor.phonePresence() == .nearby, let p = monitor.phone {
                phoneSide = true
                r = (.failed, "\(name) is nearby but went quiet after the copy",
                     "The Mac heard it over Bluetooth \(ago(p.lastSeen)), but no Handoff broadcast came during the test. Keep it unlocked and stay in the app you copied from.")
            } else {
                r = (.failed, "Your iPhone isn't nearby",
                     (monitor.phone.map { "The Mac last heard \($0.name) \(ago($0.lastSeen)). " } ?? "This Mac hasn't heard your iPhone at all. ")
                     + "Bring it within a few metres, unlock it, and check Bluetooth is on (in Settings, not Control Center). Then test again.")
            }
        case .toPhone:
            if seen(.macSent) {
                r = (.passed, "Your iPhone pasted from the Mac", "Delivered \(secs(.macSent))s after the copy.")
            } else if !seen(.macCopied) {
                r = (.failed, "This Mac's clipboard service ignored the copy",
                     "useractivityd never picked up the test copy, so nothing was offered to the iPhone. Press Kick, then test again.")
            } else if seen(.phonePasted) {
                r = (.failed, "The iPhone asked, but the data never arrived",
                     (monitor.lastError.map { "Error: \($0.text)\n\n" } ?? "") + "The transfer stalled after the request. Press Kick Harder, then test again.")
            } else if seen(.phonePeeked) {
                r = (.unclear, "The iPhone saw the clipboard but didn't paste",
                     "Did you paste within 60 seconds? If you did and got old content, turn Handoff off and on on the iPhone.")
            } else if monitor.phonePresence() == .away {
                r = (.failed, "Your iPhone isn't nearby",
                     "The Mac last heard \(monitor.phone?.name ?? "it") \(ago(monitor.phone?.lastSeen)). Bring it close, unlock it, and test again.")
            } else {
                phoneSide = monitor.phonePresence() == .nearby
                r = (.failed, "The iPhone never asked for the Mac's clipboard",
                     "The Mac offered it, but no device came for it." + (phoneSide ? " Your iPhone is in range, so it's the side that isn't listening."
                        : " On the iPhone: check Handoff is on (Settings → General → AirPlay & Continuity), turn Bluetooth off and on, then test again."))
            }
        }
        updatePlan(kind: t.kind, outcome: r.0, phoneSide: phoneSide, result: &r)
        result = TestResult(kind: t.kind, outcome: r.0, title: r.1, advice: r.2, capture: file)
        monitor.note(.note, r.0 == .passed ? .ok : r.0 == .unclear ? .warn : .bad, "Test result: \(r.1)")
        sync()
    }

    // MARK: Fixing the iPhone side

    var lastFix: (fix: PhoneFix, date: Date)? {
        guard let raw = UserDefaults.standard.string(forKey: "lastPhoneFix"), let fix = PhoneFix(rawValue: raw) else { return nil }
        let t = UserDefaults.standard.double(forKey: "lastPhoneFixAt")
        return (fix, Date(timeIntervalSince1970: t))
    }

    /// The user did `fix` on the iPhone: re-run the test that failed.
    func tried(_ fix: PhoneFix) {
        guard var plan = fixPlan, !isBusy else { return }
        if !plan.tried.contains(fix) { plan.tried.append(fix) }
        plan.pending = fix
        fixPlan = plan
        monitor.note(.note, .info, "You tried \(fix.pastTense); testing again")
        startTest(plan.kind)
    }

    func dismissFixPlan() {
        fixPlan = nil
        sync()
    }

    private func updatePlan(kind: TestKind, outcome: Outcome, phoneSide: Bool, result r: inout (Outcome, String, String)) {
        if outcome == .passed {
            if let fix = fixPlan?.pending {
                UserDefaults.standard.set(fix.rawValue, forKey: "lastPhoneFix")
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastPhoneFixAt")
                monitor.note(.note, .ok, "Fixed by \(fix.pastTense). It'll be suggested first next time")
                r.1 = "Fixed: \(fix.pastTense) did it"
                r.2 += "\n\nUC Doctor will suggest \(fix.pastTense) first next time."
            }
            fixPlan = nil
            return
        }
        guard phoneSide, diagnose(health, monitor).level != .bad else { return }
        if var plan = fixPlan, plan.kind == kind {
            plan.pending = nil // what they just tried didn't do it
            fixPlan = plan
            if let next = plan.next { r.2 += "\n\nThat didn't fix it. Next: \(next.title.lowercased())." }
        } else {
            var steps = PhoneFix.allCases
            if let last = lastFix?.fix { steps.removeAll { $0 == last }; steps.insert(last, at: 0) }
            fixPlan = PhoneFixPlan(kind: kind, steps: steps)
            monitor.note(.note, .warn, "This Mac checks out; the problem is on the iPhone. Suggested first: \(steps[0].pastTense)")
            r.2 += "\n\nThis Mac checks out, so the fix is on the iPhone: see the steps above."
        }
    }

    /// For `ucdoctor snapshot … fixplan`: show the panel without running a real test.
    func showDemoFixPlan() {
        var steps = PhoneFix.allCases
        if let last = lastFix?.fix { steps.removeAll { $0 == last }; steps.insert(last, at: 0) }
        var plan = PhoneFixPlan(kind: .toMac, steps: steps)
        plan.tried = [steps[0]]
        fixPlan = plan
        sync()
    }

    /// While a test runs, save everything the clipboard daemons say, so a failure can be dissected later.
    private func startCapture() {
        let stamp = fileStampFmt.string(from: Date()).replacingOccurrences(of: ":", with: "").replacingOccurrences(of: " ", with: "-")
        let file = logDir.appendingPathComponent("test-\(stamp).log")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: file) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "compact", "--level", "debug", "--predicate",
                       #"subsystem == "com.apple.useractivity" OR subsystem BEGINSWITH "com.apple.sharing""#]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil { capture = (p, file) }
    }

    private func stopCapture() -> URL? {
        guard let c = capture else { return nil }
        capture = nil
        c.process.terminate()
        return c.file
    }

    func openLog() {
        if !FileManager.default.fileExists(atPath: eventLogURL.path) {
            try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: eventLogURL.path, contents: nil)
        }
        NSWorkspace.shared.open(eventLogURL)
    }
}
