# OpenLocate on iPhone

Status: first iOS build, 2026-10-22. Built and smoke-tested on the iOS Simulator by GitHub
Actions; not yet tested on a real iPhone.

## How it differs from Android

| | Android | iOS |
| --- | --- | --- |
| Where sharing runs | A foreground service with its own isolate | Inside the app |
| What shows it is running | An ongoing notification with **Stop sharing** | The blue location indicator in the status bar |
| With the screen off | Keeps sharing | Keeps sharing (background location mode) |
| App swiped away | Service keeps running | Sharing stops until the app is opened again |
| Battery settings | Battery-optimisation exemption | None to set |

Relaunching sharing after the app is swiped away needs "Always" location access and a small
piece of native code (significant location changes). It is planned, not built.

The sharing logic itself (encryption, the on-disk queue, upload and retry) is the same code on
both platforms: `apps/mobile/lib/location/sharing_engine.dart`.

## Installing without a paid Apple Developer account

Each build of the iOS workflow produces an **unsigned** `.ipa`: under the run's artifacts, and
attached to each pre-release. iOS installs only signed apps, so it has to be signed with your own
Apple ID. A free Apple ID works, with limits: the app must be re-signed every 7 days, and only a
few sideloaded apps can be active at once.

One way that works from Linux, Windows or macOS:

1. On the iPhone, set a passcode and turn on **Developer Mode** (Settings → Privacy & Security).
2. On a computer, install [iloader](https://github.com/nab138/iloader). On Linux it needs
   `usbmuxd` (on Fedora: `sudo dnf install usbmuxd`).
3. Connect the iPhone by USB, open iloader, sign in with your Apple ID, and install
   **SideStore**. iloader also sets up SideStore's pairing file, so the computer is not needed
   afterwards.
4. Download the OpenLocate `.ipa` to the iPhone and open it with SideStore. SideStore signs and
   installs it.
5. Open SideStore at least once every 7 days to refresh the signature. If it expires, the app
   stops opening until it is refreshed; its data is kept.

A paid Apple Developer account ($99 a year) would allow TestFlight instead, with no weekly
refresh.

## Checks the CI runs on every change

- `flutter analyze` and the unit tests.
- A launch on the simulator, which fails the build if the app reports an error at start-up or is
  not running 45 seconds later. A screenshot is kept as the `ios-simulator-screenshot` artifact.
  Simulators run debug builds only, so this does not cover release-only problems like the one in
  Android beta.3; a real iPhone does.
