import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'database.dart';
import 'drive_service.dart';
import 'models.dart';

enum DownloadStatus { idle, downloading, completed, failed }

class DownloadManager extends ChangeNotifier {
  DownloadManager({
    required this.db,
    required this.driveService,
    required this.onLibraryChanged,
    this._downloadsDir,
  });

  final LibraryDatabase db;
  final DriveService driveService;
  final VoidCallback onLibraryChanged;

  Directory? _downloadsDir;
  final Map<String, double> _progress = {};
  final Set<String> _active = {};

  bool isDownloading(String trackId) => _active.contains(trackId);
  double? getProgress(String trackId) => _progress[trackId];

  Future<void> init() async {
    if (_downloadsDir == null) {
      final docDir = await getApplicationDocumentsDirectory();
      _downloadsDir = Directory('${docDir.path}/downloads');
    }
    if (!_downloadsDir!.existsSync()) {
      _downloadsDir!.createSync(recursive: true);
    }
  }

  Future<Directory> _getDir() async {
    if (_downloadsDir == null) {
      await init();
    }
    return _downloadsDir!;
  }

  Future<void> downloadTrack(Track track) async {
    if (!track.isCloud || track.driveId == null) return;
    if (_active.contains(track.id)) return;

    _active.add(track.id);
    _progress[track.id] = 0.0;
    notifyListeners();

    try {
      final dir = await _getDir();
      final ext = track.format.isNotEmpty ? track.format.toLowerCase() : 'mp3';
      final file = File('${dir.path}/${track.driveId}.$ext');

      if (driveService.isMock || track.driveId!.startsWith('mock_')) {
        // Mock download: simulate chunked transfer with progress updates
        final sink = file.openWrite();
        for (var step = 1; step <= 10; step++) {
          await Future.delayed(const Duration(milliseconds: 100));
          _progress[track.id] = step / 10.0;
          notifyListeners();
          sink.add(List.filled(1024 * 32, 0));
        }
        await sink.flush();
        await sink.close();
      } else {
        // Real Google Drive download
        final res = await driveService.getMediaStream(track.driveId!);
        final contentLength = res.contentLength ?? 1;
        var received = 0;

        final sink = file.openWrite();
        await res.stream.listen((chunk) {
          sink.add(chunk);
          received += chunk.length;
          _progress[track.id] = (received / contentLength).clamp(0.0, 1.0);
          notifyListeners();
        }).asFuture();

        await sink.flush();
        await sink.close();
      }

      await db.markDownloaded(track.id, file.path);
      onLibraryChanged();
    } catch (e) {
      debugPrint('Download failed for track ${track.title}: $e');
    } finally {
      _active.remove(track.id);
      _progress.remove(track.id);
      notifyListeners();
    }
  }

  Future<void> removeDownload(Track track) async {
    try {
      if (track.downloadedPath != null) {
        final f = File(track.downloadedPath!);
        if (f.existsSync()) {
          f.deleteSync();
        }
      }
    } catch (_) {}
    await db.removeDownload(track.id);
    onLibraryChanged();
    notifyListeners();
  }

  Future<void> downloadAlbum(List<Track> tracks) async {
    for (final track in tracks) {
      if (track.isCloud && !track.isDownloaded) {
        await downloadTrack(track);
      }
    }
  }

  Future<int> getDownloadedSizeBytes() async {
    final dir = await _getDir();
    if (!dir.existsSync()) return 0;
    var total = 0;
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is File) {
        total += entity.lengthSync();
      }
    }
    return total;
  }

  Future<void> deleteAllDownloads() async {
    final dir = await _getDir();
    if (dir.existsSync()) {
      for (final entity in dir.listSync()) {
        try {
          entity.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
    await db.customStatement(
      'UPDATE tracks SET is_downloaded=0, downloaded_path=NULL WHERE is_downloaded=1',
    );
    onLibraryChanged();
    notifyListeners();
  }
}
