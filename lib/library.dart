import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import 'database.dart';
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
  LibraryController(this.db, this.access);
  final LibraryDatabase db;
  final LibraryAccess access;
  bool scanning = false;
  int scanned = 0, revision = 0;
  String? error;
  String? currentFolder;
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
            changed();
          }
          await db.finishScan(folder.uri, token);
        } catch (e) {
          error =
              'Could not read ${folder.name}. Select the folder again to restore access.';
          await db.failScan(folder.uri, error!);
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
}
