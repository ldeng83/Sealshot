// Plain-C ABI shim over the WebRTC Audio Processing Module (APM).
//
// The public interface intentionally exposes only C types so that it can be
// imported cleanly into Swift (no C++ in the module map). All audio is
// 16-bit signed interleaved PCM in 10 ms frames.
//
// Underlying library: webrtc-audio-processing (PulseAudio/freedesktop fork,
// v1.3, BSD-3-Clause). See lib/LICENSE-webrtc-audio-processing.txt.

#ifndef CWEBRTC_APM_H
#define CWEBRTC_APM_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle wrapping a webrtc::AudioProcessing instance.
typedef struct cwebrtc_apm cwebrtc_apm;

// Create an APM instance.
//   sample_rate : stream sample rate in Hz (e.g. 48000). Must be one of the
//                 rates APM accepts (8000/16000/32000/48000).
//   channels    : number of interleaved channels (1 = mono).
//   enable_ns   : enable noise suppression.
//   enable_agc  : enable automatic gain control (GainController1, fixed digital).
//   enable_aec  : enable the acoustic echo canceller (AEC3). Requires the
//                 caller to feed the render/reference stream via
//                 cwebrtc_apm_process_render and to set the stream delay.
// Note: when enable_ns or enable_aec is true, APM's internal high-pass filter
// is also engaged to remove low-frequency rumble. Callers should NOT apply a
// separate external high-pass in that case to avoid filtering twice.
// Returns NULL on failure (invalid args, unsupported sample rate, or
// allocation failure).
cwebrtc_apm *cwebrtc_apm_create(int sample_rate,
                                int channels,
                                bool enable_ns,
                                bool enable_agc,
                                bool enable_aec);

// Process one 10 ms capture (near-end / microphone) frame in place.
//   frame     : interleaved int16 PCM, modified in place.
//   frame_len : must equal sample_rate / 100 * channels.
// No-op if apm is NULL or frame_len is wrong.
void cwebrtc_apm_process_capture(cwebrtc_apm *apm, int16_t *frame, int frame_len);

// Process one 10 ms render (far-end / system audio reference) frame for AEC.
//   frame     : interleaved int16 PCM, read only.
//   frame_len : must equal sample_rate / 100 * channels.
// No-op if apm is NULL or frame_len is wrong.
void cwebrtc_apm_process_render(cwebrtc_apm *apm, const int16_t *frame, int frame_len);

// Set the estimated delay (ms) between a render frame being played and the
// corresponding echo arriving in a capture frame. Used by AEC.
void cwebrtc_apm_set_stream_delay_ms(cwebrtc_apm *apm, int delay_ms);

// Destroy the instance. Safe to call with NULL.
void cwebrtc_apm_destroy(cwebrtc_apm *apm);

#ifdef __cplusplus
}
#endif

#endif // CWEBRTC_APM_H
