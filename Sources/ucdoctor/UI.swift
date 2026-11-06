import SwiftUI

extension Level {
    var color: Color {
        switch self {
        case .ok: return .green
        case .info: return .secondary
        case .warn: return .orange
        case .bad: return .red
        }
    }

    var headerSymbol: String {
        switch self {
        case .ok: return "checkmark.seal.fill"
        case .info: return "hourglass"
        case .warn: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.octagon.fill"
        }
    }
}

private let cardFill = Color(nsColor: .controlBackgroundColor)
private let hairline = Color(nsColor: .separatorColor)

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showAll = false

    var body: some View {
        VStack(spacing: 0) {
            StatusHeader(model: model)
            Divider()
            VStack(spacing: 14) {
                PhoneStrip(model: model)
                if let plan = model.fixPlan { FixPanel(model: model, plan: plan) }
                HStack(alignment: .top, spacing: 14) {
                    DirectionCard(model: model, kind: .toMac)
                    DirectionCard(model: model, kind: .toPhone)
                }
                .fixedSize(horizontal: false, vertical: true) // cards size to content, equal heights
                ChecksBar(model: model)
            }
            .padding(20)
            Divider()
            ActivityView(model: model, showAll: $showAll)
        }
        .frame(minWidth: 780, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Header: verdict + Kick buttons

struct StatusHeader: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let v = model.verdict
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: v.level.headerSymbol)
                .font(.system(size: 42))
                .foregroundStyle(v.level.color)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(v.headline).font(.title2.weight(.semibold))
                Text(v.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let line = model.kickLine {
                    Label(line, systemImage: "bolt.fill").font(.callout).foregroundStyle(.secondary).padding(.top, 2)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                Button { model.kick(hard: false) } label: {
                    Label("Kick", systemImage: "bolt.fill").frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .help("Restart useractivityd and sharingd (half a second, nothing else drops).")
                Button { model.kick(hard: true) } label: {
                    Text("Kick Harder").frame(minWidth: 120)
                }
                .help("Also re-enables Handoff, restarts Bluetooth (AirPods drop for a few seconds), and restarts rapportd and pboard. Your clipboard is kept.")
            }
            .controlSize(.large)
            .disabled(model.isBusy)
        }
        .padding(20)
        .background(v.level.color.opacity(0.08))
    }
}

// MARK: - Your iPhone: nearby or not, and whether it's offering a clipboard

struct PhoneStrip: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let m = model.monitor
        let presence = m.phonePresence()
        let since = clockFmt.string(from: m.historySince)
        HStack(spacing: 14) {
            Image(systemName: "iphone")
                .font(.system(size: 26))
                .foregroundStyle(presence == .nearby ? Color.green : presence == .away ? Color.orange : Color.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(m.phone?.name ?? "Your iPhone").font(.headline)
                    Text(presence == .nearby ? "Nearby" : presence == .away ? "Not nearby" : "Not seen yet")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill((presence == .nearby ? Color.green : presence == .away ? Color.orange : Color.secondary).opacity(0.18)))
                }
                Text(presence == .nearby ? "Heard over Bluetooth \(ago(m.phone?.lastSeen))"
                     : presence == .away ? "Last heard \(ago(m.phone?.lastSeen)). Bring it close and unlock it."
                     : "Not heard since \(since). Unlock it near this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("Clipboard in its last broadcast").font(.callout).foregroundStyle(.secondary)
                if let b = m.lastPhoneBeacon {
                    Text(b.clipboard ? "Yes · \(ago(b.date))" : "None · \(ago(b.date))")
                        .font(.headline)
                        .foregroundStyle(b.clipboard ? Color.green : Color.primary)
                } else {
                    Text("No broadcast since \(since)").font(.headline).foregroundStyle(.secondary)
                }
            }
            .help("When you copy on the iPhone, its next Handoff broadcast should carry a clipboard flag. \"None\" right after a copy means the iPhone isn't sharing it.")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hairline))
    }
}

// MARK: - Fix it on your iPhone

struct FixPanel: View {
    @ObservedObject var model: AppModel
    let plan: PhoneFixPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.orange)
                Text("Fix it on your iPhone").font(.headline)
                Spacer()
                Button("Dismiss") { model.dismissFixPlan() }.buttonStyle(.borderless)
            }
            Text(plan.exhausted
                 ? "None of these did it. Last resort on the iPhone: Settings → General → Transfer or Reset iPhone → Reset → Reset Network Settings (it forgets saved Wi-Fi passwords)."
                 : "Do one on the iPhone, then press its button. UC Doctor re-runs the \(plan.kind == .toMac ? "iPhone → Mac" : "Mac → iPhone") test to check.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(plan.steps.enumerated()), id: \.element) { index, fix in
                FixRow(model: model, plan: plan, number: index + 1, fix: fix)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.35)))
    }
}

struct FixRow: View {
    @ObservedObject var model: AppModel
    let plan: PhoneFixPlan
    let number: Int
    let fix: PhoneFix

    var body: some View {
        let testing = plan.pending == fix && model.runningTest != nil
        let failed = plan.tried.contains(fix) && plan.pending != fix
        let isNext = plan.next == fix && plan.pending == nil
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(failed ? Color.secondary.opacity(0.2) : isNext ? Color.orange : Color.secondary.opacity(0.15))
                if failed {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                } else {
                    Text("\(number)").font(.callout.weight(.semibold)).foregroundStyle(isNext ? Color.white : Color.primary)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(fix.title).font(.body.weight(isNext ? .semibold : .regular))
                        .foregroundStyle(failed ? Color.secondary : Color.primary)
                    if let last = model.lastFix, last.fix == fix {
                        Text("Fixed it last time · \(formatterShort.string(from: last.date))")
                            .font(.caption.weight(.semibold)).foregroundStyle(.green)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.15)))
                    }
                }
                Text("\(fix.how) · \(fix.time)").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if testing {
                ProgressView().controlSize(.small)
                Text("Testing…").foregroundStyle(.secondary)
            } else if failed {
                Text("Didn't fix it").foregroundStyle(.secondary)
            } else if isNext {
                Button("Done – test again") { model.tried(fix) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
            } else {
                Button("Done – test again") { model.tried(fix) }
                    .disabled(model.isBusy)
            }
        }
    }
}

private let formatterShort: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM d"
    return f
}()

// MARK: - Direction cards with built-in tests

struct DirectionCard: View {
    @ObservedObject var model: AppModel
    let kind: TestKind

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: kind == .toMac ? "iphone" : "laptopcomputer")
                Image(systemName: "arrow.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Image(systemName: kind == .toMac ? "laptopcomputer" : "iphone")
                Text(kind == .toMac ? "iPhone → Mac" : "Mac → iPhone").font(.headline).padding(.leading, 4)
            }
            if let t = model.runningTest, t.kind == kind {
                RunningTestView(model: model, test: t)
            } else if let r = model.result, r.kind == kind {
                ResultView(model: model, result: r)
            } else {
                stats
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    Button { model.startTest(kind) } label: { Label("Test", systemImage: "play.fill") }
                        .disabled(model.isBusy)
                    Text(kind == .toMac ? "Unlock your iPhone; you'll have 30 s to copy something on it."
                                        : "Copies a test line here; you'll have 60 s to paste it on your iPhone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hairline))
    }

    @ViewBuilder private var stats: some View {
        let since = model.since
        if kind == .toMac {
            Stat(label: "Last iPhone copy this Mac heard",
                 date: [model.last(.phoneOffered), model.last(.phoneClipboard)].compactMap { $0 }.max(), since: since)
            Text("Last paste from another device: \(ago(model.last(.macReceived), orNoneSince: since))")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Stat(label: "Last delivery to your iPhone", date: model.last(.macSent), since: since)
            Text("Last Mac copy offered: \(ago(model.last(.macCopied), orNoneSince: since))\nLast time a device checked it: \(ago(model.last(.phonePeeked), orNoneSince: since))")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct Stat: View {
    let label: String
    let date: Date?
    let since: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Text(date == nil ? "None since \(clockFmt.string(from: since))" : ago(date))
                .font(.title3.weight(.semibold))
                .foregroundStyle(date == nil ? Color.secondary : Color.primary)
        }
    }
}

struct RunningTestView: View {
    @ObservedObject var model: AppModel
    let test: RunningTest

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let total = test.deadline.timeIntervalSince(test.started)
            let left = max(0, test.deadline.timeIntervalSince(context.date))
            VStack(alignment: .leading, spacing: 10) {
                Text(test.kind == .toMac ? "Copy some text on your iPhone now" : "Paste on your iPhone now")
                    .font(.title3.weight(.semibold))
                Text(test.kind == .toMac
                     ? "Keep it unlocked and near this Mac. The test ends as soon as the Mac hears the copy."
                     : "The Mac clipboard holds a test line. Paste it anywhere on the iPhone (Notes works).")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ProgressView(value: total - left, total: total)
                HStack {
                    Text("\(Int(left.rounded(.up)))s left").monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.cancelTest() }
                }
            }
        }
    }
}

struct ResultView: View {
    @ObservedObject var model: AppModel
    let result: TestResult

    private var color: Color { result.outcome == .passed ? .green : result.outcome == .unclear ? .orange : .red }
    private var symbol: String {
        result.outcome == .passed ? "checkmark.circle.fill" : result.outcome == .unclear ? "questionmark.circle.fill" : "xmark.circle.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(result.title).font(.body.weight(.semibold))
            }
            Text(result.advice).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
            HStack {
                Button("Test Again") { model.startTest(result.kind) }.disabled(model.isBusy)
                if let file = result.capture {
                    Button("Show Raw Log") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
                Spacer()
                Button("Done") { model.result = nil }
            }
        }
    }
}

// MARK: - Checks

struct ChecksBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(checkChips(model.health)) { chip in
                HStack(spacing: 5) {
                    Image(systemName: chip.ok == nil ? "circle.dotted" : chip.ok! ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(chip.ok == nil ? Color.secondary : chip.ok! ? Color.green : Color.red)
                    Text(chip.id)
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(cardFill))
                .overlay(Capsule().strokeBorder(hairline))
                .help(chip.help)
            }
            Spacer()
            Text("Devices heard: \(ago(model.last(.beacon), orNoneSince: model.since))")
                .font(.callout).foregroundStyle(.secondary)
                .help("Handoff beacons from your iPhone, iPad or Watch. Recent means Bluetooth reception works.")
        }
    }
}

// MARK: - Activity

struct ActivityView: View {
    @ObservedObject var model: AppModel
    @Binding var showAll: Bool

    var body: some View {
        let rows = model.events.reversed().filter { showAll || $0.isNotable }
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Activity").font(.headline)
                Picker("Show", selection: $showAll) {
                    Text("Important").tag(false)
                    Text("Everything").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                Spacer()
                Toggle("Auto-kick when it wedges", isOn: $model.autoKick)
                    .toggleStyle(.checkbox)
                    .help("If macOS logs that the clipboard service lost its link to pboard, restart it automatically.")
                Button("Open Log File") { model.openLog() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            if rows.isEmpty {
                VStack(spacing: 6) {
                    Text(showAll ? "No clipboard activity yet." : "Nothing notable since \(clockFmt.string(from: model.since)).")
                        .foregroundStyle(.secondary)
                    if !showAll {
                        Text("Switch to Everything to see every copy and check.").font(.callout).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rows) { EventRow(event: $0) }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(minHeight: 160)
    }
}

struct EventRow: View {
    let event: Event

    private var symbol: String {
        if event.signal == .kicked { return "bolt.fill" }
        switch event.level {
        case .ok: return "checkmark.circle.fill"
        case .info: return "circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(clockSecFmt.string(from: event.date))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
            Image(systemName: symbol)
                .font(event.level == .info && event.signal != .kicked ? .system(size: 5) : .body)
                .foregroundStyle(event.signal == .kicked ? Color.accentColor : event.level.color)
                .frame(width: 16)
            Text(event.text).lineLimit(2)
            Spacer(minLength: 8)
            Text(event.lane.rawValue).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .help(event.raw.isEmpty ? event.text : event.raw)
    }
}
