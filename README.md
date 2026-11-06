# UC Doctor

Finds out why Universal Clipboard (copy on your iPhone, paste on your Mac, and back) isn't working, and gets it going again.

Universal Clipboard fails silently. UC Doctor watches the macOS services behind it and tells you which side dropped the copy: this Mac, your iPhone, or the link between them.

## What it shows

- **Status:** the most likely cause right now: Bluetooth off, Handoff off, screen sharing, a stuck service, your iPhone out of range, or "the problem is on your iPhone".
- **Your iPhone:** whether the Mac can hear it over Bluetooth, and whether its last broadcast offered a clipboard.
- **Both directions:** when a clipboard last crossed each way, with a guided **Test** for each.
- **Fix it on your iPhone:** appears when the Mac checks out but a test shows the iPhone isn't sharing. It lists fixes (restart, Handoff off and on, Bluetooth off and on), re-tests after each one, and remembers which fix worked so it can suggest that one first next time.
- **Activity:** a plain-English history. The full log is in `~/Library/Logs/UC Doctor/events.log`.

## Buttons

- **Kick:** restarts `useractivityd` and `sharingd`, the Mac services that run Universal Clipboard. It takes half a second and nothing else drops.
- **Kick Harder:** also switches Handoff back on for this Mac, turns Bluetooth off and on (AirPods disconnect for a few seconds), and restarts `rapportd` and `pboard`. Your clipboard is kept.
- **Auto-kick:** restarts the service on its own when macOS logs that it has lost its link to `pboard`.

## Install

You need:

- macOS 13 or later (built and tested on macOS 27.2 with an iPhone on iOS 27)
- Xcode Command Line Tools: `xcode-select --install`
- An admin account (macOS only lets admins read the live system log)

```bash
git clone https://github.com/davidesqalv/ucdoctor.git
cd ucdoctor
./install.sh
```

This builds the app, installs it to `~/Applications/UC Doctor.app`, and sets it to start in the background at login. Closing the window doesn't stop it: it keeps watching and logging, and clicking the Dock icon brings the window back. A red badge on the Dock icon means something is wrong. Quitting (⌘Q) stops the logging until your next login.

To remove it, run `./uninstall.sh`. Add `--logs` to delete the logs too.

## Command line

```
ucdoctor status          # checks, diagnosis, your iPhone, last 2 hours of events
ucdoctor watch           # print clipboard events as they happen
ucdoctor kick [--hard]   # same as the buttons
```

The binary is `~/Applications/UC Doctor.app/Contents/MacOS/ucdoctor`.

## How it works

On the Mac, Universal Clipboard runs inside `useractivityd`, and its offers travel in Handoff Bluetooth broadcasts handled by `sharingd`. UC Doctor:

- follows the unified log for both services (`log stream`) and translates the lines it recognises
- checks Bluetooth, Wi-Fi, peer-to-peer Wi-Fi (`awdl0`), the Handoff switch and the services every 30 seconds

The most useful signal is a single flag. When you copy on a device, its next Handoff broadcast should carry `CopyPasteKey = 1`. If your iPhone is nearby but its broadcasts still say `CopyPasteKey = 0` after you copy, the copy never left the iPhone, and nothing you do on the Mac will help.

| Log line (abridged) | Shown as |
|---|---|
| `[PBOARD CONTROLLER] Got type update from client` | You copied on the Mac |
| `[PBOARD] Types Requested from remote` | A device looked at what the Mac is offering |
| `[PBOARD CONTROLLER] Pasteboard Sent Info` | Mac clipboard delivered |
| `[PBOARD CONTROLLER] Remove Local Types Fired` | Mac stopped offering its clipboard (offers last about 2 minutes) |
| `Received a new advertisement … CopyPasteKey = 1` | Your iPhone is offering its clipboard |
| `[PBOARD] Received pboard available advertisement` | A device announced a new clipboard |
| `[CODERV2] Calling pasteboard received handler` | Clipboard data received |
| `… remote copy/paste will no longer work` | The service is stuck (Auto-kick restarts it) |
| `Screen sharing session started, disabling universal clipboard` | macOS switched Universal Clipboard off |

The rules live in [`Sources/ucdoctor/Events.swift`](Sources/ucdoctor/Events.swift).

## Known iOS 27 bug

On iOS 27, iPhone → Mac can stop working while Mac → iPhone keeps going:

- the iPhone's broadcasts keep saying `CopyPasteKey = 0`
- restarting the iPhone fixes it for a while
- toggling Handoff or Bluetooth usually doesn't
- reports on whether iOS 27.2 fixes it are mixed

See the [Apple Developer Forums thread](https://developer.apple.com/forums/thread/845422) (FB24740548). UC Doctor recognises this pattern and puts **Restart the iPhone** first once a restart has fixed it for you.

## Limits

- It reads log messages Apple doesn't document, so a macOS update can change them and break a rule.
- Kick Harder uses a private Bluetooth call (the same one [`blueutil`](https://github.com/toy/blueutil) uses). macOS asks for Bluetooth permission the first time.
- It only sees your iPhone through what macOS logs, and can't change anything on the iPhone.
- It isn't on the App Store and isn't notarized, so you build it yourself with `install.sh`.

## Privacy

Everything stays on your Mac. UC Doctor reads the system log, writes its own log to `~/Library/Logs/UC Doctor`, and makes no network connections. The test captures (`test-*.log`) contain raw system log lines, including your devices' names, so check them before you share one.

## Not affiliated with Apple

Universal Clipboard, Handoff, iPhone and macOS are trademarks of Apple Inc. UC Doctor is an independent project and isn't affiliated with or endorsed by Apple.

## License

[MIT](LICENSE)
