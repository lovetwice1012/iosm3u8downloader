#ifndef HLS_FFMPEG_BRIDGE_H
#define HLS_FFMPEG_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *HLSFFmpegRemuxSessionHandle;

#define HLS_FFMPEG_SAMPLE_AES_OUTPUT_MP4 0
#define HLS_FFMPEG_SAMPLE_AES_OUTPUT_WAV_PCM_S16LE 1
#define HLS_FFMPEG_PROBE_INPUT_MEDIA_FILE 0
#define HLS_FFMPEG_PROBE_INPUT_SAMPLE_AES_PLAYLIST 1
#define HLS_FFMPEG_TRACK_AUDIO 1
#define HLS_FFMPEG_TRACK_VIDEO 2

HLSFFmpegRemuxSessionHandle hls_ffmpeg_remux_session_create(
    const char *input_path,
    const char *audio_input_path,
    const char *output_path,
    int64_t maximum_output_bytes
);

HLSFFmpegRemuxSessionHandle hls_ffmpeg_cenc_session_create(
    const char *video_input_path,
    const char *video_decryption_key_hex,
    const char *audio_input_path,
    const char *audio_decryption_key_hex,
    const char *output_path,
    int64_t maximum_output_bytes
);

// Decrypts identity SAMPLE-AES from an app-generated, local-only HLS
// playlist.  Keys remain in protected files referenced by the playlist and
// are never added to FFmpeg's argv/session history.
HLSFFmpegRemuxSessionHandle hls_ffmpeg_sample_aes_session_create(
    const char *primary_playlist_path,
    const char *audio_playlist_path,
    const char *output_path,
    int32_t output_mode,
    int64_t maximum_output_bytes
);

// Converts a local audio input to signed 16-bit little-endian PCM WAV.  The
// optional key is for a directly opened CENC/CBCS input (for example a
// Widevine audio-only fMP4); pass NULL for clear/AES-128-decrypted inputs.
HLSFFmpegRemuxSessionHandle hls_ffmpeg_audio_wav_session_create(
    const char *input_path,
    const char *decryption_key_hex,
    const char *output_path,
    int64_t maximum_output_bytes
);

// Probes actual decrypted streams.  The result is a bitwise combination of
// HLS_FFMPEG_TRACK_AUDIO and HLS_FFMPEG_TRACK_VIDEO; -1 indicates failure.
HLSFFmpegRemuxSessionHandle hls_ffmpeg_media_probe_session_create(
    const char *input_path,
    const char *decryption_key_hex,
    int32_t input_kind
);

// Fully decodes the first video and audio streams from an already-clear local
// media file into FFmpeg's null muxer.  Any demux/decode error is fatal; this
// validates media samples rather than merely trusting container metadata.
HLSFFmpegRemuxSessionHandle hls_ffmpeg_decode_validation_session_create(
    const char *input_path
);

int32_t hls_ffmpeg_media_probe_session_execute(
    HLSFFmpegRemuxSessionHandle session,
    char *diagnostic_buffer,
    size_t diagnostic_buffer_size
);

// Registers a value that must be removed from failure diagnostics.  The value
// is not passed to FFmpeg.  Call this before session execution.
int32_t hls_ffmpeg_remux_session_add_diagnostic_secret(
    HLSFFmpegRemuxSessionHandle session,
    const char *secret
);

int64_t hls_ffmpeg_remux_session_execute(
    HLSFFmpegRemuxSessionHandle session,
    char *diagnostic_buffer,
    size_t diagnostic_buffer_size
);

void hls_ffmpeg_remux_session_cancel(HLSFFmpegRemuxSessionHandle session);
void hls_ffmpeg_remux_session_destroy(HLSFFmpegRemuxSessionHandle session);

#ifdef __cplusplus
}
#endif

#endif
