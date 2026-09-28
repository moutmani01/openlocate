**Test build — not for production use.**

### Install
1. Download the `.apk` below on your Android phone (Android 7+).
2. Open it and allow *Install unknown apps* for your browser/files app when asked.
3. Updating from an earlier beta: if Android says the app "conflicts with an existing package", uninstall the old beta first (beta builds are not yet signed with a fixed key).

### Try it with two phones
1. Phone A: enter your name and the server address, tap **Create group**.
2. Phone A: tap the invite icon (top right) to show a QR code.
3. Phone B: enter a name, tap **Scan an invitation**, scan the code.
4. On each phone, turn on **Can see me** for the other person, then the main **Sharing** switch.
5. Choose an interval in Settings (15 s … 1 h). The card shows *requested* vs *actual* interval.
6. Tap a person to see their path for the last hour / today / 24 h / 7 days.

### What's in this beta
- Device identity (no account), QR pairing with single-use 10-minute invitations
- Per-person sharing (never automatic in both directions), key rotation when someone loses access
- End-to-end encrypted live location over one persistent connection; server history with retention (default 24 h)
- Foreground-service tracking with a visible notification (works with the screen off)
- Battery modes: maximum / balanced / saver
- Offline queue (in memory) that uploads when the connection returns

### Known limitations
- Android only; iOS comes later.
- Offline queue and received locations are kept in memory only — they are lost if the app is killed while offline.
- Map tiles come from openstreetmap.org (fine for testing, not for wide distribution).
- Peer-to-peer (WebRTC) is not enabled yet; updates go through the encrypted relay.
- QR scanning uses Google ML Kit via `mobile_scanner` (to be replaced with an open-source scanner).
