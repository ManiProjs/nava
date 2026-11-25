// lib/offline_store.dart
//
// Tracks downloaded for offline listening. Files live in the app's private
// storage; a small JSON index (kept in SharedPreferences by the caller) maps
// track ids to files and remembers the track metadata so the library can still
// be shown with no server connection.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'navidrome_client.dart';

class OfflineEntry {
  const OfflineEntry({
    required this.track,
    required this.fileName,
    required this.bytes,
    this.artFileName,
  });

  final MusicTrack track;
  final String fileName;
  final int bytes;
  final String? artFileName;

  Map<String, dynamic> toJson() => {
    'track': track.toJson(),
    'file': fileName,
    'bytes': bytes,
    'art': artFileName,
  };

  factory OfflineEntry.fromJson(Map<String, dynamic> json) => OfflineEntry(
    track: MusicTrack.fromJson(Map<String, dynamic>.from(json['track'] as Map)),
    fileName: json['file'] as String,
    bytes: (json['bytes'] as num?)?.toInt() ?? 0,
    artFileName: json['art'] as String?,
  );
}

enum DownloadStatus { none, queued, downloading, downloaded, failed }

class _Job {
  _Job(this.track, this.client);
  final MusicTrack track;
  final NavidromeClient client;
  final Completer<void> done = Completer<void>();
  bool cancelled = false;
}

class OfflineStore extends ChangeNotifier {
  OfflineStore({
    required this.directoryProvider,
    required this.persist,
    http.Client? httpClient,
    this.maxConcurrent = 2,
  }) : _http = httpClient ?? http.Client();

  /// Where audio files are kept.
  final Future<Directory> Function() directoryProvider;

  /// Called with the encoded index whenever it changes.
  final Future<void> Function(String encodedIndex) persist;
  final http.Client _http;
  final int maxConcurrent;

  final Map<String, OfflineEntry> _entries = {};
  final Map<String, double> _progress = {};
  final Map<String, String> _failures = {};
  final List<_Job> _queue = [];
  final Map<String, _Job> _jobs = {};
  int _active = 0;
  Directory? _directory;

  int get totalBytes =>
      _entries.values.fold(0, (sum, entry) => sum + entry.bytes);
  int get count => _entries.length;
  int get pendingCount => _jobs.length;
  Iterable<OfflineEntry> get entries => _entries.values;

  bool has(String id) => _entries.containsKey(id);

  DownloadStatus statusOf(String id) {
    if (_entries.containsKey(id)) return DownloadStatus.downloaded;
    if (_progress.containsKey(id)) return DownloadStatus.downloading;
    if (_jobs.containsKey(id)) return DownloadStatus.queued;
    if (_failures.containsKey(id)) return DownloadStatus.failed;
    return DownloadStatus.none;
  }

  /// 0..1 while downloading; null when the size is not known yet.
  double? progressOf(String id) {
    final value = _progress[id];
    return value == null || value < 0 ? null : value;
  }

  String? failureOf(String id) => _failures[id];

  /// Absolute path of a finished download, or null.
  String? pathFor(String id) {
    final entry = _entries[id];
    final dir = _directory;
    if (entry == null || dir == null) return null;
    return '${dir.path}${Platform.pathSeparator}${entry.fileName}';
  }

  String? artPathFor(String id) {
    final name = _entries[id]?.artFileName;
    final dir = _directory;
    if (name == null || dir == null) return null;
    return '${dir.path}${Platform.pathSeparator}$name';
  }

  /// Downloaded tracks, ready to show in an offline library.
  List<MusicTrack> get tracks => [
    for (final entry in _entries.values) trackWithArtwork(entry.track),
  ];

  /// Adds the offline artwork path so covers show with no connection.
  MusicTrack trackWithArtwork(MusicTrack track) {
    final art = artPathFor(track.id);
    if (art == null) return track;
    return MusicTrack.fromJson({...track.toJson(), 'localArtworkPath': art});
  }

  Future<void> load(String? encodedIndex) async {
    _directory = await directoryProvider();
    await _directory!.create(recursive: true);
    _entries.clear();
    if (encodedIndex != null && encodedIndex.isNotEmpty) {
      try {
        final list = jsonDecode(encodedIndex) as List<dynamic>;
        for (final item in list) {
          final entry = OfflineEntry.fromJson(
            Map<String, dynamic>.from(item as Map),
          );
          final file = File(
            '${_directory!.path}${Platform.pathSeparator}${entry.fileName}',
          );
          // Files can vanish if the OS cleans storage; forget them.
          if (await file.exists()) _entries[entry.track.id] = entry;
        }
      } catch (_) {
        // A corrupt index is rebuilt as the user downloads again.
      }
    }
    notifyListeners();
  }

  Future<void> _save() => persist(
    jsonEncode(_entries.values.map((entry) => entry.toJson()).toList()),
  );

  /// Queues a download. The future completes when this track finishes or
  /// fails (failures are recorded, not thrown).
  Future<void> download(MusicTrack track, NavidromeClient client) {
    if (track.isLocal || track.id.isEmpty || has(track.id)) {
      return Future.value();
    }
    final existing = _jobs[track.id];
    if (existing != null) return existing.done.future;
    _failures.remove(track.id);
    final job = _Job(track, client);
    _jobs[track.id] = job;
    _queue.add(job);
    notifyListeners();
    _pump();
    return job.done.future;
  }

  Future<void> downloadAll(
    Iterable<MusicTrack> tracks,
    NavidromeClient client,
  ) => Future.wait(tracks.map((track) => download(track, client)));

  void cancel(String id) {
    final job = _jobs[id];
    if (job == null) return;
    job.cancelled = true;
    if (_queue.remove(job)) {
      _jobs.remove(id);
      job.done.complete();
      notifyListeners();
    }
  }

  void cancelAll() {
    for (final id in _jobs.keys.toList()) {
      cancel(id);
    }
  }

  Future<void> remove(String id) async {
    cancel(id);
    final entry = _entries.remove(id);
    if (entry == null) return;
    await _deleteQuietly(entry.fileName);
    // Artwork is shared between tracks of an album; keep it while in use.
    final art = entry.artFileName;
    if (art != null && !_entries.values.any((e) => e.artFileName == art)) {
      await _deleteQuietly(art);
    }
    notifyListeners();
    await _save();
  }

  Future<void> removeAll() async {
    cancelAll();
    final names = _entries.values
        .expand((entry) => [entry.fileName, ?entry.artFileName])
        .toSet();
    _entries.clear();
    for (final name in names) {
      await _deleteQuietly(name);
    }
    notifyListeners();
    await _save();
  }

  Future<void> _deleteQuietly(String name) async {
    final dir = _directory;
    if (dir == null) return;
    try {
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  void _pump() {
    while (_active < maxConcurrent && _queue.isNotEmpty) {
      final job = _queue.removeAt(0);
      _active++;
      unawaited(
        _run(job).whenComplete(() {
          _active--;
          _jobs.remove(job.track.id);
          _progress.remove(job.track.id);
          if (!job.done.isCompleted) job.done.complete();
          notifyListeners();
          _pump();
        }),
      );
    }
  }

  static String safeName(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  static String extensionFor(MusicTrack track, http.StreamedResponse response) {
    String clean(String value) =>
        value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final suffix = track.suffix;
    if (suffix != null && clean(suffix).isNotEmpty) return clean(suffix);
    final disposition = response.headers['content-disposition'];
    final match = disposition == null
        ? null
        : RegExp(r'filename\*?=(?:UTF-8\x27\x27)?"?[^";]*\.([A-Za-z0-9]+)"?')
              .firstMatch(disposition);
    if (match != null) return clean(match.group(1)!);
    final type = response.headers['content-type']?.split(';').first.trim();
    return switch (type) {
      'audio/mpeg' => 'mp3',
      'audio/flac' || 'audio/x-flac' => 'flac',
      'audio/ogg' || 'application/ogg' => 'ogg',
      'audio/opus' => 'opus',
      'audio/mp4' || 'audio/x-m4a' || 'audio/aac' => 'm4a',
      'audio/wav' || 'audio/x-wav' => 'wav',
      _ => 'audio',
    };
  }

  Future<void> _run(_Job job) async {
    final track = job.track;
    final dir = _directory;
    if (dir == null) {
      _failures[track.id] = 'Downloads are not ready yet';
      return;
    }
    final base = safeName(track.id);
    final partFile = File('${dir.path}${Platform.pathSeparator}$base.part');
    IOSink? sink;
    try {
      _progress[track.id] = -1;
      notifyListeners();
      final request = http.Request('GET', job.client.downloadUri(track.id));
      final response = await _http
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Server returned HTTP ${response.statusCode}');
      }
      final type = response.headers['content-type'] ?? '';
      if (type.contains('json') || type.contains('xml')) {
        // Subsonic reports errors (bad id, no download permission) as a
        // normal-looking 200 response with a JSON/XML body.
        throw Exception('The server refused to download this track');
      }
      final total = response.contentLength ?? 0;
      var received = 0;
      sink = partFile.openWrite();
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        if (job.cancelled) throw const _Cancelled();
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          final next = received / total;
          if (next - (_progress[track.id] ?? 0) > .02) {
            _progress[track.id] = next;
            notifyListeners();
          }
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (received == 0) throw Exception('The downloaded file was empty');

      final fileName = '$base.${extensionFor(track, response)}';
      await partFile.rename('${dir.path}${Platform.pathSeparator}$fileName');
      final artFileName = await _downloadArtwork(track, job.client, dir);
      _entries[track.id] = OfflineEntry(
        track: track,
        fileName: fileName,
        bytes: received,
        artFileName: artFileName,
      );
      _failures.remove(track.id);
      await _save();
    } on _Cancelled {
      // The user cancelled; nothing to report.
    } catch (error) {
      _failures[track.id] = '$error'.replaceFirst('Exception: ', '');
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await partFile.exists()) await partFile.delete();
      } catch (_) {}
    }
  }

  Future<String?> _downloadArtwork(
    MusicTrack track,
    NavidromeClient client,
    Directory dir,
  ) async {
    final art = track.coverArt;
    final url = client.coverArtUrl(art);
    if (art == null || url == null) return null;
    final name = 'art_${safeName(art)}.jpg';
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    if (await file.exists()) return name;
    try {
      final response = await _http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 20));
      final type = response.headers['content-type'] ?? '';
      if (response.statusCode == 200 &&
          type.startsWith('image/') &&
          response.bodyBytes.isNotEmpty) {
        await file.writeAsBytes(response.bodyBytes);
        return name;
      }
    } catch (_) {
      // Artwork is a nicety; the audio is what matters.
    }
    return null;
  }

  @override
  void dispose() {
    cancelAll();
    _http.close();
    super.dispose();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
