# Vision OCR cost benchmark

Settles how the cost of Sealshot's OCR pipeline is structured, so performance
work targets the right thing.

## Why this exists

`TextRecognizer` issues **many small Vision requests per capture**: one per
image tile, plus **2 per low-confidence line** in the refine pass
(`refineLowConfidenceLines` → `reocrLine`, capped at `refineMaxLines = 40`).
That is up to **80 extra requests** for a single screenshot.

On an Intel Mac captures were taking 15–37s. The initial theory was that
`.accurate` recognition is slow on Intel because it has no Neural Engine. That
theory was **wrong in an important way** — see the results below.

## Running it

```
scripts/ocr-bench/run.sh
```

Takes 2–4 minutes. Don't use the machine while it runs. `run.sh` always
compiles with `-O`, because an unoptimized run is not comparable.

Optionally pass your own image (must be ≥1600x900); it defaults to
`poc/fixtures/stripe-or-billing.png` so every machine measures identical input.

**On Apple Silicon, check the `arch` line says `arm64`.** If the script warns
about Rosetta, the numbers are meaningless — rebuild natively.

## What each experiment establishes

| | Question |
|---|---|
| **A** | Is there a fixed per-request floor, and is it *model inference* or *plumbing*? A blank image has nothing to recognize, so whatever it costs is the price of asking. If `.accurate` and `.fast` differ on a blank image, the floor is the model — which is what a Neural Engine accelerates. |
| **B** | **The decisive one.** Same pixels, same content, only the request *count* varies. Separates "cost of requests" from "cost of pixels". |
| **C** | How cost scales with submitted pixels, at native resolution. |
| **D** | Whether any production request setting is pathological (a free win). |
| **E** | Thermal-drift canary — proves throttling isn't faking the results. |

Trials are shuffled with a fixed seed, every point is repeated and reported as
a median, and Vision is warmed up first, so model load is never timed.

## Baseline: Intel (2026-08-08)

MacBook Pro, Core i9-9880H, 16 logical cores, macOS 15.7.2:

```
  .accurate floor (blank 80x24)     : 96.2ms
  .fast floor (blank 80x24)         : 9.1ms
  floor ratio accurate/fast         : 10.5x
  cost per extra request (8->16)    : 120ms
  16 requests vs 1, same pixels     : 3.47x
  full 1600x900 .accurate           : 844ms
  thermal drift over run            : 1.06x
  projected 80-request refine cost  : 9.6s
```

Findings:

- **Cost is dominated by a fixed per-request floor.** 16 requests cost
  **3.47x** one request *for identical pixels and content*. The 8→16 step is
  the cleanest read — both find the same 56 lines, so the extra 960ms is
  almost purely the cost of 8 more requests: **~120ms each**.
- **The floor is model inference, not plumbing.** A blank 80x24 image — 24
  pixels tall, nothing to read — still costs 96ms in `.accurate` but only 9ms
  in `.fast`. Same setup code, same image, **10.5x apart**. This is why the
  Neural Engine is expected to matter.
- **Pixels matter far less than requests.** 750x the pixels (1,920 →
  1,440,000) costs only ~9x the time.
- **`minimumTextHeight` is innocent.** Production's 0.008 and Vision's default
  time identically. A prior hypothesis, now dead.
- **`automaticallyDetectsLanguage = false` is ~17% faster** with identical
  output on an English fixture. Not free: the flag exists to stop non-Latin
  scripts being force-read as Latin (see the comment in `recognizeLines`).
- **Throttling is not a factor** — 1.06x drift across 85 samples.

## Why Apple Silicon needs measuring too

The request count is a property of *the code*, not the chip — Apple Silicon
issues the same 80 refine requests. So it is very unlikely to be immune; it
most likely just has a much smaller floor. If the floor there is ~15ms, the
refine pass still silently costs **~1.2s per capture** on every Mac.

That distinction decides the fix: if Apple Silicon also pays a visible cost,
trimming the refine pass is a straight win everywhere and should NOT be gated
behind an architecture check.

## Apple Silicon result

Apple M4, 10 logical cores, macOS 26.5.1 (2026-08-08):

```
  arch                              : arm64 (Apple Silicon)
  cpu                               : Apple M4
  .accurate floor (blank 80x24)     : 9.0ms
  .fast floor (blank 80x24)         : 2.8ms
  floor ratio accurate/fast         : 3.2x
  cost per extra request (8->16)    : 14ms
  16 requests vs 1, same pixels     : 2.58x
  full 1600x900 .accurate           : 116ms
  thermal drift over run            : 1.08x

  >>> Sealshot's refine pass issues up to 80 requests per capture.
  >>> Projected refine-pass cost here: 1.1s
```

The prediction above held: Apple Silicon is not immune, just cheaper. The
per-request floor shrinks from ~120ms to **~14ms**, but 16 requests still cost
**2.58x** one request for identical pixels — so the 80-request refine pass
still silently costs **~1.1s per capture** on an M4. Trimming the request
count is a win on both architectures and should NOT be architecture-gated.
Thermal drift was 1.08x (valid run, below the ~1.15x threshold).
