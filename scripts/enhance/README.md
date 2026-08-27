# Real-ESRGAN → Core ML conversion

Produces `RealESRGeneralX4V3.mlpackage` for the in-app low-res enhancer.

## Run
    python3 -m venv /tmp/realesr-convert && source /tmp/realesr-convert/bin/activate
    pip install -r scripts/enhance/requirements.txt
    curl -L -o scripts/enhance/weights/realesr-general-x4v3.pth \
      https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth
    python scripts/enhance/convert_realesr_coreml.py      # -> scripts/enhance/out/RealESRGeneralX4V3.mlpackage
    python scripts/enhance/validate_quality.py            # -> out/*_enhanced2x.png to eyeball

## Model I/O contract (consumed by ImageEnhancer, Plan B)
- input  `image` : RGB image, fixed 256x256
- output `output`: RGB image, 1024x1024 (4x), 0..255
- License: Real-ESRGAN is BSD-3-Clause; weights from the official v0.2.5.0 release.
