# WebRTCAPM

Local SwiftPM package that wraps the **WebRTC Audio Processing Module (APM)** —
noise suppression, automatic gain control, and acoustic echo cancellation — and
exposes it to Swift through a **plain-C ABI shim** (no C++ in the public
interface).

## Which path worked

The **prebuilt universal static library** fallback (per the spike decision gate).
Vendoring the full APM C++ source tree as raw SwiftPM sources is impractical
(meson/ninja build system, bundled abseil subproject, platform code), so we:

1. Build the upstream library with its own meson/ninja build, once per arch.
2. Merge all resulting `.a` files (APM + its internal modules + abseil) into one
   archive per arch with `libtool -static`.
3. `lipo` the two arches into a single universal `.a`.
4. Wrap that in an `.xcframework` and reference it via a SwiftPM `binaryTarget`.

A `binaryTarget` `.xcframework` (rather than raw `-L`/`-l` linker flags) is used
because relative library search paths do not resolve consistently between
`swift build` (cwd = package root) and an Xcode/xcodegen app build (cwd = app
root). The xcframework path is resolved by SwiftPM in both contexts.

## Upstream version & license

- **Library:** `webrtc-audio-processing` — the PulseAudio / freedesktop fork.
- **Version:** `v1.3` (tarball:
  `https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing/-/archive/v1.3/webrtc-audio-processing-v1.3.tar.gz`).
- **License:** BSD-3-Clause (Google copyright). MAS-compatible. Copy committed at
  `Frameworks/LICENSE-webrtc-audio-processing.txt`.
- **Bundled dependency:** abseil-cpp `20230125.1`, fetched by meson as a wrap
  subproject and statically merged into the archive (also BSD-licensed). No
  external/Homebrew abseil and **no runtime dylib dependency** — everything is
  inside the committed `.a`.

## How the static lib was produced (reproducible)

Requires `meson`, `ninja`, and Xcode command-line tools (`brew install meson ninja`).

```sh
# 1. Fetch + extract
curl -sL "https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing/-/archive/v1.3/webrtc-audio-processing-v1.3.tar.gz" -o src.tar.gz
tar xzf src.tar.gz && cd webrtc-audio-processing-v1.3
export MACOSX_DEPLOYMENT_TARGET=14.0

# 2a. Native arm64 build
meson setup builddir-arm64 --default-library=static --buildtype=release \
  -Dc_args="-arch arm64 -mmacosx-version-min=14.0" \
  -Dcpp_args="-arch arm64 -mmacosx-version-min=14.0" \
  -Dc_link_args="-arch arm64" -Dcpp_link_args="-arch arm64"
ninja -C builddir-arm64

# 2b. Cross x86_64 build (cross file selecting clang -arch x86_64; see below)
meson setup builddir-x86 --default-library=static --buildtype=release \
  -Dc_args="-arch x86_64 -mmacosx-version-min=14.0" \
  -Dcpp_args="-arch x86_64 -mmacosx-version-min=14.0" \
  -Dc_link_args="-arch x86_64" -Dcpp_link_args="-arch x86_64" \
  --cross-file=x86.ini
ninja -C builddir-x86

# 3. Merge each arch's many .a files into one, then lipo.
#    IMPORTANT: use `find ... -name '*.a'` to collect EVERY archive ninja
#    produced and merge them ALL. On x86_64 meson splits the SIMD kernels into
#    separate "convenience" static libraries built with -msse2 / -mavx2 -mfma
#    (libcommon_audio_sse2.a, libcommon_audio_avx.a,
#    libwebrtc_audio_processing_privatearch.a). These hold the definitions for
#    FIRFilterSSE2/AVX2, SincResampler::Convolve_SSE/AVX2, the ooura
#    cft*/rft*_128_SSE2 kernels, and the aec3 *_Avx2 / SqrtAVX2 kernels.
#    If you cherry-pick a subset (e.g. only the main libwebrtc-audio-processing-1.a
#    + abseil) those convenience libs are dropped and a Release UNIVERSAL build
#    fails to link x86_64 with "Undefined symbols ... FIRFilterSSE2 / Convolve_SSE
#    / cft1st_128_SSE2 / SqrtAVX2 / ...". (A Debug build with ONLY_ACTIVE_ARCH=YES
#    only links arm64 and silently hides this — always link-test x86_64.)
#    On arm64 the NEON kernels are compiled directly into libcommon_audio.a (no
#    separate convenience lib), so the same `find | libtool` covers it.
#    Verify after merging:
#      nm -arch x86_64 libwebrtc-audio-processing.a \
#        | grep -E "FIRFilterSSE2|Convolve_SSE|cft1st_128_SSE2|SqrtAVX2" | grep " T "
#    must show T (defined), not only U.
libtool -static -o libapm-arm64.a $(find builddir-arm64 -name '*.a')
libtool -static -o libapm-x86.a   $(find builddir-x86   -name '*.a')
lipo -create libapm-arm64.a libapm-x86.a -output libwebrtc-audio-processing.a

# 4. Wrap as an xcframework
xcodebuild -create-xcframework \
  -library libwebrtc-audio-processing.a \
  -output WebRTCAPM.xcframework
```

`x86.ini` (meson cross file):

```ini
[binaries]
c = ['clang', '-arch', 'x86_64']
cpp = ['clang++', '-arch', 'x86_64']
ar = 'ar'
strip = 'strip'

[host_machine]
system = 'darwin'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
```

The resulting `WebRTCAPM.xcframework` (≈18 MB universal `.a`) is committed at
`Frameworks/WebRTCAPM.xcframework`.

## Package layout

- `Sources/CWebRTCAPM/include/cwebrtc_apm.h` — public plain-C ABI (opaque handle).
- `Sources/CWebRTCAPM/cwebrtc_apm.cpp` — C++ shim bridging to `webrtc::AudioProcessing`.
- `Sources/CWebRTCAPM/vendor/` — webrtc + abseil **headers only** (needed to
  compile the shim; reached via an explicit `-I`, not re-exported to Swift).
- `Sources/WebRTCAPM/WebRTCAPM.swift` — `public final class WebRTCAPM`.
- `Frameworks/WebRTCAPM.xcframework` — the prebuilt universal static lib.

## API

```swift
let apm = WebRTCAPM(sampleRate: 48000, channels: 1,
                    noiseSuppression: true, gainControl: false,
                    echoCancellation: false)
// apm.frameLength == 480 (10 ms @ 48 kHz mono)
var frame: [Int16] = ...           // exactly frameLength samples
apm.processCapture(&frame)         // near-end / mic, in place
apm.processRender(referenceFrame)  // far-end / system audio (for AEC)
apm.setStreamDelay(ms: 50)         // for AEC
```

## Tests

`swift test` runs a deterministic noise-suppression smoke test: 48 kHz mono,
NS on, ~20 frames of LCG-seeded white noise through `processCapture`; output
energy must be well below input energy (observed ratio ≈ 0.04).
