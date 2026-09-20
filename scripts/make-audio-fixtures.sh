#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p test-output/fixtures/Evening
for format in mp3 flac wav ogg opus m4a aac; do
  case "$format" in
    mp3) codec=libmp3lame ;;
    flac) codec=flac ;;
    wav) codec=pcm_s16le ;;
    ogg) codec=vorbis ;;
    opus) codec=libopus ;;
    m4a|aac) codec=aac ;;
  esac
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'sine=frequency=440:duration=45' \
    -af 'volume=0.08' -ac 2 -c:a "$codec" -strict -2 -metadata title="Evening Signal · $format" \
    -metadata artist='LocalBeat Sessions' -metadata album='After Hours' -metadata track=1 \
    "test-output/fixtures/Evening/Evening Signal.$format"
done
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'sine=frequency=330:duration=45' \
  -af 'volume=0.08' -c:a libmp3lame -metadata title='Quiet City' -metadata artist='LocalBeat Sessions' \
  -metadata album='After Hours' -metadata track=2 'test-output/fixtures/Evening/Quiet City.mp3'
echo 'Synthetic audio fixtures are ready in test-output/fixtures.'
