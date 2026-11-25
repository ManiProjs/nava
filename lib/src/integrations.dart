part of '../main.dart';

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

/// Offline downloads, server sync, scrobbling and desktop keyboard control.
extension _IntegrationMethods on _HomeScreenState {
  // ---------------------------------------------------------------- settings

  Future<void> _loadIntegrationSettings(SharedPreferences preferences) async {
    _syncEnabled = preferences.getBool(_syncEnabledKey) ?? true;
    _scrobbleEnabled = preferences.getBool(_scrobbleEnabledKey) ?? true;
    _syncState = SyncState.decode(preferences.getString(_syncStateKey));
    _scrobbleQueue = ScrobbleQueue.decode(
      preferences.getString(_scrobbleQueueKey),
    );
    try {
      await _offline.load(preferences.getString(_offlineIndexKey));
    } catch (error) {
      debugPrint('Nava offline storage unavailable: $error');
    }
  }

  Future<void> _setBoolPreference(String key, bool value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(key, value);
  }

  // ---------------------------------------------------------------- connect

  /// Called once the library loads from the server (so the server is
  /// reachable): deliver queued listens and reconcile playlists/favorites.
  Future<void> _onServerReachable() async {
    _offlineMode = false;
    unawaited(_flushScrobbles());
    _scheduleSync(delay: const Duration(milliseconds: 300));
  }

  // ------------------------------------------------------------------ sync

  void _scheduleSync({Duration delay = const Duration(seconds: 2)}) {
    if (!_syncEnabled || _client == null) return;
    _syncTimer?.cancel();
    _syncTimer = Timer(delay, () => unawaited(_runSync()));
  }

  String _playlistsFingerprint() =>
      jsonEncode([_playlists, (_favorites.toList()..sort())]);

  Future<void> _runSync({bool manual = false}) async {
    final client = _client;
    if (client == null || (!_syncEnabled && !manual) || _syncing) return;
    _syncing = true;
    _updateState(() => _syncStatus = 'Syncing…');
    final before = _playlistsFingerprint();
    final localIds = _localTracks.map((track) => track.id).toSet();
    try {
      final outcome = await syncWithServer(
        remote: NavidromeSyncRemote(client),
        localPlaylists: _playlists,
        localFavorites: _favorites,
        state: _syncState,
        isLocalId: localIds.contains,
      );
      if (!mounted) return;
      if (_playlistsFingerprint() != before) {
        // The user edited while we were syncing. Applying the merge would
        // overwrite that edit, so drop it; the next pass merges both sides.
        _updateState(() => _syncStatus = 'Syncing again…');
        _scheduleSync(delay: const Duration(seconds: 1));
        return;
      }
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_syncStateKey, outcome.state.encode());
      final changed =
          jsonEncode(outcome.playlists) != jsonEncode(_playlists) ||
          outcome.favorites.length != _favorites.length ||
          !outcome.favorites.containsAll(_favorites);
      if (changed) {
        await preferences.setString(
          _playlistsKey,
          jsonEncode(outcome.playlists),
        );
        await preferences.setStringList(
          _favoritesKey,
          outcome.favorites.toList(),
        );
      }
      _syncState = outcome.state;
      _updateState(() {
        if (changed) {
          _playlists = outcome.playlists;
          _favorites = outcome.favorites;
          _cachedFavoriteTracks = null;
          _flowQueueDirty = true;
          _invalidateRecommendationCaches();
        }
        _syncStatus = outcome.errors.isEmpty
            ? 'Synced just now'
            : 'Synced with ${outcome.errors.length} problem(s): ${outcome.errors.first}';
      });
    } catch (error) {
      if (!mounted) return;
      _updateState(
        () => _syncStatus = isTransientNetworkError(error)
            ? 'Server unreachable. Will retry when you are back online.'
            : 'Sync failed: ${'$error'.replaceFirst('Exception: ', '')}',
      );
    } finally {
      _syncing = false;
    }
  }

  // ------------------------------------------------------------- scrobbling

  void _scrobbleStart(MusicTrack track) {
    final client = _client;
    _scrobbleTracker.stop();
    if (!_scrobbleEnabled || client == null || track.isLocal) return;
    final seconds = track.duration > 0
        ? track.duration
        : (_player.duration?.inSeconds ?? 0);
    _scrobbleTracker.start(track.id, seconds, DateTime.now());
    // "Now playing" is best effort; failures are not worth surfacing.
    unawaited(client.scrobble(track.id, submission: false).catchError((_) {}));
  }

  void _scrobbleTick(Duration position) {
    if (!_scrobbleEnabled || !_player.playing) return;
    final id = _scrobbleTracker.trackId;
    if (id == null) return;
    final startedBefore = _scrobbleTracker.startedAt;
    final signal = _scrobbleTracker.update(position, now: DateTime.now());
    if (signal == ScrobbleSignal.submit) {
      _scrobbleQueue.add(
        PendingScrobble(
          id,
          (startedBefore ?? DateTime.now()).millisecondsSinceEpoch,
        ),
      );
      unawaited(_flushScrobbles());
    } else if (signal == ScrobbleSignal.restart) {
      _scrobbleStartAgain(id);
    }
  }

  void _scrobbleStartAgain(String id) {
    final client = _client;
    if (client == null) return;
    unawaited(client.scrobble(id, submission: false).catchError((_) {}));
  }

  Future<void> _flushScrobbles() async {
    final client = _client;
    final preferences = await SharedPreferences.getInstance();
    // Persist first so a crash right after the listen does not lose it.
    await preferences.setString(_scrobbleQueueKey, _scrobbleQueue.encode());
    if (client == null || _scrobbleQueue.length == 0) return;
    await _scrobbleQueue.flush(
      (id, time) => client.scrobble(id, time: time, submission: true),
    );
    await preferences.setString(_scrobbleQueueKey, _scrobbleQueue.encode());
  }

  // -------------------------------------------------------------- downloads

  Future<void> _saveOfflineIndex(String encoded) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_offlineIndexKey, encoded);
  }

  void _downloadTracks(List<MusicTrack> tracks, {String? label}) {
    final client = _client;
    final messenger = ScaffoldMessenger.of(context);
    if (client == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Connect to a server to download.')),
      );
      return;
    }
    final fresh = tracks
        .where((track) => !track.isLocal && !_offline.has(track.id))
        .toList();
    if (fresh.isEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            tracks.isEmpty
                ? 'Nothing to download.'
                : 'Already available offline.',
          ),
        ),
      );
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          fresh.length == 1
              ? 'Downloading “${fresh.first.title}”'
              : 'Downloading ${fresh.length} tracks${label == null ? '' : ' from $label'}',
        ),
      ),
    );
    unawaited(
      _offline.downloadAll(fresh, client).then((_) {
        if (!mounted) return;
        final failed = fresh
            .where((t) => _offline.statusOf(t.id) == DownloadStatus.failed)
            .toList();
        if (failed.isEmpty) return;
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              failed.length == 1
                  ? 'Could not download “${failed.first.title}”: ${_offline.failureOf(failed.first.id)}'
                  : '${failed.length} downloads failed: ${_offline.failureOf(failed.first.id)}',
            ),
          ),
        );
      }),
    );
  }

  Future<void> _removeDownloads(List<MusicTrack> tracks) async {
    for (final track in tracks) {
      await _offline.remove(track.id);
    }
  }

  /// Small status glyph shown beside a track's duration.
  Widget _downloadBadge(MusicTrack track) {
    switch (_offline.statusOf(track.id)) {
      case DownloadStatus.downloaded:
        return Tooltip(
          message: 'Available offline',
          child: Icon(Icons.download_done_rounded, color: C.lime, size: 15),
        );
      case DownloadStatus.downloading:
        return SizedBox(
          width: 13,
          height: 13,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            value: _offline.progressOf(track.id),
            color: C.lime,
          ),
        );
      case DownloadStatus.queued:
        return Icon(Icons.schedule_rounded, color: C.muted, size: 14);
      case DownloadStatus.failed:
        return Tooltip(
          message: _offline.failureOf(track.id) ?? 'Download failed',
          child: Icon(Icons.error_outline_rounded, color: C.danger, size: 15),
        );
      case DownloadStatus.none:
        return const SizedBox.shrink();
    }
  }

  Widget _downloadMenuTile(MusicTrack track) {
    if (track.isLocal) return const SizedBox.shrink();
    final status = _offline.statusOf(track.id);
    final downloaded = status == DownloadStatus.downloaded;
    final active =
        status == DownloadStatus.queued || status == DownloadStatus.downloading;
    return ListTile(
      leading: Icon(
        downloaded
            ? Icons.delete_outline_rounded
            : active
            ? Icons.close_rounded
            : Icons.download_rounded,
      ),
      title: Text(
        downloaded
            ? 'Remove download'
            : active
            ? 'Cancel download'
            : 'Download for offline',
      ),
      onTap: () {
        Navigator.pop(context);
        if (downloaded) {
          unawaited(_offline.remove(track.id));
        } else if (active) {
          _offline.cancel(track.id);
        } else {
          _downloadTracks([track]);
        }
      },
    );
  }

  /// Download/remove button for a list of tracks (album, artist, playlist).
  Widget _downloadCollectionButton(List<MusicTrack> tracks, {String? label}) {
    return ListenableBuilder(
      listenable: _offline,
      builder: (context, _) {
        final remote = tracks.where((t) => !t.isLocal).toList();
        final missing = remote.where((t) => !_offline.has(t.id)).length;
        final busy = remote.any(
          (t) =>
              _offline.statusOf(t.id) == DownloadStatus.queued ||
              _offline.statusOf(t.id) == DownloadStatus.downloading,
        );
        if (remote.isEmpty) return const SizedBox.shrink();
        if (busy) {
          return OutlinedButton.icon(
            onPressed: () {
              for (final track in remote) {
                _offline.cancel(track.id);
              }
            },
            icon: const Icon(Icons.close_rounded),
            label: const Text('Cancel download'),
          );
        }
        if (missing == 0) {
          return OutlinedButton.icon(
            onPressed: () => unawaited(_removeDownloads(remote)),
            icon: const Icon(Icons.download_done_rounded),
            label: const Text('Downloaded'),
          );
        }
        return OutlinedButton.icon(
          onPressed: () => _downloadTracks(remote, label: label),
          icon: const Icon(Icons.download_rounded),
          label: Text(
            missing == remote.length ? 'Download' : 'Download $missing more',
          ),
        );
      },
    );
  }

  // --------------------------------------------------------- settings panel

  Widget _syncSwitch({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: value,
      activeThumbColor: C.black,
      activeTrackColor: C.lime,
      inactiveThumbColor: C.muted,
      inactiveTrackColor: C.surface2,
      title: Text(
        title,
        style: TextStyle(fontFamily: 'DMSansMedium', fontSize: 12),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: C.muted, fontSize: 10, height: 1.5),
      ),
      onChanged: onChanged,
    );
  }

  List<Widget> _offlineAndSyncSettings({required bool isDesktop}) {
    return [
      _settingsSection('DOWNLOADS'),
      ListenableBuilder(
        listenable: _offline,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.download_done_rounded, color: C.muted),
              title: Text(
                _offline.count == 0
                    ? 'No downloads yet'
                    : '${_offline.count} ${_offline.count == 1 ? 'track' : 'tracks'} offline',
                style: TextStyle(fontSize: 12),
              ),
              subtitle: Text(
                _offline.pendingCount > 0
                    ? '${_offline.pendingCount} downloading · ${_formatBytes(_offline.totalBytes)} used'
                    : _offline.count == 0
                    ? 'Use a track’s menu, or the Download button on an album, artist or playlist.'
                    : '${_formatBytes(_offline.totalBytes)} used on this device',
                style: TextStyle(color: C.muted, fontSize: 10, height: 1.5),
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _client == null
                      ? null
                      : () => _downloadTracks(
                          _tracks
                              .where((t) => _favorites.contains(t.id))
                              .toList(),
                          label: 'favorites',
                        ),
                  icon: const Icon(Icons.favorite_border_rounded, size: 16),
                  label: const Text('Download favorites'),
                ),
                if (_offline.pendingCount > 0)
                  OutlinedButton(
                    onPressed: _offline.cancelAll,
                    child: const Text('Cancel all'),
                  ),
                if (_offline.count > 0)
                  OutlinedButton(
                    onPressed: _confirmRemoveAllDownloads,
                    child: Text(
                      'Remove all',
                      style: TextStyle(color: C.danger),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      _settingsSection('SERVER SYNC'),
      _syncSwitch(
        title: 'Sync playlists and favorites',
        subtitle: 'Keep playlists and favorites in step with your Navidrome account across devices. Local files stay on this device.',
        value: _syncEnabled,
        onChanged: (value) {
          _updateState(() => _syncEnabled = value);
          unawaited(_setBoolPreference(_syncEnabledKey, value));
          if (value) _scheduleSync(delay: const Duration(milliseconds: 200));
        },
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Sync now', style: TextStyle(fontSize: 12)),
        subtitle: Text(
          _client == null
              ? 'Connect to a server to sync.'
              : _syncStatus.isEmpty
              ? 'Not synced yet.'
              : _syncStatus,
          style: TextStyle(color: C.muted, fontSize: 10, height: 1.5),
        ),
        trailing: _syncing
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(Icons.sync_rounded, color: C.muted),
        onTap: _client == null || _syncing
            ? null
            : () => unawaited(_runSync(manual: true)),
      ),
      _syncSwitch(
        title: 'Scrobble listens',
        subtitle: _scrobbleQueue.length > 0
            ? 'Send plays to Navidrome (and any Last.fm or ListenBrainz linked to it). ${_scrobbleQueue.length} waiting to send.'
            : 'Send plays to Navidrome (and any Last.fm or ListenBrainz linked to it) once you have heard half a track.',
        value: _scrobbleEnabled,
        onChanged: (value) {
          _updateState(() => _scrobbleEnabled = value);
          unawaited(_setBoolPreference(_scrobbleEnabledKey, value));
          if (!value) _scrobbleTracker.stop();
        },
      ),
      if (isDesktop) ...[
        _settingsSection('KEYBOARD'),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.keyboard_alt_outlined, color: C.muted),
          title: const Text(
            'Keyboard shortcuts',
            style: TextStyle(fontSize: 12),
          ),
          subtitle: Text(
            'Space, arrows, media keys and more.',
            style: TextStyle(color: C.muted, fontSize: 10),
          ),
          trailing: Icon(Icons.chevron_right_rounded, color: C.muted),
          onTap: _showShortcutsDialog,
        ),
      ],
    ];
  }

  Future<void> _confirmRemoveAllDownloads() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: C.surface,
        title: const Text('Remove all downloads?'),
        content: Text(
          'This frees ${_formatBytes(_offline.totalBytes)}. Your server library is not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _offline.removeAll();
  }

  // ---------------------------------------------------------- desktop keys

  static const _shortcutHelp = <(String, String)>[
    ('Space / Media play-pause', 'Play or pause'),
    ('← / →', 'Seek 5 seconds (hold Shift for 15)'),
    ('Ctrl/⌘ + ← / →', 'Previous / next track'),
    ('Media next / previous', 'Next / previous track'),
    ('L', 'Like or unlike the current track'),
    ('S', 'Toggle shuffle'),
    ('R', 'Cycle repeat mode'),
    ('/  or  Ctrl/⌘ + F', 'Go to search'),
    ('Ctrl/⌘ + ,', 'Open settings'),
    ('Esc', 'Close the player, Flow or settings'),
    ('?', 'Show this list'),
  ];

  void _showShortcutsDialog() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: C.surface,
        title: const Text('Keyboard shortcuts'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (keys, action) in _shortcutHelp)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 5,
                        child: Text(
                          keys,
                          style: TextStyle(
                            fontFamily: 'DMSansBold',
                            fontSize: 12,
                            color: C.lime,
                          ),
                        ),
                      ),
                      Expanded(
                        flex: 6,
                        child: Text(
                          action,
                          style: TextStyle(fontSize: 12, color: C.muted),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  bool _typingInTextField() {
    final context = FocusManager.instance.primaryFocus?.context;
    return context?.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _seekBy(Duration delta) {
    final duration = _player.duration;
    if (_current == null || duration == null) return;
    var target = _player.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > duration) target = duration;
    unawaited(_player.seek(target));
  }

  KeyEventResult _handleDesktopKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final modifier = keyboard.isControlPressed || keyboard.isMetaPressed;
    final isRepeat = event is KeyRepeatEvent;

    // Hardware media keys work even while a text field has focus.
    if (!isRepeat) {
      if (key == LogicalKeyboardKey.mediaPlayPause) {
        unawaited(_togglePlayback());
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.mediaPlay && !_player.playing ||
          key == LogicalKeyboardKey.mediaPause && _player.playing) {
        unawaited(_togglePlayback());
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.mediaTrackNext) {
        unawaited(_skip(1));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.mediaTrackPrevious) {
        unawaited(_skip(-1));
        return KeyEventResult.handled;
      }
    }

    if (_typingInTextField()) {
      if (key == LogicalKeyboardKey.escape && _shouldHandleSystemBack) {
        _handleSystemBack();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (key == LogicalKeyboardKey.space && !isRepeat) {
      if (_current == null) return KeyEventResult.ignored;
      unawaited(_togglePlayback());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowLeft) {
      final forward = key == LogicalKeyboardKey.arrowRight;
      if (modifier) {
        if (!isRepeat) unawaited(_skip(forward ? 1 : -1));
      } else {
        final seconds = keyboard.isShiftPressed ? 15 : 5;
        _seekBy(Duration(seconds: forward ? seconds : -seconds));
      }
      return KeyEventResult.handled;
    }
    if (isRepeat) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.escape && _shouldHandleSystemBack) {
      _handleSystemBack();
      return KeyEventResult.handled;
    }
    if (modifier && key == LogicalKeyboardKey.comma) {
      _updateState(() => _showSettings = true);
      return KeyEventResult.handled;
    }
    if ((modifier && key == LogicalKeyboardKey.keyF) ||
        key == LogicalKeyboardKey.slash && !keyboard.isShiftPressed) {
      _selectTab(AppTab.search);
      return KeyEventResult.handled;
    }
    if (modifier) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.slash && keyboard.isShiftPressed) {
      _showShortcutsDialog();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyL && _current != null) {
      unawaited(_toggleFavorite(_current!));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyS) {
      unawaited(_toggleShuffle());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyR) {
      unawaited(_cycleRepeatMode());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}
