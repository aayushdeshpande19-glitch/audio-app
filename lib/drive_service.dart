import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;

class DriveFolder {
  const DriveFolder({required this.id, required this.name});
  final String id, name;
}

class DriveAudioFile {
  const DriveAudioFile({
    required this.id,
    required this.name,
    required this.size,
    required this.mimeType,
    this.parentName,
    this.grandparentName,
  });
  final String id, name, mimeType;
  final int size;
  final String? parentName, grandparentName;

  Map<String, dynamic> toTrackMap() {
    final cleanExt = name.contains('.') ? name.substring(name.lastIndexOf('.') + 1).toLowerCase() : '';
    var title = name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
    var artist = 'Unknown artist';
    var album = 'Unknown album';
    var trackNumber = 0;

    // Check for "01 - Title" or "01. Title"
    final trackNumMatch = RegExp(r'^(\d{1,3})[\s.\-_]+(.+)$').firstMatch(title);
    if (trackNumMatch != null) {
      trackNumber = int.tryParse(trackNumMatch.group(1)!) ?? 0;
      title = trackNumMatch.group(2)!.trim();
    }

    // Check for "Artist - Title"
    if (title.contains(' - ')) {
      final parts = title.split(' - ');
      if (parts.length >= 2) {
        artist = parts[0].trim();
        title = parts.sublist(1).join(' - ').trim();
      }
    }

    // Heuristics from folder structure if available
    if (parentName != null && parentName!.isNotEmpty && parentName != 'Music' && parentName != 'root') {
      album = parentName!;
      if (grandparentName != null && grandparentName!.isNotEmpty && grandparentName != 'Music' && grandparentName != 'root') {
        artist = grandparentName!;
      }
    }

    return {
      'id': 'gdrive:$id',
      'uri': 'gdrive://$id',
      'drive_id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'album_artist': artist,
      'duration_ms': 0,
      'track_number': trackNumber,
      'disc_number': 0,
      'format': cleanExt.toUpperCase(),
      'size': size,
      'modified': DateTime.now().millisecondsSinceEpoch,
    };
  }
}

/// Manages Google Drive OAuth authentication and file operations.
class DriveService extends ChangeNotifier {
  DriveService({GoogleSignIn? googleSignIn})
      : _googleSignIn = googleSignIn ??
            GoogleSignIn(
              scopes: [drive.DriveApi.driveReadonlyScope],
            );

  final GoogleSignIn _googleSignIn;
  GoogleSignInAccount? _currentUser;
  drive.DriveApi? _driveApi;
  http.Client? _authClient;

  bool _isMock = false;
  bool get isMock => _isMock;

  bool get isSignedIn => _currentUser != null || _isMock;
  String? get userEmail => _isMock ? 'demo.localbeat@gmail.com' : _currentUser?.email;
  String? get userDisplayName => _isMock ? 'Demo Cloud User' : _currentUser?.displayName;

  Future<void> init() async {
    _googleSignIn.onCurrentUserChanged.listen((account) async {
      _currentUser = account;
      if (account != null) {
        final authHeaders = await account.authHeaders;
        _authClient = _AuthenticatedClient(authHeaders);
        _driveApi = drive.DriveApi(_authClient!);
      } else {
        _authClient = null;
        _driveApi = null;
      }
      notifyListeners();
    });
    try {
      await _googleSignIn.signInSilently();
    } catch (_) {
      // Silent sign-in may fail if not previously authenticated.
    }
  }

  void enableMockMode() {
    _isMock = true;
    notifyListeners();
  }

  void disableMockMode() {
    _isMock = false;
    notifyListeners();
  }

  Future<bool> signIn() async {
    try {
      final account = await _googleSignIn.signIn();
      if (account != null) {
        _isMock = false;
        final authHeaders = await account.authHeaders;
        _authClient = _AuthenticatedClient(authHeaders);
        _driveApi = drive.DriveApi(_authClient!);
        notifyListeners();
        return true;
      }
    } catch (e) {
      debugPrint('Google Sign-In error: $e');
    }
    return false;
  }

  Future<void> signOut() async {
    _isMock = false;
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
    _currentUser = null;
    _driveApi = null;
    _authClient = null;
    notifyListeners();
  }

  Future<Map<String, String>> getAuthHeaders() async {
    if (_isMock) return {'Authorization': 'Bearer mock_token'};
    if (_currentUser != null) {
      return await _currentUser!.authHeaders;
    }
    return {};
  }

  /// Lists folders inside a given parent folder (or root).
  Future<List<DriveFolder>> listFolders({String? parentId}) async {
    if (_isMock) {
      return const [
        DriveFolder(id: 'mock_music_folder', name: 'Music'),
        DriveFolder(id: 'mock_audio_folder', name: 'Lossless Library'),
        DriveFolder(id: 'mock_podcasts_folder', name: 'Podcasts'),
      ];
    }
    if (_driveApi == null) return [];

    final qParent = parentId == null ? "'root' in parents" : "'$parentId' in parents";
    final query = "mimeType = 'application/vnd.google-apps.folder' and $qParent and trashed = false";

    final result = await _driveApi!.files.list(
      q: query,
      spaces: 'drive',
      $fields: 'files(id, name)',
      orderBy: 'name',
    );

    return (result.files ?? [])
        .where((f) => f.id != null && f.name != null)
        .map((f) => DriveFolder(id: f.id!, name: f.name!))
        .toList();
  }

  /// Recursively scans audio files inside a Google Drive folder.
  Future<List<DriveAudioFile>> scanFolder(
    String folderId, {
    String? folderName,
    String? parentFolderName,
    void Function(int count)? onProgress,
  }) async {
    if (_isMock) {
      // Return synthetic cloud audio fixtures for testing
      return [
        DriveAudioFile(
          id: 'mock_evening_mp3',
          name: 'Evening Signal.mp3',
          size: 1448576,
          mimeType: 'audio/mpeg',
          parentName: 'After Hours',
          grandparentName: 'LocalBeat Sessions',
        ),
        DriveAudioFile(
          id: 'mock_quiet_city_flac',
          name: 'Quiet City.flac',
          size: 5242880,
          mimeType: 'audio/flac',
          parentName: 'After Hours',
          grandparentName: 'LocalBeat Sessions',
        ),
        DriveAudioFile(
          id: 'mock_ambient_opus',
          name: 'Ambient Skyline.opus',
          size: 984000,
          mimeType: 'audio/ogg',
          parentName: 'After Hours',
          grandparentName: 'LocalBeat Sessions',
        ),
      ];
    }

    if (_driveApi == null) return [];

    final audioFiles = <DriveAudioFile>[];
    final subfolders = <DriveFolder>[];

    String? pageToken;
    do {
      final query = "'$folderId' in parents and trashed = false";
      final result = await _driveApi!.files.list(
        q: query,
        spaces: 'drive',
        pageToken: pageToken,
        $fields: 'nextPageToken, files(id, name, size, mimeType)',
      );

      for (final f in result.files ?? []) {
        if (f.id == null || f.name == null) continue;
        if (f.mimeType == 'application/vnd.google-apps.folder') {
          subfolders.add(DriveFolder(id: f.id!, name: f.name!));
        } else if (_isAudioFile(f.name!, f.mimeType)) {
          audioFiles.add(
            DriveAudioFile(
              id: f.id!,
              name: f.name!,
              size: int.tryParse(f.size ?? '0') ?? 0,
              mimeType: f.mimeType ?? 'audio/mpeg',
              parentName: folderName,
              grandparentName: parentFolderName,
            ),
          );
          onProgress?.call(audioFiles.length);
        }
      }
      pageToken = result.nextPageToken;
    } while (pageToken != null);

    // Recursively scan subfolders
    for (final sub in subfolders) {
      final nested = await scanFolder(
        sub.id,
        folderName: sub.name,
        parentFolderName: folderName,
        onProgress: (c) => onProgress?.call(audioFiles.length + c),
      );
      audioFiles.addAll(nested);
    }

    return audioFiles;
  }

  /// Fetches media download stream for a Drive file.
  Future<http.StreamedResponse> getMediaStream(String fileId, {Map<String, String>? headers}) async {
    final url = Uri.parse('https://www.googleapis.com/drive/v3/files/$fileId?alt=media');
    final auth = await getAuthHeaders();
    final allHeaders = <String, String>{
      ...auth,
      ...?headers,
    };

    final request = http.Request('GET', url)..headers.addAll(allHeaders);
    final client = http.Client();
    return await client.send(request);
  }

  static bool _isAudioFile(String name, String? mimeType) {
    if (mimeType != null && mimeType.startsWith('audio/')) return true;
    final lower = name.toLowerCase();
    return lower.endsWith('.mp3') ||
        lower.endsWith('.flac') ||
        lower.endsWith('.m4a') ||
        lower.endsWith('.aac') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.ogg') ||
        lower.endsWith('.opus');
  }
}

class _AuthenticatedClient extends http.BaseClient {
  _AuthenticatedClient(this._headers);
  final Map<String, String> _headers;
  final http.Client _client = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _client.send(request);
  }
}
