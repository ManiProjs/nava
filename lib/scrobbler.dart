// lib/scrobbler.dart
//
// Decides when a play counts as a listen and keeps listens that could not be
// delivered (offline, server down) so they are sent later.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

enum ScrobbleSignal { none, submit, restart }

/// Counts real listening time (not seek jumps) for one track at a time.
///
/// A play is a listen once the track is longer than 30 seconds and the listener
/// has heard half of it or 4 minutes, whichever comes first — the same rule
/// Last.fm and ListenBrainz use.
class ScrobbleTracker {
  String? _id;
  int _durationSeconds = 0;
  DateTime? _startedAt;
  Duration _listened = Duration.zero;
  Duration? _lastPosition;
  bool _submitted = false;

  String? get trackId => _id;
  DateTime? get startedAt => _startedAt;
  bool get submitted => _submitted;

  void start(String id, int durationSeconds, DateTime startedAt) {
    _id = id;
    _durationSeconds = durationSeconds;
    _startedAt = startedAt;
    _listened = Duration.zero;
    _lastPosition = Duration.zero;
    _submitted = false;
  }

  void stop() {
    _id = null;
    _lastPosition = null;
  }

  Duration get _threshold {
    final half = Duration(milliseconds: _durationSeconds * 500);
    const cap = Duration(minutes: 4);
    return half < cap ? half : cap;
  }

  bool get eligible => _id != null && _durationSeconds > 30;

  /// Feed playback position ticks while the track is playing.
  ScrobbleSignal update(Duration position, {required DateTime now}) {
    if (_id == null) return ScrobbleSignal.none;
    final last = _lastPosition;
    _lastPosition = position;
    if (last == null) return ScrobbleSignal.none;

    final delta = position - last;
    // A repeat-one loop jumps from the end back to the start after a listen.
    if (_submitted &&
        _durationSeconds > 0 &&
        delta < Duration(seconds: -(_durationSeconds ~/ 2)) &&
        position < const Duration(seconds: 5)) {
      start(_id!, _durationSeconds, now);
      return ScrobbleSignal.restart;
    }
    // Only continuous playback counts; seeks and pauses are ignored.
    if (delta > Duration.zero && delta <= const Duration(seconds: 2)) {
      _listened += delta;
    }
    if (!_submitted && eligible && _listened >= _threshold) {
      _submitted = true;
      return ScrobbleSignal.submit;
    }
    return ScrobbleSignal.none;
  }
}

class PendingScrobble {
  const PendingScrobble(this.id, this.timeMillis);
  final String id;
  final int timeMillis;

  Map<String, dynamic> toJson() => {'id': id, 't': timeMillis};
  factory PendingScrobble.fromJson(Map<String, dynamic> json) =>
      PendingScrobble('${json['id']}', (json['t'] as num).toInt());
}

bool isTransientNetworkError(Object error) =>
    error is SocketException ||
    error is TimeoutException ||
    error is http.ClientException ||
    (error is Exception && error.toString().contains('HTTP 5'));

/// A durable list of listens waiting to be delivered.
class ScrobbleQueue {
  ScrobbleQueue({List<PendingScrobble>? initial, this.maxLength = 500})
    : _items = List.of(initial ?? const []);

  final int maxLength;
  final List<PendingScrobble> _items;
  bool _flushing = false;

  List<PendingScrobble> get items => List.unmodifiable(_items);
  int get length => _items.length;

  void add(PendingScrobble scrobble) {
    _items.add(scrobble);
    if (_items.length > maxLength) {
      _items.removeRange(0, _items.length - maxLength);
    }
  }

  /// Sends queued listens oldest-first. A network failure stops the flush and
  /// keeps the rest; a rejection from the server (for example a track that no
  /// longer exists) drops just that listen so it cannot block the queue.
  /// Returns how many were delivered.
  Future<int> flush(
    Future<void> Function(String id, DateTime time) submit,
  ) async {
    if (_flushing) return 0;
    _flushing = true;
    var delivered = 0;
    try {
      while (_items.isNotEmpty) {
        final next = _items.first;
        try {
          await submit(
            next.id,
            DateTime.fromMillisecondsSinceEpoch(next.timeMillis),
          );
          _items.removeAt(0);
          delivered++;
        } catch (error) {
          if (isTransientNetworkError(error)) break;
          _items.removeAt(0);
        }
      }
    } finally {
      _flushing = false;
    }
    return delivered;
  }

  String encode() => jsonEncode(_items.map((item) => item.toJson()).toList());

  static ScrobbleQueue decode(String? raw) {
    if (raw == null || raw.isEmpty) return ScrobbleQueue();
    try {
      return ScrobbleQueue(
        initial: (jsonDecode(raw) as List)
            .map(
              (item) => PendingScrobble.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList(),
      );
    } catch (_) {
      return ScrobbleQueue();
    }
  }
}
