# MPEG-TS fixtures

These tiny fixtures were generated with FFmpeg 8.1 from synthetic video and
audio sources. They contain no third-party media.

```sh
ffmpeg -f lavfi -i "testsrc2=size=320x180:rate=24:duration=1.5" \
  -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=1.5" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 96k sample-h264-aac.ts

ffmpeg -f lavfi -i "testsrc2=size=160x90:rate=24:duration=3" \
  -vf "setpts=PTS+10/TB" -c:v libx264 -pix_fmt yuv420p \
  -mpegts_copyts 1 -muxdelay 0 sample-h264-video-offset.ts

ffmpeg -f lavfi -i "sine=frequency=1000:sample_rate=48000:duration=2" \
  -af "asetpts=PTS+11/TB" -c:a aac -b:a 96k \
  -mpegts_copyts 1 -muxdelay 0 sample-aac-audio-offset.ts
```
