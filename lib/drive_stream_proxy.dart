import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'drive_service.dart';

/// Embedded local HTTP streaming proxy for just_audio.
/// Handles Google Drive Bearer token injection, HTTP Range requests for scrubbing,
/// and provides an automatic LRU disk cache (up to 250MB) to minimize mobile data usage.
class DriveStreamProxy {
  DriveStreamProxy({required this.driveService, this._cacheDir});
  final DriveService driveService;

  HttpServer? _server;
  int get port => _server?.port ?? 0;
  Directory? _cacheDir;

  static const int maxCacheBytes = 250 * 1024 * 1024; // 250 MB

  Future<void> start() async {
    if (_server != null) return;
    if (_cacheDir == null) {
      final appDir = await getTemporaryDirectory();
      _cacheDir = Directory('${appDir.path}/localbeat_stream_cache');
    }
    if (!_cacheDir!.existsSync()) {
      _cacheDir!.createSync(recursive: true);
    }

    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    debugPrint('DriveStreamProxy listening on http://127.0.0.1:${_server!.port}');

    _server!.listen(_handleRequest, onError: (e) {
      debugPrint('DriveStreamProxy server error: $e');
    });
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  String urlFor(String driveId) {
    return 'http://127.0.0.1:$port/stream/$driveId';
  }

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      final pathSegments = req.uri.pathSegments;
      if (pathSegments.length < 2 || pathSegments[0] != 'stream') {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }

      final fileId = pathSegments[1];
      final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);

      // Check if we have a complete local cached copy
      final cachedFile = File('${_cacheDir!.path}/$fileId.bin');
      if (cachedFile.existsSync() && cachedFile.lengthSync() > 0) {
        await _serveLocalFile(req, cachedFile, rangeHeader);
        return;
      }

      // If in mock mode or mock track, generate a valid audio stream
      if (driveService.isMock || fileId.startsWith('mock_')) {
        await _serveMockAudio(req, fileId, rangeHeader);
        return;
      }

      // Otherwise stream from Google Drive with fresh Bearer token
      final forwardHeaders = <String, String>{};
      if (rangeHeader != null) {
        forwardHeaders[HttpHeaders.rangeHeader] = rangeHeader;
      }

      final driveRes = await driveService.getMediaStream(fileId, headers: forwardHeaders);

      req.response.statusCode = driveRes.statusCode;
      driveRes.headers.forEach((key, value) {
        // Forward content-length, content-range, content-type, accept-ranges
        final lk = key.toLowerCase();
        if (lk == 'content-length' ||
            lk == 'content-range' ||
            lk == 'content-type' ||
            lk == 'accept-ranges') {
          req.response.headers.set(key, value);
        }
      });
      req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

      // Forward stream to player and optionally cache if streaming from beginning
      final isFullStream = rangeHeader == null || rangeHeader.startsWith('bytes=0-');
      IOSink? cacheSink;
      if (isFullStream && driveRes.statusCode == HttpStatus.ok) {
        _enforceCacheLimit();
        cacheSink = cachedFile.openWrite();
      }

      await driveRes.stream.listen(
        (chunk) {
          req.response.add(chunk);
          cacheSink?.add(chunk);
        },
        onError: (e) {
          debugPrint('Stream forwarding error: $e');
        },
        cancelOnError: true,
      ).asFuture();

      await cacheSink?.flush();
      await cacheSink?.close();
      await req.response.close();
    } catch (e) {
      debugPrint('Proxy request handler error: $e');
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _serveLocalFile(HttpRequest req, File file, String? rangeHeader) async {
    final totalLength = file.lengthSync();
    req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    req.response.headers.set(HttpHeaders.contentTypeHeader, 'audio/mpeg');

    if (rangeHeader == null) {
      req.response.statusCode = HttpStatus.ok;
      req.response.headers.set(HttpHeaders.contentLengthHeader, totalLength);
      await req.response.addStream(file.openRead());
    } else {
      final range = _parseRange(rangeHeader, totalLength);
      if (range == null) {
        req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$totalLength');
        await req.response.close();
        return;
      }
      final start = range[0];
      final end = range[1];
      final chunkLen = end - start + 1;

      req.response.statusCode = HttpStatus.partialContent;
      req.response.headers.set(HttpHeaders.contentLengthHeader, chunkLen);
      req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$totalLength');
      await req.response.addStream(file.openRead(start, end + 1));
    }
    await req.response.close();
  }

  Future<void> _serveMockAudio(HttpRequest req, String fileId, String? rangeHeader) async {
    // Generate 45 seconds of mock synthetic audio bytes (WAV/MP3 header + sine samples)
    final syntheticData = _generateMockAudioBytes();
    final totalLength = syntheticData.length;

    req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    req.response.headers.set(HttpHeaders.contentTypeHeader, 'audio/wav');

    if (rangeHeader == null) {
      req.response.statusCode = HttpStatus.ok;
      req.response.headers.set(HttpHeaders.contentLengthHeader, totalLength);
      req.response.add(syntheticData);
    } else {
      final range = _parseRange(rangeHeader, totalLength);
      if (range == null) {
        req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$totalLength');
        await req.response.close();
        return;
      }
      final start = range[0];
      final end = range[1];
      final chunkLen = end - start + 1;

      req.response.statusCode = HttpStatus.partialContent;
      req.response.headers.set(HttpHeaders.contentLengthHeader, chunkLen);
      req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$totalLength');
      req.response.add(syntheticData.sublist(start, end + 1));
    }
    await req.response.close();
  }

  List<int>? _parseRange(String header, int totalLength) {
    if (!header.startsWith('bytes=')) return null;
    final parts = header.substring(6).split('-');
    if (parts.length != 2) return null;

    int start = int.tryParse(parts[0]) ?? 0;
    int end = parts[1].isNotEmpty ? (int.tryParse(parts[1]) ?? totalLength - 1) : totalLength - 1;

    if (start >= totalLength) return null;
    if (end >= totalLength) end = totalLength - 1;
    if (start > end) return null;

    return [start, end];
  }

  Uint8List _generateMockAudioBytes() {
    // 5 seconds of 44.1kHz 16-bit mono PCM WAV
    const sampleRate = 44100;
    const durationSec = 10;
    const numSamples = sampleRate * durationSec;
    const byteRate = sampleRate * 2;
    const dataSize = numSamples * 2;
    final totalSize = 36 + dataSize;

    final buffer = ByteData(44 + dataSize);
    // RIFF header
    buffer.setUint8(0, 0x52); // R
    buffer.setUint8(1, 0x49); // I
    buffer.setUint8(2, 0x46); // F
    buffer.setUint8(3, 0x46); // F
    buffer.setUint32(4, totalSize, Endian.little);
    buffer.setUint8(8, 0x57);  // W
    buffer.setUint8(9, 0x41);  // A
    buffer.setUint8(10, 0x56); // V
    buffer.setUint8(11, 0x45); // E
    // fmt subchunk
    buffer.setUint8(12, 0x66); // f
    buffer.setUint8(13, 0x6D); // m
    buffer.setUint8(14, 0x74); // t
    buffer.setUint8(15, 0x20); // ' '
    buffer.setUint32(16, 16, Endian.little); // subchunk size
    buffer.setUint16(20, 1, Endian.little);  // PCM format
    buffer.setUint16(22, 1, Endian.little);  // 1 channel (mono)
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, byteRate, Endian.little);
    buffer.setUint16(32, 2, Endian.little); // block align
    buffer.setUint16(34, 16, Endian.little); // bits per sample
    // data subchunk
    buffer.setUint8(36, 0x64); // d
    buffer.setUint8(37, 0x61); // a
    buffer.setUint8(38, 0x74); // t
    buffer.setUint8(39, 0x61); // a
    buffer.setUint32(40, dataSize, Endian.little);

    // Audio samples (gentle 440Hz sine wave)
    for (var i = 0; i < numSamples; i++) {
      final sample = (32767 * 0.15 * (i % 100 < 50 ? 1 : -1)).toInt();
      buffer.setInt16(44 + i * 2, sample, Endian.little);
    }
    return buffer.buffer.asUint8List();
  }

  Future<int> getCacheSizeBytes() async {
    if (_cacheDir == null || !_cacheDir!.existsSync()) return 0;
    var size = 0;
    for (final entity in _cacheDir!.listSync(recursive: true)) {
      if (entity is File) {
        size += entity.lengthSync();
      }
    }
    return size;
  }

  Future<void> clearCache() async {
    if (_cacheDir != null && _cacheDir!.existsSync()) {
      for (final entity in _cacheDir!.listSync()) {
        try {
          entity.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  }

  void _enforceCacheLimit() {
    if (_cacheDir == null || !_cacheDir!.existsSync()) return;
    try {
      final files = _cacheDir!.listSync().whereType<File>().toList();
      var total = files.fold<int>(0, (sum, f) => sum + f.lengthSync());
      if (total > maxCacheBytes) {
        // Sort by last modified ascending (LRU)
        files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
        for (final f in files) {
          total -= f.lengthSync();
          f.deleteSync();
          if (total <= maxCacheBytes * 0.75) break;
        }
      }
    } catch (_) {}
  }
}
