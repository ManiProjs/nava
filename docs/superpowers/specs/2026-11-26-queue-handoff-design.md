# Design: Your music follows you (cross-device queue handoff)


## Context / why
The goal is to get more Navidrome users onto Nava. The audience we chose is **people who listen on more than one device** (phone on the go, laptop/desktop at home) and today use a different client on each one. Nava's pitch to them: *one free app that feels the same everywhere, and your music follows you.* Rival clients each do well on one platform (Symfonium on Android, Feishin on desktop). A queue that carries over between platforms is something they can't easily match, and it builds on the playlist/favorites sync Nava just shipped (`df7cf63`).

This is the first of two pieces of work. The second, **streaming quality per connection** (Wi‑Fi vs cellular bitrate via transcoding), is separate and gets its own design afterward.

## Goals
1. **Same-device resume:** after a restart, Nava comes back with the same queue, the same current track and the same position, paused. Today only the queue list survives (`_saveQueue` in `lib/src/playback.dart:136`, restored in `lib/src/home_data.dart:543`). The current index and position are restored only for Flow sessions.
2. **Cross-device handoff:** when you open (or return to) Nava on device B after listening on device A, a **"Continue from <device>"** banner shows the track and position. One tap loads A's queue on B, paused at that position. B's own queue stays untouched until you tap.

## Non-goals
- Live remote control or "play on another device" (Spotify Connect-style).
- Syncing queues for tracks from local folders, or Flow session state, across devices.
- Supporting Subsonic servers other than Navidrome (the API exists on others, but we test against Navidrome only).
- Streaming quality settings (next project).

## Anti-goals (a failure even if it technically works)
- Device B's queue gets overwritten without the user asking.
- The banner nags: it shows up for your own device's save, for a stale queue, or again after you dismissed it.
- Playback stutters, or the UI waits on the network, because of queue saving.
- Something breaks while offline (saves must fail silently and must not join the scrobble retry queue).

## Approaches considered
- **A. Navidrome play queue: `savePlayQueue` / `getPlayQueue` (chosen).** Built in. Stores the track IDs, current ID, position (ms), `changed` time and `changedBy` (client name). One queue per user, where the last save wins. Tracks from local folders can't be included. Other clients using this API may read and write the same queue, which is acceptable.
- **B. A hidden "Nava queue" playlist with metadata in its comment.** Rejected: it clutters other clients' playlist lists, the comment field is a hack, and the existing playlist sync would have to skip it.
- **C. Device-to-device over the LAN.** Rejected: it fails in the main case, leaving home with your phone.

## Decided parts of the how
- **Device identity:** the Subsonic `c` param becomes `Nava · <device name> · <id>` (currently the hard-coded `'c': 'Nava'` at `lib/navidrome_client.dart:462`). `<id>` is a short random tag (e.g. 4 hex chars) generated once and stored in SharedPreferences. *(My call: names like "iPhone" collide, and without the tag two same-named devices would each treat the other's saves as their own, so the banner would silently never show.)* The device is recognised by the tag. The banner shows only the name part ("from MacBook"). Default name is the hostname / device model, editable in Settings. *(Builder's call how to get it per platform.)*
- **Navidrome player entries:** because `c` changes, each device appears as a new player in Navidrome, and any per-player settings an existing user set on the old "Nava" player (e.g. transcoding) stop applying. *(My call: accept this and mention it in the release notes. The streaming-quality project will send `maxBitRate`/`format` with each request instead of relying on per-player server settings.)*
- **Local resume:** persist `currentId`, `queueIndex` and `positionMs` alongside the existing `_queueKey` entry (the same shape the Flow session already uses in `lib/src/flow_logic.dart:~190`). On launch, restore paused at that position.
- **Only real listening counts:** a device saves to the server only after **real local activity since launch or since the last accepted handoff**: pressing play, seeking, skipping, or the user editing the queue. Restoring the queue at launch, showing the banner, and browsing don't count. *(My call: otherwise a device that was merely opened would overwrite the other device's newer queue with its own stale one.)*
- **When to save to the server** (once real activity has happened): on pause, on track change, when the queue is edited, when the app goes to the background or is detached (`didChangeAppLifecycleState`, `lib/main.dart:632`), plus a throttled save during playback (~every 30 s) so a crash or kill loses little. Debounce so bursts of skips cause one save. Fire-and-forget: it never blocks the UI.
- **When to check the server:** at launch after connecting, and on `AppLifecycleState.resumed`.
- **When the banner shows:** the server queue's `changedBy` ≠ this device, **and** it differs from the local queue (different current track, or position more than ~10 s apart), **and** `changed` is newer than the last server `changed` value this device has seen (from its own last save, or from a banner it accepted or dismissed). *(My call: compare only server timestamps with each other, never with the device's clock, so a device clock that's off can't break it.)* The "2 min ago" label is for display only, so a wrong device clock can make the label wrong but can't hide the banner or show it wrongly.
- **Banner UI:** a dismissible card above the mini-player / on Home:
  ```
  ┌───────────────────────────────────────────┐
  │ ▶ Continue from MacBook · 2 min ago       │
  │   Song Title — Artist      at 2:41    [✕] │
  └───────────────────────────────────────────┘
  ```
  Tap → replace the local queue, seek, stay paused (or play: builder's call, keep it consistent with local resume). ✕ → remember the dismissed `changed` timestamp.
- **Mixed queues:** local-folder tracks are left out of the server save. If the current track is local-only, skip the server save for that moment.
- **Offline / Flow:** nothing is saved while `_offlineMode` is on. Flow sessions keep their own resume and are not synced. While Flow is active, don't save Flow's generated queue to the server.

## Left to the builder
- How the device name is detected on each platform, and the exact Settings UI for renaming it.
- Throttle/debounce constants, and where the banner sits on desktop vs mobile layouts.
- Code structure: likely a small `PlayQueueSync` unit next to `lib/server_sync.dart` with an injectable client so it can be unit-tested, plus `getPlayQueue` / `savePlayQueue` in `lib/navidrome_client.dart`.

## Verification
- Unit tests (`flutter test`), in the style of `test/sync_scrobble_offline_test.dart` with a fake client: save is skipped offline; local-only tracks are filtered; the banner rules (own device, stale, dismissed, differing position) behave as listed above; two devices with the same name still see each other's saves; a device opened without playing never saves.
- Widget test: the banner appears, accepting replaces the queue and seeks, dismissing hides it for good.
- Manual: run macOS (`flutter run -d macos`) and the Android emulator against the same Navidrome account. Play on one, pause, open the other, and check the banner text, track and position. Restart a single device and confirm it resumes in the same place.
