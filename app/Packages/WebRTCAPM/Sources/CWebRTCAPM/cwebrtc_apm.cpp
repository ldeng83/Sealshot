// C++ shim bridging the plain-C ABI in cwebrtc_apm.h to webrtc::AudioProcessing.
//
// Underlying library: webrtc-audio-processing (PulseAudio/freedesktop fork,
// v1.3, BSD-3-Clause).

#include "include/cwebrtc_apm.h"

#include "modules/audio_processing/include/audio_processing.h"

#include <memory>
#include <vector>

// The APM Create() in this fork returns a raw, ref-counted AudioProcessing*.
// We hold it in a scoped_refptr so it is released exactly once on destroy.
struct cwebrtc_apm {
  rtc::scoped_refptr<webrtc::AudioProcessing> apm;
  webrtc::StreamConfig stream_config;  // capture (near-end) layout
  webrtc::StreamConfig render_config;  // render (far-end) layout
  int frame_len;                       // expected interleaved length per 10ms
  // Scratch destination for ProcessReverseStream, allocated once at create time
  // so the real-time render path (called every 10 ms) never heap-allocates.
  std::vector<int16_t> render_scratch;
};

cwebrtc_apm *cwebrtc_apm_create(int sample_rate,
                                int channels,
                                bool enable_ns,
                                bool enable_agc,
                                bool enable_aec) {
  if (channels <= 0) {
    return nullptr;
  }
  // APM only accepts a fixed set of rates; reject anything else so the Swift
  // init? fails early rather than feeding the APM an unsupported layout.
  if (sample_rate != 8000 && sample_rate != 16000 && sample_rate != 32000 &&
      sample_rate != 48000) {
    return nullptr;
  }

  // C++ exception firewall: an exception unwinding into the C ABI is undefined
  // behavior, so contain anything thrown by the library calls below.
  try {
    webrtc::AudioProcessing *raw = webrtc::AudioProcessingBuilder().Create();
    if (raw == nullptr) {
      return nullptr;
    }
    rtc::scoped_refptr<webrtc::AudioProcessing> apm(raw);

    webrtc::AudioProcessing::Config config;
    config.noise_suppression.enabled = enable_ns;
    config.noise_suppression.level =
        webrtc::AudioProcessing::Config::NoiseSuppression::kHigh;

    config.gain_controller1.enabled = enable_agc;
    config.gain_controller1.mode =
        webrtc::AudioProcessing::Config::GainController1::kFixedDigital;

    config.echo_canceller.enabled = enable_aec;

    // A high-pass filter is cheap and helps remove low-frequency rumble; enable
    // it whenever we are doing any cleanup so voice comes through clearer.
    config.high_pass_filter.enabled = enable_ns || enable_aec;

    apm->ApplyConfig(config);

    // Initialize internal state. The int16 ProcessStream overload derives the
    // actual rate/channel layout from the StreamConfig passed per frame, so the
    // no-argument Initialize is sufficient here.
    if (apm->Initialize() != webrtc::AudioProcessing::kNoError) {
      return nullptr;
    }

    auto *handle = new (std::nothrow) cwebrtc_apm();
    if (handle == nullptr) {
      return nullptr;
    }
    handle->apm = apm;
    handle->stream_config =
        webrtc::StreamConfig(sample_rate, static_cast<size_t>(channels));
    handle->render_config =
        webrtc::StreamConfig(sample_rate, static_cast<size_t>(channels));
    handle->frame_len = (sample_rate / 100) * channels;
    // Preallocate the render scratch buffer once (frame_len samples). Sizing it
    // here keeps the real-time render path allocation-free.
    handle->render_scratch.resize(static_cast<size_t>(handle->frame_len));
    return handle;
  } catch (...) {
    return nullptr;
  }
}

void cwebrtc_apm_process_capture(cwebrtc_apm *apm, int16_t *frame, int frame_len) {
  if (apm == nullptr || frame == nullptr || frame_len != apm->frame_len) {
    return;
  }
  try {
    apm->apm->ProcessStream(frame, apm->stream_config, apm->stream_config, frame);
  } catch (...) {
    // Contain any C++ exception at the C ABI boundary; treat as a no-op.
  }
}

void cwebrtc_apm_process_render(cwebrtc_apm *apm, const int16_t *frame, int frame_len) {
  if (apm == nullptr || frame == nullptr || frame_len != apm->frame_len) {
    return;
  }
  // ProcessReverseStream writes to dest; for a pure reference we discard the
  // output but must supply a valid destination buffer of the same size. The
  // scratch buffer was allocated once at create time (no per-frame alloc).
  try {
    apm->apm->ProcessReverseStream(frame, apm->render_config,
                                   apm->render_config,
                                   apm->render_scratch.data());
  } catch (...) {
    // Contain any C++ exception at the C ABI boundary; treat as a no-op.
  }
}

void cwebrtc_apm_set_stream_delay_ms(cwebrtc_apm *apm, int delay_ms) {
  if (apm == nullptr) {
    return;
  }
  try {
    apm->apm->set_stream_delay_ms(delay_ms);
  } catch (...) {
    // Contain any C++ exception at the C ABI boundary; treat as a no-op.
  }
}

void cwebrtc_apm_destroy(cwebrtc_apm *apm) {
  delete apm;  // scoped_refptr releases the APM
}
