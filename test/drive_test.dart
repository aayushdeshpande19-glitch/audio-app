import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:localbeat/database.dart';
import 'package:localbeat/download_manager.dart';
import 'package:localbeat/drive_service.dart';
import 'package:localbeat/drive_stream_proxy.dart';
import 'package:localbeat/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DriveAudioFile metadata heuristics', () {
    test('parses track number and title correctly', () {
      const file = DriveAudioFile(
        id: 'f1',
        name: '05 - Golden Slumbers.mp3',
        size: 3000000,
        mimeType: 'audio/mpeg',
        parentName: 'Abbey Road',
        grandparentName: 'The Beatles',
      );
      final map = file.toTrackMap();
      expect(map['id'], 'gdrive:f1');
      expect(map['drive_id'], 'f1');
      expect(map['track_number'], 5);
      expect(map['title'], 'Golden Slumbers');
      expect(map['album'], 'Abbey Road');
      expect(map['artist'], 'The Beatles');
      expect(map['format'], 'MP3');
    });

    test('parses Artist - Title filename format', () {
      const file = DriveAudioFile(
        id: 'f2',
        name: 'Pink Floyd - Time.flac',
        size: 25000000,
        mimeType: 'audio/flac',
      );
      final map = file.toTrackMap();
      expect(map['artist'], 'Pink Floyd');
      expect(map['title'], 'Time');
      expect(map['format'], 'FLAC');
    });
  });

  group('DriveService mock mode', () {
    late DriveService service;

    setUp(() {
      service = DriveService()..enableMockMode();
    });

    test('lists mock folders and scans mock audio tracks', () async {
      expect(service.isSignedIn, isTrue);
      final folders = await service.listFolders();
      expect(folders.length, 3);
      expect(folders.first.name, 'Music');

      final tracks = await service.scanFolder(folders.first.id);
      expect(tracks.length, 3);
      expect(tracks.map((t) => t.name).toList(), contains('Evening Signal.mp3'));
    });
  });

  group('DriveStreamProxy', () {
    late DriveService driveService;
    late DriveStreamProxy proxy;
    late Directory tempCacheDir;

    setUp(() async {
      HttpOverrides.global = null;
      driveService = DriveService()..enableMockMode();
      tempCacheDir = Directory.systemTemp.createTempSync('proxy_cache_');
      proxy = DriveStreamProxy(driveService: driveService, cacheDir: tempCacheDir);
      await proxy.start();
    });

    tearDown(() async {
      await proxy.stop();
      if (tempCacheDir.existsSync()) tempCacheDir.deleteSync(recursive: true);
    });

    test('serves full audio stream and handles HTTP Range requests', () async {
      final streamUrl = Uri.parse(proxy.urlFor('mock_test_song'));
      final client = http.Client();

      // Full stream request
      final fullRes = await client.get(streamUrl);
      expect(fullRes.statusCode, HttpStatus.ok);
      expect(fullRes.headers[HttpHeaders.acceptRangesHeader], 'bytes');
      expect(fullRes.bodyBytes.length, greaterThan(1000));

      // Range request (first 500 bytes)
      final rangeRes = await client.get(
        streamUrl,
        headers: {HttpHeaders.rangeHeader: 'bytes=0-499'},
      );
      expect(rangeRes.statusCode, HttpStatus.partialContent);
      expect(rangeRes.headers[HttpHeaders.contentLengthHeader], '500');
      expect(rangeRes.bodyBytes.length, 500);

      client.close();
    });
  });

  group('DownloadManager and Database integration', () {
    late LibraryDatabase db;
    late DriveService driveService;
    late DownloadManager downloadManager;
    late Directory tempDlDir;
    var changedCount = 0;

    setUp(() async {
      db = LibraryDatabase(NativeDatabase.memory());
      driveService = DriveService()..enableMockMode();
      tempDlDir = Directory.systemTemp.createTempSync('dl_mgr_');
      downloadManager = DownloadManager(
        db: db,
        driveService: driveService,
        onLibraryChanged: () => changedCount++,
        downloadsDir: tempDlDir,
      );
      await downloadManager.init();
    });

    tearDown(() async {
      await db.close();
      if (tempDlDir.existsSync()) tempDlDir.deleteSync(recursive: true);
    });

    test('downloads a mock cloud track, updates SQLite, and removes download', () async {
      const track = Track(
        id: 'gdrive:mock_dl_track',
        uri: 'gdrive://mock_dl_track',
        title: 'Mock Cloud Song',
        driveId: 'mock_dl_track',
        source: 'gdrive',
        format: 'MP3',
      );

      // Ingest track into DB first
      await db.ingestDriveTracks('mock_folder', 'token', [
        {
          'id': track.id,
          'uri': track.uri,
          'drive_id': track.driveId,
          'title': track.title,
        },
      ]);

      expect(changedCount, 0);

      // Trigger download
      await downloadManager.downloadTrack(track);
      expect(changedCount, 1);

      // Verify track marked downloaded in DB
      final songsAfterDl = await db.songs(downloaded: true);
      expect(songsAfterDl.length, 1);
      final dlTrack = songsAfterDl.single;
      expect(dlTrack.isDownloaded, isTrue);
      expect(dlTrack.downloadedPath, isNotNull);

      // Verify downloaded file exists on disk
      final file = File(dlTrack.downloadedPath!);
      expect(file.existsSync(), isTrue);

      // Remove download
      await downloadManager.removeDownload(dlTrack);
      expect(file.existsSync(), isFalse);

      final songsAfterRemove = await db.songs(downloaded: true);
      expect(songsAfterRemove, isEmpty);
      // Track still exists in cloud library
      expect((await db.songs(cloudOnly: true)).length, 1);
    });
  });
}
