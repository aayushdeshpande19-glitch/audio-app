import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// Hand-written SQL on Drift's background SQLite executor; no generated models.
class LibraryDatabase extends GeneratedDatabase {
  LibraryDatabase(super.e);
  static Future<LibraryDatabase> open() async {
    final dir = await getApplicationSupportDirectory();
    return LibraryDatabase(
      NativeDatabase.createInBackground(File('${dir.path}/localbeat.sqlite')),
    );
  }

  @override
  int get schemaVersion => 2;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      for (final statement in _schema) {
        await customStatement(statement);
      }
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await customStatement(
          'CREATE INDEX IF NOT EXISTS track_added ON tracks(added_at DESC)',
        );
      }
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
  static const _schema = [
    '''CREATE TABLE folders(uri TEXT PRIMARY KEY, name TEXT NOT NULL, error TEXT)''',
    '''CREATE TABLE tracks(id TEXT PRIMARY KEY, uri TEXT NOT NULL, title TEXT NOT NULL,
      artist TEXT NOT NULL, album TEXT NOT NULL, album_artist TEXT NOT NULL DEFAULT '',
      duration_ms INTEGER NOT NULL DEFAULT 0, track_number INTEGER NOT NULL DEFAULT 0,
      disc_number INTEGER NOT NULL DEFAULT 0, art_path TEXT, format TEXT NOT NULL DEFAULT '',
      modified INTEGER NOT NULL DEFAULT 0, size INTEGER NOT NULL DEFAULT 0,
      favorite INTEGER NOT NULL DEFAULT 0, added_at INTEGER NOT NULL,
      available INTEGER NOT NULL DEFAULT 1, last_played INTEGER)''',
    '''CREATE TABLE folder_tracks(folder_uri TEXT NOT NULL REFERENCES folders(uri) ON DELETE CASCADE,
      track_id TEXT NOT NULL REFERENCES tracks(id), scan_token TEXT NOT NULL, uri TEXT NOT NULL,
      PRIMARY KEY(folder_uri, track_id))''',
    'CREATE INDEX track_title ON tracks(title COLLATE NOCASE)',
    'CREATE INDEX track_artist ON tracks(artist COLLATE NOCASE)',
    'CREATE INDEX track_album ON tracks(album, album_artist)',
    'CREATE INDEX track_recent ON tracks(last_played DESC)',
    'CREATE INDEX track_added ON tracks(added_at DESC)',
    'CREATE INDEX folder_track_id ON folder_tracks(track_id)',
    '''CREATE TABLE playlists(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)''',
    '''CREATE TABLE playlist_tracks(playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
      track_id TEXT NOT NULL REFERENCES tracks(id), position INTEGER NOT NULL,
      PRIMARY KEY(playlist_id, track_id))''',
    'CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
  ];
  Future<List<Map<String, dynamic>>> rows(
    String sql, [
    List<Object> args = const [],
  ]) async => (await customSelect(
    sql,
    variables: args.map((e) => Variable(e)).toList(),
  ).get()).map((e) => e.data).toList();
  Future<void> putSetting(String key, Object value) => customStatement(
    'INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)',
    [key, jsonEncode(value)],
  );
  Future<dynamic> setting(String key) async {
    final r = await rows('SELECT value FROM settings WHERE key=?', [key]);
    return r.isEmpty ? null : jsonDecode(r.first['value'] as String);
  }

  Future<List<MusicFolder>> folders() async =>
      (await rows('SELECT * FROM folders ORDER BY name'))
          .map(
            (r) => MusicFolder(
              r['uri'] as String,
              r['name'] as String,
              r['error'] as String?,
            ),
          )
          .toList();
  Future<void> addFolder(String uri, String name) => customStatement(
    'INSERT INTO folders(uri,name) VALUES(?,?) ON CONFLICT(uri) DO UPDATE SET name=excluded.name',
    [uri, name],
  );
  Future<void> folderError(String uri, String? error) =>
      customStatement('UPDATE folders SET error=? WHERE uri=?', [error, uri]);
  Future<void> removeFolder(String uri) async {
    await transaction(() async {
      await customStatement('DELETE FROM folders WHERE uri=?', [uri]);
      await _updateAvailability();
    });
  }

  Future<void> _updateAvailability() => customStatement('''UPDATE tracks SET
    uri=COALESCE((SELECT f.uri FROM folder_tracks f JOIN folders d ON d.uri=f.folder_uri
      WHERE f.track_id=tracks.id AND d.error IS NULL LIMIT 1),uri),
    art_path=COALESCE((SELECT f.uri FROM folder_tracks f JOIN folders d ON d.uri=f.folder_uri
      WHERE f.track_id=tracks.id AND d.error IS NULL LIMIT 1),art_path), available =
    CASE WHEN EXISTS(SELECT 1 FROM folder_tracks f JOIN folders d ON d.uri=f.folder_uri
      WHERE f.track_id=tracks.id AND d.error IS NULL) THEN 1 ELSE 0 END''');
  Future<List<Map<String, dynamic>>> fingerprints(String folder) => rows(
    '''SELECT t.id,t.modified,t.size
    FROM tracks t JOIN folder_tracks f ON f.track_id=t.id WHERE f.folder_uri=?''',
    [folder],
  );
  Future<void> ingest(
    String folder,
    String token,
    List<Map<String, dynamic>> batch,
  ) async {
    await transaction(() async {
      for (final m in batch) {
        final id = m['id'] as String;
        if (m['unchanged'] != true) {
          await customStatement(
            '''INSERT INTO tracks(id,uri,title,artist,album,album_artist,
            duration_ms,track_number,disc_number,art_path,format,modified,size,added_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
            uri=excluded.uri,title=excluded.title,artist=excluded.artist,album=excluded.album,
            album_artist=excluded.album_artist,duration_ms=excluded.duration_ms,
            track_number=excluded.track_number,disc_number=excluded.disc_number,
            art_path=excluded.art_path,format=excluded.format,modified=excluded.modified,size=excluded.size''',
            [
              id,
              m['uri'],
              m['title'],
              m['artist'],
              m['album'],
              m['album_artist'] ?? '',
              m['duration_ms'] ?? 0,
              m['track_number'] ?? 0,
              m['disc_number'] ?? 0,
              m['art_path'],
              m['format'] ?? '',
              m['modified'] ?? 0,
              m['size'] ?? 0,
              DateTime.now().millisecondsSinceEpoch,
            ],
          );
        }
        await customStatement(
          '''INSERT OR REPLACE INTO folder_tracks(folder_uri,track_id,scan_token,uri)
          VALUES(?,?,?,?)''',
          [folder, id, token, m['uri']],
        );
        await customStatement('UPDATE tracks SET available=1 WHERE id=?', [id]);
      }
    });
  }

  Future<void> finishScan(String folder, String token) async {
    await transaction(() async {
      await customStatement(
        'DELETE FROM folder_tracks WHERE folder_uri=? AND scan_token<>?',
        [folder, token],
      );
      await folderError(folder, null);
      await _updateAvailability();
    });
  }

  Future<void> failScan(String folder, String error) async {
    await folderError(folder, error);
    await _updateAvailability();
  }

  Future<List<Track>> songs({
    String query = '',
    SongSort sort = SongSort.title,
    bool favorites = false,
    bool recent = false,
    String? artist,
    String? album,
    String? albumArtist,
    int? playlist,
  }) async {
    final args = <Object>[];
    var sql = playlist == null
        ? 'SELECT t.* FROM tracks t WHERE t.available=1'
        : 'SELECT t.* FROM tracks t JOIN playlist_tracks p ON p.track_id=t.id WHERE p.playlist_id=?';
    if (playlist != null) args.add(playlist);
    if (favorites) sql += ' AND t.favorite=1';
    if (recent) sql += ' AND t.last_played IS NOT NULL';
    if (artist != null) {
      sql += ' AND t.artist=?';
      args.add(artist);
    }
    if (album != null) {
      sql += ' AND t.album=? AND t.album_artist=?';
      args.addAll([album, albumArtist ?? '']);
    }
    if (query.trim().isNotEmpty) {
      // instr treats % and _ literally; search terms never become SQL.
      sql += ' AND instr(lower(t.title || char(10) || t.artist || char(10) || t.album),lower(?))>0';
      args.add(query.trim());
    }
    final order = playlist != null
        ? 'p.position'
        : recent
        ? 't.last_played DESC'
        : album != null
        ? 't.disc_number,t.track_number,t.title COLLATE NOCASE'
        : switch (sort) {
            SongSort.title => 't.title COLLATE NOCASE',
            SongSort.artist => 't.artist COLLATE NOCASE,t.title COLLATE NOCASE',
            SongSort.album =>
              't.album COLLATE NOCASE,t.disc_number,t.track_number',
            SongSort.added => 't.added_at DESC,t.title COLLATE NOCASE',
          };
    return (await rows(
      '$sql ORDER BY $order${recent ? ' LIMIT 100' : ''}',
      args,
    )).map(Track.fromMap).toList();
  }

  Future<List<LibraryGroup>> groups({required bool artists}) async =>
      (await rows(
            artists
                ? '''SELECT artist AS name,artist,COUNT(*) AS count,MAX(art_path) AS art_path FROM tracks
      WHERE available=1 GROUP BY artist ORDER BY artist COLLATE NOCASE'''
                : '''SELECT album AS name,album_artist AS artist,COUNT(*) AS count,MAX(art_path) AS art_path FROM tracks
      WHERE available=1 GROUP BY album,album_artist ORDER BY album COLLATE NOCASE''',
          ))
          .map(
            (r) => LibraryGroup(
              r['name'] as String,
              r['artist'] as String,
              r['count'] as int,
              r['art_path'] as String?,
            ),
          )
          .toList();
  Future<void> favorite(Track t) => customStatement(
    'UPDATE tracks SET favorite=? WHERE id=?',
    [t.favorite ? 0 : 1, t.id],
  );
  Future<bool> isFavorite(String id) async =>
      (await rows('SELECT favorite FROM tracks WHERE id=?', [
        id,
      ])).firstOrNull?['favorite'] ==
      1;
  Future<void> played(String id) => customStatement(
    'UPDATE tracks SET last_played=? WHERE id=?',
    [DateTime.now().millisecondsSinceEpoch, id],
  );
  Future<List<Playlist>> playlists() async =>
      (await rows(
            '''SELECT p.id,p.name,COUNT(t.track_id) AS count
    FROM playlists p LEFT JOIN playlist_tracks t ON t.playlist_id=p.id GROUP BY p.id ORDER BY p.name COLLATE NOCASE''',
          ))
          .map(
            (r) => Playlist(
              r['id'] as int,
              r['name'] as String,
              r['count'] as int,
            ),
          )
          .toList();
  Future<int> createPlaylist(String name) async {
    await customStatement('INSERT INTO playlists(name) VALUES(?)', [
      name.trim(),
    ]);
    return (await rows('SELECT last_insert_rowid() AS id')).first['id'] as int;
  }

  Future<void> renamePlaylist(int id, String name) => customStatement(
    'UPDATE playlists SET name=? WHERE id=?',
    [name.trim(), id],
  );
  Future<void> deletePlaylist(int id) =>
      customStatement('DELETE FROM playlists WHERE id=?', [id]);
  Future<void> addToPlaylist(int id, String track) => customStatement(
    '''INSERT OR IGNORE INTO playlist_tracks
    (playlist_id,track_id,position) VALUES(?,?,(SELECT COALESCE(MAX(position),-1)+1 FROM playlist_tracks WHERE playlist_id=?))''',
    [id, track, id],
  );
  Future<void> removeFromPlaylist(int id, String track) => customStatement(
    'DELETE FROM playlist_tracks WHERE playlist_id=? AND track_id=?',
    [id, track],
  );
  Future<void> reorderPlaylist(int id, List<Track> tracks) async =>
      transaction(() async {
        for (var i = 0; i < tracks.length; i++) {
          await customStatement(
            'UPDATE playlist_tracks SET position=? WHERE playlist_id=? AND track_id=?',
            [i, id, tracks[i].id],
          );
        }
      });
  Future<List<Track>> tracksByIds(List<String> ids) async {
    final found = <String, Track>{};
    for (var i = 0; i < ids.length; i += 400) {
      final chunk = ids.skip(i).take(400).toList();
      for (final r in await rows(
        'SELECT * FROM tracks WHERE available=1 AND id IN (${List.filled(chunk.length, '?').join(',')})',
        chunk,
      )) {
        final t = Track.fromMap(r);
        found[t.id] = t;
      }
    }
    return ids.where(found.containsKey).map((id) => found[id]!).toList();
  }
}
