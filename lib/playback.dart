import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

import 'database.dart';
import 'library.dart';
import 'models.dart';

class ArtworkCache {
  static final _cache = <String, Future<String?>>{};
  static void clear() => _cache.clear();
  static Future<String?> resolve(String? source) {
    if (source == null) return Future.value(null);
    if (!source.startsWith('content:')) return Future.value(source);
    if (_cache.length > 512) _cache.remove(_cache.keys.first);
    return _cache.putIfAbsent(source, () async {
      try {
        return await AndroidLibraryAccess.channel.invokeMethod<String>(
          'artwork',
          {'uri': source},
        );
      } catch (_) {
        return null;
      }
    });
  }
}

abstract interface class PlaybackController {
  Future<void> playTracks(List<Track> tracks, {int index = 0});
  Future<void> enqueue(Track track, {bool next = false});
  Future<void> move(int from, int to);
  Future<void> removeAt(int index);
}

class LocalAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler
    implements PlaybackController {
  LocalAudioHandler(this.db) {
    _player.playbackEventStream.listen((_) => _broadcast());
    _player.currentIndexStream.listen((_) => _currentChanged());
    _player.playerStateStream.listen((_) {
      _broadcast();
      _scheduleSave();
    });
    _player.errorStream.listen((e) {
      messages.add(
        'Cannot play this file. It may be missing, damaged, or use an unsupported codec.',
      );
    });
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _scheduleSave(),
    );
  }
  final LibraryDatabase db;
  final AudioPlayer _player = AudioPlayer(maxSkipsOnError: 6);
  final messages = StreamController<String>.broadcast();
  final List<Track> _tracks = [];
  List<Track> get tracks => List.unmodifiable(_tracks);
  AudioPlayer get player => _player;
  Timer? _saveTimer, _saveDebounce;
  Future<void> _operations = Future.value();
  bool _loading = false;
  String? _lastPlayed;
  Future<void> configure() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
  }

  Future<void> _serial(Future<void> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.catchError((Object error, StackTrace stack) {
      messages.add(
        'Playback could not complete. Try another track or refresh your folders.',
      );
    });
    return _operations;
  }

  MediaItem _item(Track t) => MediaItem(
    id: t.id,
    title: t.title,
    artist: t.artist,
    album: t.album,
    duration: Duration(milliseconds: t.durationMs),
    extras: {'uri': t.uri, 'art': t.artPath},
  );
  void _publishQueue() {
    queue.add(_tracks.map(_item).toList());
  }

  AudioSource _source(Track t) =>
      AudioSource.uri(Uri.parse(t.uri), tag: _item(t));
  @override
  Future<void> playTracks(List<Track> tracks, {int index = 0}) =>
      _serial(() async {
        final selected = tracks.isEmpty
            ? null
            : tracks[index.clamp(0, tracks.length - 1)];
        final valid = tracks.where((t) => t.available).toList();
        if (valid.isEmpty) {
          messages.add('No available tracks. Check your music folders.');
          return;
        }
        var target = valid.indexWhere((t) => t.id == selected?.id);
        if (target < 0) target = 0;
        await _load(valid, target, Duration.zero);
        await play();
      });
  Future<void> _load(List<Track> tracks, int index, Duration position) async {
    _loading = true;
    try {
      await _player.pause();
      _tracks
        ..clear()
        ..addAll(tracks);
      _publishQueue();
      await _player.setAudioSources(
        _tracks.map(_source).toList(),
        initialIndex: index,
        initialPosition: position,
      );
    } finally {
      _loading = false;
      _currentChanged();
      _scheduleSave();
    }
  }

  Future<void> restore() async {
    try {
      final saved = await db.setting('playback');
      if (saved is! Map) return;
      final ids = List<String>.from(saved['ids'] as List);
      final tracks = await db.tracksByIds(ids);
      if (tracks.isEmpty) return;
      final current = saved['current'] as String?;
      final originalIndex = (saved['index'] as int? ?? 0).clamp(0, ids.length - 1);
      final availableIds = tracks.map((t) => t.id).toSet();
      var index = ids.take(originalIndex).where(availableIds.contains).length;
      if (index >= tracks.length || tracks[index].id != current) {
        index = tracks.indexWhere((t) => t.id == current);
      }
      if (index < 0) index = 0;
      await _load(
        tracks,
        index,
        tracks[index].id == current
            ? Duration(milliseconds: (saved['position'] as int?) ?? 0)
            : Duration.zero,
      );
      await _player.setLoopMode(
        LoopMode.values[(saved['repeat'] as int? ?? 0).clamp(0, 2)],
      );
      await _player.setShuffleModeEnabled(saved['shuffle'] == true);
      _broadcast();
    } catch (_) {
      messages.add(
        'The previous queue could not be restored. Your library is still available.',
      );
    }
  }

  void _currentChanged() {
    if (_loading) return;
    final i = _player.currentIndex;
    if (i == null || i >= _tracks.length) {
      mediaItem.add(null);
      return;
    }
    final track = _tracks[i];
    mediaItem.add(_item(track));
    ArtworkCache.resolve(track.artPath).then((path) {
      if (path != null && mediaItem.value?.id == track.id) {
        mediaItem.add(_item(track).copyWith(artUri: Uri.file(path)));
      }
    });
    _recordPlayed();
    _broadcast();
    _scheduleSave();
  }

  void _recordPlayed() {
    final id = mediaItem.value?.id;
    if (_player.playing && id != null && id != _lastPlayed) {
      _lastPlayed = id;
      unawaited(db.played(id));
    }
  }

  void _broadcast() {
    _recordPlayed();
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          _player.playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: [0, 1, 2],
        processingState: switch (_player.processingState) {
          ProcessingState.idle => AudioProcessingState.idle,
          ProcessingState.loading => AudioProcessingState.loading,
          ProcessingState.buffering => AudioProcessingState.buffering,
          ProcessingState.ready => AudioProcessingState.ready,
          ProcessingState.completed => AudioProcessingState.completed,
        },
        playing: _player.playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: _player.currentIndex,
        shuffleMode: _player.shuffleModeEnabled
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
        repeatMode: switch (_player.loopMode) {
          LoopMode.off => AudioServiceRepeatMode.none,
          LoopMode.one => AudioServiceRepeatMode.one,
          LoopMode.all => AudioServiceRepeatMode.all,
        },
      ),
    );
  }

  void _scheduleSave() {
    if (_loading) return;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(save()),
    );
  }

  Future<void> save() async {
    if (_loading) return;
    await db.putSetting('playback', {
      'ids': _tracks.map((t) => t.id).toList(),
      'current': mediaItem.value?.id,
      'index': _player.currentIndex,
      'position': _player.position.inMilliseconds,
      'repeat': _player.loopMode.index,
      'shuffle': _player.shuffleModeEnabled,
    });
  }

  @override
  Future<void> play() async {
    if (_tracks.isEmpty) return;
    if (_player.processingState == ProcessingState.completed) {
      await _player.seek(Duration.zero, index: _player.currentIndex);
    }
    unawaited(
      _player.play().catchError((Object e) {
        messages.add('Could not play this track. Try refreshing your folders.');
      }),
    );
  }

  @override
  Future<void> pause() async {
    await _player.pause();
    await save();
  }

  @override
  Future<void> seek(Duration position) async {
    await _player.seek(position);
    _scheduleSave();
  }

  @override
  Future<void> skipToNext() async {
    if (_player.hasNext) await _player.seekToNext();
  }

  @override
  Future<void> skipToPrevious() async {
    if (_player.position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
    } else if (_player.hasPrevious) {
      await _player.seekToPrevious();
    } else {
      await seek(Duration.zero);
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index >= 0 && index < _tracks.length) {
      await _player.seek(Duration.zero, index: index);
      await play();
    }
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    if (shuffleMode != AudioServiceShuffleMode.none) await _player.shuffle();
    await _player.setShuffleModeEnabled(
      shuffleMode != AudioServiceShuffleMode.none,
    );
    _broadcast();
    _scheduleSave();
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    await _player.setLoopMode(switch (repeatMode) {
      AudioServiceRepeatMode.one => LoopMode.one,
      AudioServiceRepeatMode.all ||
      AudioServiceRepeatMode.group => LoopMode.all,
      _ => LoopMode.off,
    });
    _broadcast();
    _scheduleSave();
  }

  @override
  Future<void> enqueue(Track t, {bool next = false}) => _serial(() async {
    if (!t.available) {
      messages.add('This file is currently unavailable.');
      return;
    }
    if (_tracks.isEmpty) {
      await _load([t], 0, Duration.zero);
      return;
    }
    final index = next ? (_player.currentIndex ?? 0) + 1 : _tracks.length;
    _tracks.insert(index, t);
    await _player.insertAudioSource(index, _source(t));
    // Explicit Play Next takes precedence over randomized traversal.
    if (next && _player.shuffleModeEnabled) {
      await setShuffleMode(AudioServiceShuffleMode.none);
    }
    _publishQueue();
    _scheduleSave();
  });
  @override
  Future<void> move(int from, int to) => _serial(() async {
    final t = _tracks.removeAt(from);
    _tracks.insert(to, t);
    await _player.moveAudioSource(from, to);
    _publishQueue();
    _currentChanged();
  });
  @override
  Future<void> removeAt(int index) => _serial(() async {
    _tracks.removeAt(index);
    if (_tracks.isEmpty) {
      await _player.stop();
      await _player.clearAudioSources();
      mediaItem.add(null);
    } else {
      await _player.removeAudioSourceAt(index);
    }
    _publishQueue();
    _currentChanged();
    _scheduleSave();
  });
  @override
  Future<void> stop() async {
    await save();
    await _player.stop();
    await super.stop();
  }

  Future<void> dispose() async {
    _saveTimer?.cancel();
    _saveDebounce?.cancel();
    await save();
    await _player.dispose();
    await messages.close();
  }
}
