import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localbeat/database.dart';
import 'package:localbeat/library.dart';
import 'package:localbeat/models.dart';

Map<String, dynamic> song(
  String id, {
  String? uri,
  String? title,
  String artist = 'Artist',
  String album = 'Album',
  int modified = 1,
}) => {
  'id': id,
  'uri': uri ?? 'content://music/$id',
  'title': title ?? 'Song $id',
  'artist': artist,
  'album': album,
  'modified': modified,
  'size': 1024,
  'duration_ms': 180000,
  'format': 'MP3',
};

class FakeLibrary implements LibraryAccess {
  List<List<Map<String, dynamic>>> pages = [];
  bool fail = false;
  @override
  Future<Map<String, String>?> pickFolder() async => {
    'uri': 'folder',
    'name': 'Music',
  };
  @override
  Future<void> releaseFolder(String uri) async {}
  @override
  Future<List<Map<String, dynamic>>> scanPage(
    String folder,
    List<Map<String, dynamic>>? known,
  ) async {
    if (fail) throw StateError('Revoked');
    return pages.isEmpty ? [] : pages.removeAt(0);
  }
}

void main() {
  late LibraryDatabase db;
  setUp(() async {
    db = LibraryDatabase(NativeDatabase.memory());
    await db.addFolder('a', 'Music');
  });
  tearDown(() async => db.close());
  test(
    'schema version, literal search, metadata updates preserve favorites',
    () async {
      await db.ingest('a', '1', [
        song('one', title: '100%_Love'),
        song('two', title: 'Ordinary'),
      ]);
      await db.finishScan('a', '1');
      final track = (await db.songs(query: '%_')).single;
      expect(track.id, 'one');
      expect(db.schemaVersion, 3);
      await db.favorite(track);
      await db.ingest('a', '2', [song('one', title: 'Retagged', modified: 2)]);
      await db.finishScan('a', '2');
      expect((await db.songs(favorites: true)).single.title, 'Retagged');
      expect(await db.songs(query: 'ordinary'), isEmpty);
    },
  );
  test(
    'overlapping folders deduplicate and retain a valid URI after removal',
    () async {
      await db.addFolder('b', 'Nested');
      await db.ingest('a', '1', [song('same', uri: 'content://a/same')]);
      await db.finishScan('a', '1');
      await db.ingest('b', '2', [song('same', uri: 'content://b/same')]);
      await db.finishScan('b', '2');
      expect((await db.songs()).length, 1);
      await db.removeFolder('a');
      expect((await db.songs()).single.uri, 'content://b/same');
      await db.removeFolder('b');
      expect(await db.songs(), isEmpty);
    },
  );
  test(
    'missing files stay in playlists and return with favorite intact',
    () async {
      await db.ingest('a', '1', [song('one'), song('two')]);
      await db.finishScan('a', '1');
      final id = await db.createPlaylist('Road trip');
      await db.addToPlaylist(id, 'one');
      await db.favorite((await db.songs()).first);
      await db.finishScan('a', 'empty');
      final missing = (await db.songs(playlist: id)).single;
      expect(missing.available, false);
      expect(missing.favorite, true);
      await db.ingest('a', '3', [song('one')]);
      await db.finishScan('a', '3');
      expect((await db.songs(playlist: id)).single.available, true);
      expect((await db.songs(favorites: true)).single.id, 'one');
    },
  );
  test(
    'unchanged scan keeps metadata and playlists reorder without duplicates',
    () async {
      await db.ingest('a', '1', [song('1'), song('2'), song('3')]);
      await db.finishScan('a', '1');
      await db.ingest('a', '2', [
        {'id': '1', 'uri': 'content://music/1', 'unchanged': true},
      ]);
      final id = await db.createPlaylist('Focus');
      for (final track in ['1', '2', '3', '1']) {
        await db.addToPlaylist(id, track);
      }
      expect((await db.playlists()).single.count, 3);
      final original = await db.songs(playlist: id);
      await db.reorderPlaylist(id, [original[2], original[0], original[1]]);
      expect((await db.songs(playlist: id)).map((t) => t.id), ['3', '1', '2']);
      await db.removeFromPlaylist(id, '1');
      expect((await db.playlists()).single.count, 2);
      await db.renamePlaylist(id, 'Rest');
      expect((await db.playlists()).single.name, 'Rest');
      await db.deletePlaylist(id);
      expect(await db.playlists(), isEmpty);
    },
  );
  test('folder revocation hides tracks without losing user data', () async {
    await db.ingest('a', '1', [song('1')]);
    await db.finishScan('a', '1');
    await db.favorite((await db.songs()).single);
    await db.failScan('a', 'Permission revoked');
    expect(await db.songs(), isEmpty);
    await db.ingest('a', '2', [
      {'id': '1', 'uri': 'content://music/1', 'unchanged': true},
    ]);
    await db.finishScan('a', '2');
    expect((await db.songs(favorites: true)).single.id, '1');
  });
  test(
    'queue restoration resolves available IDs in order, including repeats',
    () async {
      await db.ingest('a', '1', [song('1'), song('2')]);
      await db.finishScan('a', '1');
      await db.putSetting('playback', {
        'ids': ['2', 'missing', '1', '2'],
        'position': 12345,
      });
      final saved = await db.setting('playback');
      expect(saved['position'], 12345);
      expect(
        (await db.tracksByIds(List<String>.from(saved['ids'])))
            .map((t) => t.id),
        ['2', '1', '2'],
      );
    },
  );
  test('album track ordering and recent history', () async {
    await db.ingest('a', '1', [
      {...song('1'), 'track_number': 2},
      {...song('2'), 'track_number': 1},
    ]);
    await db.finishScan('a', '1');
    expect((await db.songs(album: 'Album')).map((t) => t.id), ['2', '1']);
    await db.played('1');
    expect((await db.songs(recent: true)).single.id, '1');
    expect((await db.groups(artists: false)).single.count, 2);
  });
  test(
    'scan controller ingests batches and reports permission failures',
    () async {
      final access = FakeLibrary()
        ..pages = [
          [song('new')],
        ];
      final lib = LibraryController(db, access);
      await lib.refresh();
      expect(lib.scanned, 1);
      expect(lib.scanning, false);
      expect(lib.error, isNull);
      access.fail = true;
      await lib.refresh();
      expect(lib.error, isNotNull);
      expect(lib.scanning, false);
      expect(await db.songs(), isEmpty);
      lib.dispose();
    },
  );
  test('20,000 tracks support search, grouping and large queue restore', () async {
    final watch = Stopwatch()..start();
    for (var i = 0; i < 20000; i += 200) {
      await db.ingest(
        'a',
        'big',
        List.generate(
          200,
          (j) => song(
            '${i + j}',
            title: 'Track ${i + j}',
            artist: 'Artist ${(i + j) % 100}',
            album: 'Album ${(i + j) % 400}',
          ),
        ),
      );
    }
    await db.finishScan('a', 'big');
    final importMs = watch.elapsedMilliseconds;
    watch.reset();
    final results = await db.songs(query: 'Track 19999');
    expect(results.single.id, '19999');
    expect((await db.groups(artists: true)).length, 100);
    expect((await db.songs(sort: SongSort.added)).length, 20000);
    expect(
      (await db.tracksByIds(List.generate(20000, (i) => '$i'))).length,
      20000,
    );
    // Report measured database performance; device indexing is a separate test.
    // ignore: avoid_print
    print(
      '20k database fixture: ingest ${importMs}ms; search + groups + full listing + restore ${watch.elapsedMilliseconds}ms',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('schema version 3 includes track_added and track_downloaded index', () async {
    expect(db.schemaVersion, 3);
    final rows = await db.rows(
      "SELECT name FROM sqlite_master WHERE type='index' AND name IN ('track_added', 'track_downloaded', 'track_source')",
    );
    final names = rows.map((r) => r['name']).toSet();
    expect(names.contains('track_added'), isTrue);
    expect(names.contains('track_downloaded'), isTrue);
    expect(names.contains('track_source'), isTrue);
  });

  test('drive tracks can be ingested, marked downloaded, and filtered', () async {
    await db.ingestDriveTracks('drive_folder_1', 'token_1', [
      {
        'id': 'gdrive:track1',
        'uri': 'gdrive://track1',
        'drive_id': 'track1',
        'title': 'Cloud Song 1',
        'artist': 'Cloud Artist',
        'album': 'Cloud Album',
      },
      {
        'id': 'gdrive:track2',
        'uri': 'gdrive://track2',
        'drive_id': 'track2',
        'title': 'Cloud Song 2',
        'artist': 'Cloud Artist',
        'album': 'Cloud Album',
      },
    ]);

    final allDrive = await db.songs(cloudOnly: true);
    expect(allDrive.length, 2);
    expect(allDrive.first.isCloud, isTrue);
    expect(allDrive.first.isDownloaded, isFalse);

    // Filter downloaded: initially only local files (0 local so far)
    final downloadedBefore = await db.songs(downloaded: true);
    expect(downloadedBefore, isEmpty);

    // Mark track1 downloaded
    await db.markDownloaded('gdrive:track1', '/path/to/downloaded/track1.mp3');
    final downloadedAfter = await db.songs(downloaded: true);
    expect(downloadedAfter.length, 1);
    expect(downloadedAfter.single.id, 'gdrive:track1');
    expect(downloadedAfter.single.isDownloaded, isTrue);
    expect(downloadedAfter.single.downloadedPath, '/path/to/downloaded/track1.mp3');

    // Remove download
    await db.removeDownload('gdrive:track1');
    final afterRemove = await db.songs(downloaded: true);
    expect(afterRemove, isEmpty);
    // Track still exists in cloud library
    expect((await db.songs(cloudOnly: true)).length, 2);
  });

  test('playback position and current track scalar settings update correctly', () async {
    await db.putSetting('playback_position', 45000);
    await db.putSetting('playback_current', 'track-123');
    final pos = await db.setting('playback_position');
    final current = await db.setting('playback_current');
    expect(pos, 45000);
    expect(current, 'track-123');
  });
}
