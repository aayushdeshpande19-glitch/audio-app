class Track {
  const Track({
    required this.id,
    required this.uri,
    required this.title,
    this.artist = 'Unknown artist',
    this.album = 'Unknown album',
    this.albumArtist = '',
    this.durationMs = 0,
    this.trackNumber = 0,
    this.discNumber = 0,
    this.artPath,
    this.format = '',
    this.available = true,
    this.favorite = false,
    this.addedAt = 0,
    this.source = 'local',
    this.driveId,
    this.downloadedPath,
    this.isDownloaded = false,
  });
  final String id, uri, title, artist, album, albumArtist, format, source;
  final String? artPath, driveId, downloadedPath;
  final int durationMs, trackNumber, discNumber, addedAt;
  final bool available, favorite, isDownloaded;

  bool get isCloud => source == 'gdrive';
  bool get canStream => isCloud && !isDownloaded;

  factory Track.fromMap(Map<String, dynamic> m) => Track(
    id: m['id'] as String,
    uri: m['uri'] as String,
    title: m['title'] as String,
    artist: m['artist'] as String? ?? 'Unknown artist',
    album: m['album'] as String? ?? 'Unknown album',
    albumArtist: m['album_artist'] as String? ?? '',
    durationMs: (m['duration_ms'] as num?)?.toInt() ?? 0,
    trackNumber: (m['track_number'] as num?)?.toInt() ?? 0,
    discNumber: (m['disc_number'] as num?)?.toInt() ?? 0,
    artPath: m['art_path'] as String?,
    format: m['format'] as String? ?? '',
    available: m['available'] != 0,
    favorite: m['favorite'] == 1,
    addedAt: (m['added_at'] as num?)?.toInt() ?? 0,
    source: m['source'] as String? ?? 'local',
    driveId: m['drive_id'] as String?,
    downloadedPath: m['downloaded_path'] as String?,
    isDownloaded: (m['is_downloaded'] as num?)?.toInt() == 1,
  );

  Track copyWith({
    String? uri,
    String? downloadedPath,
    bool? isDownloaded,
    bool? available,
    bool? favorite,
  }) => Track(
    id: id,
    uri: uri ?? this.uri,
    title: title,
    artist: artist,
    album: album,
    albumArtist: albumArtist,
    durationMs: durationMs,
    trackNumber: trackNumber,
    discNumber: discNumber,
    artPath: artPath,
    format: format,
    available: available ?? this.available,
    favorite: favorite ?? this.favorite,
    addedAt: addedAt,
    source: source,
    driveId: driveId,
    downloadedPath: downloadedPath ?? this.downloadedPath,
    isDownloaded: isDownloaded ?? this.isDownloaded,
  );
}

class MusicFolder {
  const MusicFolder(this.uri, this.name, this.error);
  final String uri, name;
  final String? error;
}

class Playlist {
  const Playlist(this.id, this.name, this.count);
  final int id, count;
  final String name;
}

class LibraryGroup {
  const LibraryGroup(this.name, this.artist, this.count, this.artPath);
  final String name, artist;
  final int count;
  final String? artPath;
}

enum SongSort { title, artist, album, added }

String timeLabel(int ms) {
  final seconds = ms ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}
