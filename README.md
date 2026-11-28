# Nava

Nava is a cross-platform music player for [Navidrome](https://www.navidrome.org/) servers, built with Flutter. It brings your streamed music library, playback queue, favorites, playlists, and listening insights into a focused desktop-and-mobile app.

## Features

- **Navidrome connection** — connect to your own server with its URL and account credentials.
- **Music library** — browse your collection and search for tracks without dumping the entire library into search results.
- **Playback controls** — play, pause, skip, seek through tracks, shuffle, repeat, and manage the Up Next queue.
- **Mini-player and full player** — keep playback controls close, or open the animated full-screen player with artwork and optional visualizer.
- **Personalized Home** — Quick start, listening-based picks, discovery suggestions, and your most-played artists.
- **Favorites and playlists** — save favorites and create local playlists.
- **Listening stats** — review listening activity and the history stored on your device.
- **Local recommendations** — a lightweight ranking algorithm uses listening recency, familiar artists and albums, and favorites to suggest tracks. It runs locally and does not require an AI API key.
- **Offline downloads** — download tracks, albums, artists, playlists or all favorites. Downloaded music plays with no connection, and Nava opens with your downloads if the server is unreachable.
- **Server sync** — playlists and favorites are merged both ways with your Navidrome account, so changes on one device appear on the others. Local files stay on the device.
- **Scrobbling** — listens (half a track or four minutes) are sent to Navidrome, and so to any Last.fm or ListenBrainz linked to it. Listens made offline are queued and sent later.
- **Desktop shortcuts** — Space, arrow keys, media keys, `L` to like, `S`/`R` for shuffle/repeat, `/` for search, `?` for the full list.
- **Preferences** — adjust reduced motion, automatic track advancement, and the player visualizer.
- **Cross-platform Flutter app** — platform folders are included for Android, iOS, Linux, macOS, Windows, and web.

## Requirements

- [Flutter](https://docs.flutter.dev/get-started/install) with a Dart SDK compatible with the version in `pubspec.yaml`.
- Access to a running Navidrome server and a user account on that server.
- Network access from the device running Nava to the server URL.

## Getting started

Clone or download this repository, then run these commands from the project directory:

```sh
flutter pub get
flutter run
```

When Nava opens, use the connection flow to enter your Navidrome server URL, username, and password. Use the server's reachable **HTTPS** address. ~~Plain HTTP connections are rejected because they expose authentication tokens and streamed traffic to network interception~~ Nava doesn't require HTTPS anymore, although it's highly recommended to add one.

## Build

Choose the target platform and run its Flutter build command:

```sh
# macOS
flutter build macos

# Linux
flutter build linux

# Windows
flutter build windows

# Android APK
flutter build apk

# iOS (requires macOS and Xcode)
flutter build ios

# Web
flutter build web
```

Platform-specific prerequisites still apply. For example, iOS builds require Xcode, and Android release builds may need signing configuration.

## Development checks

Run the formatter, static analyzer, and tests before submitting changes:

```sh
dart format lib test
flutter analyze
flutter test
```

## Data and privacy

Nava stores ordinary app preferences, favorites, local playlists, and listening history in local app preferences. Listening history is used by the on-device recommendation algorithm and stats views. Navidrome credentials are stored using Android Keystore-backed AES-GCM on Android, the Secret Service keyring on Linux, and Windows DPAPI on Windows. Linux desktop builds require a working Secret Service keyring and `secret-tool`; credential saving fails closed if it is unavailable. On iOS and macOS, credentials remain in plain-text app preferences, and the app displays this warning: `WARNING: Your Navidrome credentials are stored in plain text on your platform. Blame Apple for this.` Keep your device account protected and only connect to servers you trust.

Recommendations are algorithmic and local; the current project does not require a cloud AI provider. Music files and streaming are served by your Navidrome server.

## Tech stack

- [Flutter](https://flutter.dev/) and Dart
- [Navidrome](https://www.navidrome.org/) with its Subsonic-compatible API
- [`just_audio`](https://pub.dev/packages/just_audio) for audio playback
- [`http`](https://pub.dev/packages/http) for API requests
- [`shared_preferences`](https://pub.dev/packages/shared_preferences) for local app settings and data
- [`crypto`](https://pub.dev/packages/crypto) for request authentication

## License

See [`LICENSE`](LICENSE) for the project's license.
