import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import 'database.dart';
import 'drive_service.dart';
import 'playback.dart';

/// Platform boundary: a desktop implementation can replace this adapter later.
abstract interface class LibraryAccess {
  Future<Map<String, String>?> pickFolder();
  Future<List<Map<String, dynamic>>> scanPage(
    String folder,
    List<Map<String, dynamic>>? known,
  );
  Future<void> releaseFolder(String uri);
}

class AndroidLibraryAccess implements LibraryAccess {
  static const channel = MethodChannel('app.localbeat/library');
  @override
  Future<Map<String, String>?> pickFolder() async {
    return await channel.invokeMapMethod<String, String>('pickFolder');
  }

  @override
  Future<List<Map<String, dynamic>>> scanPage(
    String folder,
    List<Map<String, dynamic>>? known,
  ) async {
    final page = await channel.invokeListMethod<dynamic>('scanPage', {
      'folder': folder,
      'known': known,
    });
    return (page ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  @override
  Future<void> releaseFolder(String uri) =>
      channel.invokeMethod('releaseFolder', {'uri': uri});
}

class LibraryController extends ChangeNotifier {
  LibraryController(this.db, this.access, {this.driveService});
  final LibraryDatabase db;
  final LibraryAccess access;
  final DriveService? driveService;
  bool scanning = false;
  int scanned = 0, revision = 0;
  String? error;
  String? currentFolder;
  String? currentDriveFolder;
  void changed() {
    revision++;
    notifyListeners();
  }

  Future<void> addFolder() async {
    if (scanning) return;
    try {
      final folder = await access.pickFolder();
      if (folder == null) return;
      await db.addFolder(folder['uri']!, folder['name']!);
      await refresh();
    } catch (e) {
      error = 'Could not open that folder. $e';
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    if (scanning) return;
    scanning = true;
    ArtworkCache.clear();
    scanned = 0;
    error = null;
    notifyListeners();
    try {
      for (final folder in await db.folders()) {
        currentFolder = folder.name;
        notifyListeners();
        final token = DateTime.now().microsecondsSinceEpoch.toString();
        try {
          var known = await db.fingerprints(folder.uri);
          var first = true;
          var lastProgressUpdate = DateTime.now();
          while (true) {
            final page = await access.scanPage(
              folder.uri,
              first ? known : null,
            );
            first = false;
            known = [];
            if (page.isEmpty) break;
            await db.ingest(folder.uri, token, page);
            scanned += page.length;
            final now = DateTime.now();
            if (now.difference(lastProgressUpdate).inMilliseconds >= 250) {
              lastProgressUpdate = now;
              notifyListeners();
            }
          }
          await db.finishScan(folder.uri, token);
          changed();
        } catch (e) {
          error =
              'Could not read ${folder.name}. Select the folder again to restore access.';
          await db.failScan(folder.uri, error!);
          changed();
        }
      }
    } catch (e) {
      error = 'Library refresh failed: $e';
    } finally {
      scanning = false;
      currentFolder = null;
      changed();
    }
  }

  Future<void> removeFolder(String uri) async {
    if (scanning) return;
    await db.removeFolder(uri);
    try {
      await access.releaseFolder(uri);
    } catch (_) {
      /* Already revoked by Android. */
    }
    changed();
  }

  Future<void> syncDriveFolder(String folderId, String folderName) async {
    if (scanning || driveService == null) return;
    scanning = true;
    currentFolder = 'Google Drive: $folderName';
    currentDriveFolder = folderName;
    scanned = 0;
    error = null;
    notifyListeners();

    try {
      final token = DateTime.now().microsecondsSinceEpoch.toString();
      final audioFiles = await driveService!.scanFolder(
        folderId,
        folderName: folderName,
        onProgress: (count) {
          scanned = count;
          notifyListeners();
        },
      );

      final trackMaps = audioFiles.map((f) => f.toTrackMap()).toList();
      await db.ingestDriveTracks(folderId, token, trackMaps);
      await db.putSetting('gdrive_sync', {
        'folder_id': folderId,
        'folder_name': folderName,
        'synced_at': DateTime.now().millisecondsSinceEpoch,
        'count': trackMaps.length,
      });
      scanned = trackMaps.length;
      changed();
    } catch (e) {
      error = 'Could not sync Google Drive folder: $e';
      notifyListeners();
    } finally {
      scanning = false;
      currentFolder = null;
      changed();
    }
  }

  Future<void> clearDriveLibrary() async {
    if (scanning) return;
    await db.clearDriveTracks();
    await db.putSetting('gdrive_sync', {});
    currentDriveFolder = null;
    changed();
  }
}
