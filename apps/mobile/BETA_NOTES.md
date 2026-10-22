**Test build — not for production use.**

### Install
1. Download the `.apk` below on your Android phone (Android 7+).
2. Open it and allow *Install unknown apps* for your browser/files app when asked.
3. Updating from an earlier beta: if Android says the app "conflicts with an existing package", uninstall the old beta first (beta builds are not yet signed with a fixed key).

### New in beta.4
- **Fixes beta.3 not opening.** A library update made the app stop at its launch screen. If
  start-up ever fails again, the app now shows an error message to report instead.

### New in beta.3
- **Relay choice.** Creating a group asks for the **Default relay** (run by the project) or a
  **Private relay** (your own server, which must use https). The relay only ever sees encrypted
  updates and when they arrive. Each group stays on its relay; people you invite use it
  automatically. Settings shows which relay your group uses.
- The default relay now limits how many groups and requests one address can make per minute.
- No crash fix yet: the "app stopped" crash is still being investigated. If it happens, the
  commands in `docs/RELIABILITY.md` capture what Android recorded about it.

### Try it with two phones
1. Phone A: enter your name, keep **Default relay** (or pick **Private relay** and enter your
   server), tap **Create group**.
2. Phone A: tap the invite icon (top right) to show a QR code.
3. Phone B: enter a name, tap **Scan an invitation**, scan the code.
4. On each phone, turn on **Can see me** for the other person, then the main **Sharing** switch.
5. Choose an interval in Settings (15 s … 1 h). The card shows *requested* vs *actual* interval.
6. Tap a person to see their path for the last hour / today / 24 h / 7 days.

### What's in this beta
- Device identity (no account), QR pairing with single-use 10-minute invitations
- Per-person sharing (never automatic in both directions), key rotation when someone loses access
- End-to-end encrypted live location over one persistent connection; server history with retention (default 24 h)
- Tracking in its own background service with a visible notification: it keeps running with the
  screen off and after the app is swiped away, and the notification has a **Stop sharing** button
- Battery modes: maximum / balanced / saver
- Offline queue on disk: positions taken without a connection survive the app or the phone
  restarting, and upload when the connection returns
- Settings → **Background reliability**: battery-optimisation exemption, optional "Allow all the
  time" location access so Android can restart sharing by itself, optional resume after reboot

### Known limitations
- Android only; iOS comes later.
- Received locations are kept in memory only; they are fetched from the server again when the app opens.
- If Android kills the app outright, sharing restarts by itself only when battery optimisation is
  off **and** location access is "Allow all the time". Otherwise it resumes when you open the app,
  which tells you it had stopped.
- A person who is not moving sends no updates in *Balanced* and *Battery saver* modes, so their
  position can look old even though sharing is working.
- Map tiles come from openstreetmap.org (fine for testing, not for wide distribution).
- Peer-to-peer (WebRTC) is not enabled yet; updates go through the encrypted relay.
- QR scanning uses Google ML Kit via `mobile_scanner` (to be replaced with an open-source scanner).
