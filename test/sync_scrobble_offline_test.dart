import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nava/navidrome_client.dart';
import 'package:nava/offline_store.dart';
import 'package:nava/scrobbler.dart';
import 'package:nava/server_sync.dart';

class FakeRemote implements SyncRemote {
  final Map<String, ({String id, List<String> ids})> playlists = {};
  Set<String> starred = {};
  int nextId = 1;
  final List<String> calls = [];

  @override
  Future<List<ServerPlaylist>> listPlaylists() async => [
    for (final entry in playlists.entries)
      ServerPlaylist(id: entry.value.id, name: entry.key),
  ];

  @override
  Future<List<String>> playlistTrackIds(String id) async =>
      playlists.values.firstWhere((p) => p.id == id).ids;

  @override
  Future<String> createPlaylist(String name, List<String> ids) async {
    calls.add('create $name');
    final id = 'p${nextId++}';
    playlists[name] = (id: id, ids: List.of(ids));
    return id;
  }

  @override
  Future<void> replacePlaylist(String id, List<String> ids) async {
    calls.add('replace $id');
    final name = playlists.entries.firstWhere((e) => e.value.id == id).key;
    playlists[name] = (id: id, ids: List.of(ids));
  }

  @override
  Future<void> deletePlaylist(String id) async {
    calls.add('delete $id');
    playlists.removeWhere((_, v) => v.id == id);
  }

  @override
  Future<Set<String>> starredIds() async => starred;
  @override
  Future<void> star(Iterable<String> ids) async => starred.addAll(ids);
  @override
  Future<void> unstar(Iterable<String> ids) async => starred.removeAll(ids);
}

Future<SyncOutcome> sync(
  FakeRemote remote,
  Map<String, List<String>> playlists,
  Set<String> favorites,
  SyncState state,
) => syncWithServer(
  remote: remote,
  localPlaylists: playlists,
  localFavorites: favorites,
  state: state,
  isLocalId: (id) => id.startsWith('local:'),
);

void setServerIds(FakeRemote remote, String name, List<String> ids) {
  remote.playlists[name] = (id: remote.playlists[name]!.id, ids: ids);
}

void main() {
  group('playlist sync', () {
    test('first sync pushes local playlists and pulls server ones', () async {
      final remote = FakeRemote()
        ..playlists['Road'] = (id: 'x', ids: ['r1', 'r2']);
      final out = await sync(
        remote,
        {
          'Gym': ['g1', 'local:file'],
        },
        {},
        const SyncState(),
      );
      expect(remote.playlists['Gym']!.ids, ['g1']); // local file not pushed
      expect(out.playlists['Road'], ['r1', 'r2']);
      expect(out.playlists['Gym'], ['g1', 'local:file']); // kept locally
    });

    test('server-only change is pulled, local-only change is pushed', () async {
      final remote = FakeRemote();
      var out = await sync(
        remote,
        {
          'A': ['1', '2'],
          'B': ['1'],
        },
        {},
        const SyncState(),
      );
      setServerIds(remote, 'A', ['1', '2', '3']);
      out = await sync(
        remote,
        {
          'A': ['1', '2'],
          'B': ['1', '9'],
        },
        {},
        out.state,
      );
      expect(out.playlists['A'], ['1', '2', '3']);
      expect(remote.playlists['B']!.ids, ['1', '9']);
    });

    test('changes on both sides are merged without losing either', () async {
      final remote = FakeRemote();
      var out = await sync(
        remote,
        {
          'A': ['1'],
        },
        {},
        const SyncState(),
      );
      setServerIds(remote, 'A', ['1', 's']);
      out = await sync(
        remote,
        {
          'A': ['1', 'l'],
        },
        {},
        out.state,
      );
      expect(out.playlists['A'], ['1', 's', 'l']);
      expect(remote.playlists['A']!.ids, ['1', 's', 'l']);
    });

    test('deleting locally deletes on the server, and vice versa', () async {
      final remote = FakeRemote();
      var out = await sync(
        remote,
        {
          'A': ['1'],
          'B': ['2'],
        },
        {},
        const SyncState(),
      );
      // A deleted locally, B deleted on the server.
      remote.playlists.remove('B');
      out = await sync(
        remote,
        {
          'B': ['2'],
        },
        {},
        out.state,
      );
      expect(remote.playlists.containsKey('A'), isFalse);
      expect(out.playlists.containsKey('B'), isFalse);
      expect(out.state.playlistSnapshot, isEmpty);
    });

    test('a delete never discards edits made on the other side', () async {
      final remote = FakeRemote();
      var out = await sync(
        remote,
        {
          'A': ['1'],
        },
        {},
        const SyncState(),
      );
      setServerIds(remote, 'A', ['1', 'new']);
      out = await sync(remote, {}, {}, out.state);
      expect(out.playlists['A'], ['1', 'new']);
    });

    test('a second sync with no changes does nothing', () async {
      final remote = FakeRemote();
      final out = await sync(
        remote,
        {
          'A': ['1'],
        },
        {'1'},
        const SyncState(),
      );
      remote.calls.clear();
      await sync(remote, out.playlists, out.favorites, out.state);
      expect(remote.calls, isEmpty);
    });

    test('state survives encode/decode', () {
      const state = SyncState(
        playlistIds: {'A': 'p1'},
        playlistSnapshot: {
          'A': ['1', '2'],
        },
        favoriteSnapshot: {'x'},
      );
      final back = SyncState.decode(state.encode());
      expect(back.playlistIds, state.playlistIds);
      expect(back.playlistSnapshot, state.playlistSnapshot);
      expect(back.favoriteSnapshot, state.favoriteSnapshot);
      expect(SyncState.decode('garbage').playlistIds, isEmpty);
    });
  });

  group('favorites sync', () {
    test('first sync unions both sides', () async {
      final remote = FakeRemote()..starred = {'s'};
      final out = await sync(remote, {}, {'l', 'local:f'}, const SyncState());
      expect(remote.starred, {'s', 'l'});
      expect(out.favorites, {'s', 'l', 'local:f'});
    });

    test('removals propagate in both directions', () async {
      final remote = FakeRemote();
      var out = await sync(remote, {}, {'a', 'b', 'c'}, const SyncState());
      remote.starred.remove('b'); // un-starred on another device
      // c is un-favorited here.
      out = await sync(remote, {}, {'a', 'b'}, out.state);
      expect(remote.starred, {'a'});
      expect(out.favorites, {'a'});
    });
  });

  group('scrobble tracker', () {
    final t0 = DateTime(2026, 1, 1);

    ScrobbleSignal play(ScrobbleTracker tracker, int seconds) {
      var signal = ScrobbleSignal.none;
      for (var ms = 500; ms <= seconds * 1000; ms += 500) {
        final s = tracker.update(Duration(milliseconds: ms), now: t0);
        if (s != ScrobbleSignal.none) signal = s;
      }
      return signal;
    }

    test('submits once after half the track', () {
      expect(
        play(ScrobbleTracker()..start('a', 200, t0), 90),
        ScrobbleSignal.none,
      );
      final tracker = ScrobbleTracker()..start('a', 200, t0);
      expect(play(tracker, 101), ScrobbleSignal.submit);
      expect(tracker.submitted, isTrue);
      // Keeps counting but never submits twice.
      expect(
        tracker.update(const Duration(seconds: 102), now: t0),
        ScrobbleSignal.none,
      );
    });

    test('long tracks count at four minutes', () {
      expect(
        play(ScrobbleTracker()..start('a', 1200, t0), 239),
        ScrobbleSignal.none,
      );
      expect(
        play(ScrobbleTracker()..start('a', 1200, t0), 241),
        ScrobbleSignal.submit,
      );
    });

    test('short tracks and seeking never count', () {
      expect(
        play(ScrobbleTracker()..start('a', 25, t0), 25),
        ScrobbleSignal.none,
      );
      final tracker = ScrobbleTracker()..start('a', 200, t0);
      tracker.update(const Duration(seconds: 1), now: t0);
      expect(
        tracker.update(const Duration(seconds: 150), now: t0),
        ScrobbleSignal.none,
      );
    });

    test('repeat-one restarts a play after it was submitted', () {
      final tracker = ScrobbleTracker()..start('a', 60, t0);
      expect(play(tracker, 31), ScrobbleSignal.submit);
      expect(
        tracker.update(const Duration(seconds: 59), now: t0),
        ScrobbleSignal.none,
      );
      expect(
        tracker.update(const Duration(seconds: 1), now: t0),
        ScrobbleSignal.restart,
      );
      expect(tracker.submitted, isFalse);
    });
  });

  group('scrobble queue', () {
    test('keeps listens on network failure and delivers them later', () async {
      final queue = ScrobbleQueue()
        ..add(const PendingScrobble('a', 1))
        ..add(const PendingScrobble('b', 2));
      var online = false;
      final sent = <String>[];
      Future<void> submit(String id, DateTime time) async {
        if (!online) throw const SocketException('offline');
        sent.add(id);
      }

      expect(await queue.flush(submit), 0);
      expect(queue.length, 2);
      online = true;
      expect(await queue.flush(submit), 2);
      expect(sent, ['a', 'b']);
      expect(queue.length, 0);
    });

    test(
      'a rejected listen is dropped instead of blocking the queue',
      () async {
        final queue = ScrobbleQueue()
          ..add(const PendingScrobble('gone', 1))
          ..add(const PendingScrobble('ok', 2));
        final sent = <String>[];
        await queue.flush((id, time) async {
          if (id == 'gone') throw Exception('Data not found');
          sent.add(id);
        });
        expect(sent, ['ok']);
        expect(queue.length, 0);
      },
    );

    test('persists and caps length', () {
      final queue = ScrobbleQueue(maxLength: 2)
        ..add(const PendingScrobble('a', 1))
        ..add(const PendingScrobble('b', 2))
        ..add(const PendingScrobble('c', 3));
      expect(queue.items.map((e) => e.id), ['b', 'c']);
      expect(ScrobbleQueue.decode(queue.encode()).length, 2);
      expect(ScrobbleQueue.decode('nonsense').length, 0);
    });
  });

  group('offline store', () {
    late Directory dir;
    String? savedIndex;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('nava_offline_test');
      savedIndex = null;
    });
    tearDown(() async => dir.delete(recursive: true));

    NavidromeClient client() => NavidromeClient(
      const NavidromeCredentials(
        baseUrl: 'http://example.test',
        username: 'u',
        password: 'p',
      ),
    );

    OfflineStore store(http.Client httpClient) => OfflineStore(
      directoryProvider: () async => dir,
      persist: (index) async => savedIndex = index,
      httpClient: httpClient,
    );

    test('downloads, indexes, reloads and removes a track', () async {
      final mock = MockClient((request) async {
        if (request.url.path.endsWith('download.view')) {
          return http.Response.bytes(
            List.filled(2048, 7),
            200,
            headers: {'content-type': 'audio/flac'},
          );
        }
        return http.Response.bytes(
          [1, 2, 3],
          200,
          headers: {'content-type': 'image/jpeg'},
        );
      });
      final offline = store(mock);
      await offline.load(null);
      const track = MusicTrack(
        id: 'song/1',
        title: 'T',
        coverArt: 'al-1',
        suffix: 'flac',
      );

      await offline.download(track, client());
      expect(offline.statusOf('song/1'), DownloadStatus.downloaded);
      expect(offline.totalBytes, 2048);
      expect(File(offline.pathFor('song/1')!).existsSync(), isTrue);
      expect(offline.pathFor('song/1'), endsWith('.flac'));
      expect(offline.tracks.single.localArtworkPath, isNotNull);
      expect(offline.tracks.single.isLocal, isFalse);

      final reloaded = store(mock);
      await reloaded.load(savedIndex);
      expect(reloaded.has('song/1'), isTrue);

      await offline.remove('song/1');
      expect(offline.has('song/1'), isFalse);
      expect(dir.listSync().whereType<File>(), isEmpty);
    });

    test(
      'server errors are recorded, not thrown, and leave no files',
      () async {
        final offline = store(
          MockClient(
            (_) async => http.Response(
              '{"subsonic-response":{}}',
              200,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );
        await offline.load(null);
        await offline.download(const MusicTrack(id: 'x', title: 'X'), client());
        expect(offline.statusOf('x'), DownloadStatus.failed);
        expect(offline.failureOf('x'), contains('refused'));
        expect(dir.listSync(), isEmpty);
      },
    );

    test('files deleted behind our back are forgotten on load', () async {
      final mock = MockClient(
        (_) async => http.Response.bytes(
          [1, 2, 3],
          200,
          headers: {'content-type': 'audio/mpeg'},
        ),
      );
      final offline = store(mock);
      await offline.load(null);
      await offline.download(const MusicTrack(id: 'm', title: 'M'), client());
      File(offline.pathFor('m')!).deleteSync();
      final reloaded = store(mock);
      await reloaded.load(savedIndex);
      expect(reloaded.count, 0);
    });
  });
}
