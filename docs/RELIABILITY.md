# Reliability: target, evidence and suspects

Started 2026-10-21. This is the working file for roadmap priority 1. It says what "reliable"
means, how to collect evidence from a phone, and which causes of the "app stopped" crash are
suspected, with what would confirm or rule each out. Nothing here is a claim that a fix works on
a phone; results are added only when a phone has produced them.

## The target

A location app fails when the viewer sees an old position, whatever the cause: a crash, Android
killing the process silently, a lost network, or a bug. So the target measures what the viewer
sees, not whether the app crashed.

**Freshness.** For a sharer with update interval *I*, sample once a minute the age of the
newest position a group member has received from them. The sample is *fresh* when that age is at
most `2 × I`, with a floor of 5 minutes. In *Balanced* and *Battery saver* modes a phone that is
not moving sends nothing, so freshness cannot pass there until the heartbeat (roadmap item
"Heartbeat while standing still") exists; until then those modes are measured while moving only.

**Pass threshold**, per phone, over 24 hours with the battery exemption granted:

- at least 95 % of samples fresh;
- no exit with reason crash, crash (native) or not responding in `dumpsys activity exit-info`;
- every gap longer than 15 minutes explained by an exit reason, the phone being off, or no
  network.

The observer is a group member that only records arrivals (see "Soak test" below). It is not the
server: the server does not store when events arrive, and this work does not change that.

## Evidence from a phone

Connect the phone with USB debugging on, then run these on a computer with `adb`. Send back the
files; they contain no positions, because the app does not log any, but the bug report holds the
phone's general system state, so read it before sharing it with anyone else.

```bash
adb devices                                   # the phone must be listed as "device"
adb shell getprop ro.build.version.release    # Android version
adb shell getprop ro.product.manufacturer     # maker
adb shell dumpsys package org.openlocate.openlocate | grep -E "versionName|targetSdk"

# Why the app last stopped, as recorded by Android (crash, ANR, low memory, killed by the user…)
adb shell dumpsys activity exit-info org.openlocate.openlocate > exit-info.txt

# Java and native crash logs kept since the last reboot
adb logcat -d -b crash > crash.txt

# Recent general log lines from the service and the plugins
adb logcat -d -v time | grep -iE "openlocate|ForegroundService|flutter|RestartReceiver|FGS|AndroidRuntime" > app-log.txt

# Background restrictions applied to the app
adb shell dumpsys deviceidle whitelist | grep -i openlocate > battery.txt
adb shell am get-standby-bucket org.openlocate.openlocate >> battery.txt
adb shell cmd appops get org.openlocate.openlocate RUN_ANY_IN_BACKGROUND >> battery.txt

# Everything at once (large zip, includes the above and battery history)
adb bugreport bugreport.zip
```

If the package name differs, find it with `adb shell pm list packages | grep -i locate`.

## Suspects for the "app stopped" crash, ranked

The dialog appears for an uncaught Java or native exception, or an Android-enforced failure. An
uncaught Dart error does not show it (Flutter logs it and carries on), so the suspects are on the
Android side.

### 1. Restart from the background throws on Android 14+ (most likely)

The app targets the newest Android (Flutter's default target is API 36). Since Android 14, a
foreground service of type `location` may start only while the app is allowed to use location
*at that moment*. With "while in use" permission, that means while the app is visible.

`flutter_foreground_task` 11.0.3 restarts the service from the background in three ways, all
enabled by `allowAutoRestart: true` (always on in `tracker.dart`) or `autoRunOnBoot`:

- the service is destroyed without `stopService` → `RestartReceiver.setRestartAlarm(5000)`;
- the process is killed → `START_STICKY` restart with a null intent;
- the phone reboots → `RebootReceiver` (only when the restart-after-reboot option is on).

The alarm path calls `startForegroundService()`; the service then calls
`startForeground(…, location)`, which throws `SecurityException` without background location.
The plugin catches it and calls `stopSelf()`, so `startForeground` never completes. Android
then raises `ForegroundServiceDidNotStartInTimeException` ("Context.startForegroundService() did
not then call Service.startForeground()"), which is the "app stopped" dialog, possibly while the
app is not even open.

- **Confirms:** `crash.txt` or `exit-info.txt` naming `ForegroundServiceDidNotStartInTimeException`,
  `RemoteServiceException`, or `SecurityException: Starting FGS with type location`.
- **Rules out:** a crash with only "while in use" never coincides with a service restart, or
  the same crash happens with "Allow all the time".
- **Reproduce:** grant "while in use" only, start sharing, leave the app, then
  `adb shell am kill org.openlocate.openlocate` or stop the service process, and watch the crash
  buffer.

### 2. Android kills the process silently (most likely cause of stale positions, no dialog)

Low memory, the restricted standby bucket, or the maker's own task killer (Xiaomi, Samsung,
Huawei) stop the process without an error. Combined with suspect 1, the restart then fails.

- **Confirms:** `exit-info.txt` reasons `LOW_MEMORY`, `USER_REQUESTED` (from a maker's cleaner),
  `EXCESSIVE_RESOURCE_USAGE` or `FREEZER`; `am get-standby-bucket` returning 45 (restricted).
- **Reproduce:** `adb shell am set-standby-bucket org.openlocate.openlocate restricted`,
  `adb shell dumpsys deviceidle force-idle`, `adb shell am kill …`.

### 3. A start-up failure before any screen appears

`main.dart` awaits libsodium, secure storage and `AppState.init()` before `runApp`, with no error
handling. A failure there (for example a keystore error in `flutter_secure_storage`) leaves a
blank screen rather than the dialog, so it explains "the app does not open", not "app stopped".
It still needs a guard and a visible error.

- **Confirms:** a Dart exception at start-up in `app-log.txt`.

### 4. A native crash in a plugin

libsodium (`sodium`), the camera scanner (`mobile_scanner`) or the map. These produce
`Fatal signal` lines and a tombstone.

- **Confirms:** `crash.txt` with `*** *** ***` native backtrace, or exit reason `CRASH_NATIVE`.

### 5. Crashes from builds before beta.2

The crash was reported on builds that tracked location inside the app, before the service
existed. If it never appears on beta.2, the evidence above will show that; the earlier suspects
(restarting tracking at launch, no error handling at start-up) no longer apply as written.

## Emulator results (2026-10-21)

Android 15 emulator (API 35, x86_64), beta.2 code built as a debug APK, "while in use" location
only, sharing on in a one-member test group on the default relay, app in the background.

| Scenario | Result |
| --- | --- |
| Process killed (`kill -9`), normal standby | Android restarted the service after 1 s; it kept the location capability (`curCapability=L…`). No crash. |
| Process killed in the *restricted* standby bucket | Restarted after 4 s. No crash. |
| App reopened after the restart | No crash; one foreground service, not two. |

So the restart-after-kill path, the first form of suspect 1, does not crash on Android 15. Not
yet tried: the plugin's own alarm restart (needs the service destroyed without being stopped),
reboot with restart-after-reboot on, Android 14, and real makers' task killers. Suspect 1 drops
below the evidence from a real phone: the next step is the `adb` capture above.

Emulator notes for this machine: the emulator crashes with its GPU emulation unless started with
`-gpu swangle_indirect`, and the app must run with Flutter's software renderer
(`--ez enable-software-rendering true`) and Impeller turned off in a test-only manifest entry.

## Soak test

To be written with the observer tool; see the roadmap item "Soak tests".
