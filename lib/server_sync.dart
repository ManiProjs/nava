// lib/server_sync.dart
//
// Two-way sync of playlists and favorites with a Navidrome server.
//
// The server and the device can both change between syncs, so every merge is
// three-way: the last synced "snapshot" tells us which side actually changed.
// Local-only tracks (files imported from this device) never leave the device;
// they are kept in local playlists and favorites but never pushed.
import 'dart:convert';

import 'navidrome_client.dart';

/// The server operations sync needs. Abstracted so the merge logic can be
/// tested without a network.
abstract class SyncRemote {
  Future<List<ServerPlaylist>> listPlaylists();
  Future<List<String>> playlistTrackIds(String playlistId);
  Future<String> createPlaylist(String name, List<String> ids);
  Future<void> replacePlaylist(String playlistId, List<String> ids);
  Future<void> deletePlaylist(String playlistId);
  Future<Set<String>> starredIds();
  Future<void> star(Iterable<String> ids);
  Future<void> unstar(Iterable<String> ids);
}

class NavidromeSyncRemote implements SyncRemote {
  NavidromeSyncRemote(this.client);
  final NavidromeClient client;

  @override
  Future<List<ServerPlaylist>> listPlaylists() async {
    final username = client.credentials.username.toLowerCase();
    // Only playlists this account owns can be edited; shared ones are skipped.
    return (await client.getServerPlaylists())
        .where((p) => p.owner == null || p.owner!.toLowerCase() == username)
        .toList();
  }

  @override
  Future<List<String>> playlistTrackIds(String playlistId) =>
      client.getServerPlaylistTrackIds(playlistId);

  @override
  Future<String> createPlaylist(String name, List<String> ids) =>
      client.createServerPlaylist(name, ids);

  @override
  Future<void> replacePlaylist(String playlistId, List<String> ids) =>
      client.replaceServerPlaylist(playlistId, ids);

  @override
  Future<void> deletePlaylist(String playlistId) =>
      client.deleteServerPlaylist(playlistId);

  @override
  Future<Set<String>> starredIds() => client.getStarredIds();

  @override
  Future<void> star(Iterable<String> ids) => client.star(ids);

  @override
  Future<void> unstar(Iterable<String> ids) => client.unstar(ids);
}

/// What the last successful sync looked like. Persisted between runs.
class SyncState {
  const SyncState({
    this.playlistIds = const {},
    this.playlistSnapshot = const {},
    this.favoriteSnapshot = const {},
  });

  /// Playlist name → server playlist id.
  final Map<String, String> playlistIds;

  /// Playlist name → server-track ids at the last sync.
  final Map<String, List<String>> playlistSnapshot;
  final Set<String> favoriteSnapshot;

  SyncState copyWith({
    Map<String, String>? playlistIds,
    Map<String, List<String>>? playlistSnapshot,
    Set<String>? favoriteSnapshot,
  }) => SyncState(
    playlistIds: playlistIds ?? this.playlistIds,
    playlistSnapshot: playlistSnapshot ?? this.playlistSnapshot,
    favoriteSnapshot: favoriteSnapshot ?? this.favoriteSnapshot,
  );

  String encode() => jsonEncode({
    'playlistIds': playlistIds,
    'playlistSnapshot': playlistSnapshot,
    'favoriteSnapshot': favoriteSnapshot.toList(),
  });

  static SyncState decode(String? raw) {
    if (raw == null || raw.isEmpty) return const SyncState();
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return SyncState(
        playlistIds: Map<String, String>.from(
          json['playlistIds'] as Map? ?? const {},
        ),
        playlistSnapshot: (json['playlistSnapshot'] as Map? ?? const {}).map(
          (key, value) =>
              MapEntry('$key', List<String>.from(value as List<dynamic>)),
        ),
        favoriteSnapshot: Set<String>.from(
          json['favoriteSnapshot'] as List? ?? const [],
        ),
      );
    } catch (_) {
      return const SyncState();
    }
  }
}

class SyncOutcome {
  const SyncOutcome({
    required this.playlists,
    required this.favorites,
    required this.state,
    this.errors = const [],
    this.pushed = 0,
    this.pulled = 0,
  });

  final Map<String, List<String>> playlists;
  final Set<String> favorites;
  final SyncState state;
  final List<String> errors;
  final int pushed;
  final int pulled;
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Server ids first, then anything only the device added, without repeats.
List<String> _union(List<String> first, List<String> second) {
  final seen = <String>{};
  return [
    for (final id in [...first, ...second])
      if (seen.add(id)) id,
  ];
}

class FavoritePlan {
  const FavoritePlan({
    required this.merged,
    required this.toStar,
    required this.toUnstar,
  });
  final Set<String> merged;
  final Set<String> toStar;
  final Set<String> toUnstar;
}

/// Three-way favorites merge. Anything in [snapshot] that is missing from
/// either side was deliberately removed there; anything new is kept.
FavoritePlan planFavoriteSync({
  required Set<String> local,
  required Set<String> server,
  required Set<String> snapshot,
  required bool Function(String id) isLocalId,
}) {
  final localServerIds = local.where((id) => !isLocalId(id)).toSet();
  final merged = <String>{
    for (final id in {...localServerIds, ...server})
      if (!(snapshot.contains(id) &&
          (!localServerIds.contains(id) || !server.contains(id))))
        id,
  };
  return FavoritePlan(
    merged: merged,
    toStar: merged.difference(server),
    toUnstar: server.difference(merged),
  );
}

/// Runs a complete playlist + favorites sync and returns the merged result.
/// Failures on one playlist never abort the others; they are reported in
/// [SyncOutcome.errors] and that playlist is retried next time.
Future<SyncOutcome> syncWithServer({
  required SyncRemote remote,
  required Map<String, List<String>> localPlaylists,
  required Set<String> localFavorites,
  required SyncState state,
  required bool Function(String id) isLocalId,
  bool syncPlaylists = true,
  bool syncFavorites = true,
}) async {
  final errors = <String>[];
  var pushed = 0;
  var pulled = 0;

  final playlists = <String, List<String>>{
    for (final entry in localPlaylists.entries)
      entry.key: List<String>.of(entry.value),
  };
  var ids = Map<String, String>.of(state.playlistIds);
  var snapshot = Map<String, List<String>>.of(state.playlistSnapshot);

  if (syncPlaylists) {
    final serverPlaylists = await remote.listPlaylists();
    final byName = <String, ServerPlaylist>{};
    for (final playlist in serverPlaylists) {
      byName.putIfAbsent(playlist.name, () => playlist);
    }
    final serverTracks = <String, List<String>>{};
    final fetchFailures = <String>{};
    final pending = byName.values.toList();
    for (var start = 0; start < pending.length; start += 6) {
      await Future.wait(
        pending.skip(start).take(6).map((playlist) async {
          try {
            serverTracks[playlist.name] = await remote.playlistTrackIds(
              playlist.id,
            );
          } catch (error) {
            fetchFailures.add(playlist.name);
            errors.add('Could not read “${playlist.name}”: $error');
          }
        }),
      );
    }

    final names = {...localPlaylists.keys, ...byName.keys, ...snapshot.keys};
    for (final name in names) {
      if (fetchFailures.contains(name)) continue;
      final local = localPlaylists[name];
      final localServerIds = local?.where((id) => !isLocalId(id)).toList();
      final localOnly = local?.where(isLocalId).toList() ?? const <String>[];
      final remoteList = byName[name];
      final server = serverTracks[name];
      final base = snapshot[name];

      try {
        if (local != null && remoteList != null && server != null) {
          late List<String> result;
          if (base == null) {
            result = _union(server, localServerIds!);
          } else {
            final localChanged = !_sameList(localServerIds!, base);
            final serverChanged = !_sameList(server, base);
            if (!localChanged && !serverChanged) {
              result = server;
            } else if (!localChanged) {
              result = server;
            } else if (!serverChanged) {
              result = localServerIds;
            } else {
              result = _union(server, localServerIds);
            }
          }
          if (!_sameList(result, server)) {
            await remote.replacePlaylist(remoteList.id, result);
            pushed++;
          }
          if (!_sameList(result, localServerIds)) pulled++;
          playlists[name] = [...result, ...localOnly];
          ids[name] = remoteList.id;
          snapshot[name] = result;
        } else if (local != null && remoteList == null) {
          if (base != null && _sameList(localServerIds!, base)) {
            // Deleted on the server and untouched here: honour the delete.
            playlists.remove(name);
            ids.remove(name);
            snapshot.remove(name);
            pulled++;
          } else {
            final id = await remote.createPlaylist(name, localServerIds!);
            ids[name] = id;
            snapshot[name] = List<String>.of(localServerIds);
            pushed++;
          }
        } else if (local == null && remoteList != null && server != null) {
          if (base != null && _sameList(server, base)) {
            // Deleted here and untouched on the server: delete it there too.
            await remote.deletePlaylist(remoteList.id);
            ids.remove(name);
            snapshot.remove(name);
            pushed++;
          } else {
            playlists[name] = List<String>.of(server);
            ids[name] = remoteList.id;
            snapshot[name] = List<String>.of(server);
            pulled++;
          }
        } else if (local == null && remoteList == null) {
          ids.remove(name);
          snapshot.remove(name);
        }
      } catch (error) {
        errors.add('Could not sync “$name”: $error');
      }
    }
  }

  var favorites = Set<String>.of(localFavorites);
  var favoriteSnapshot = state.favoriteSnapshot;
  if (syncFavorites) {
    try {
      final server = await remote.starredIds();
      final plan = planFavoriteSync(
        local: localFavorites,
        server: server,
        snapshot: state.favoriteSnapshot,
        isLocalId: isLocalId,
      );
      if (plan.toStar.isNotEmpty) await remote.star(plan.toStar);
      if (plan.toUnstar.isNotEmpty) await remote.unstar(plan.toUnstar);
      pushed += plan.toStar.length + plan.toUnstar.length;
      pulled += plan.merged.difference(localFavorites).length;
      favorites = {...plan.merged, ...localFavorites.where(isLocalId)};
      favoriteSnapshot = plan.merged;
    } catch (error) {
      errors.add('Could not sync favorites: $error');
    }
  }

  return SyncOutcome(
    playlists: playlists,
    favorites: favorites,
    state: SyncState(
      playlistIds: ids,
      playlistSnapshot: snapshot,
      favoriteSnapshot: favoriteSnapshot,
    ),
    errors: errors,
    pushed: pushed,
    pulled: pulled,
  );
}
