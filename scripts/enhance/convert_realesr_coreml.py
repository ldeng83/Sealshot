"""Convert realesr-general-x4v3 (.pth) to a Core ML .mlpackage.

Contract (relied on by the Sealshot app, Plan B):
  input  "image" : RGB image, fixed 256x256
  output "output": RGB image, fixed 1024x1024 (4x), values already in 0..255
Run: python scripts/enhance/convert_realesr_coreml.py
"""
import numpy as np
import torch
from torch import nn
from torch.nn import functional as F
import coremltools as ct

WEIGHTS = "scripts/enhance/weights/realesr-general-x4v3.pth"
OUT = "scripts/enhance/out/RealESRGeneralX4V3.mlpackage"
TILE = 256
UPSCALE = 4


class SRVGGNetCompact(nn.Module):
    """Architecture used by realesr-general-x4v3 (num_conv=32, prelu)."""
    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=32, upscale=4):
        super().__init__()
        self.upscale = upscale
        self.body = nn.ModuleList()
        self.body.append(nn.Conv2d(num_in_ch, num_feat, 3, 1, 1))
        self.body.append(nn.PReLU(num_parameters=num_feat))
        for _ in range(num_conv):
            self.body.append(nn.Conv2d(num_feat, num_feat, 3, 1, 1))
            self.body.append(nn.PReLU(num_parameters=num_feat))
        self.body.append(nn.Conv2d(num_feat, num_out_ch * upscale * upscale, 3, 1, 1))
        self.upsampler = nn.PixelShuffle(upscale)

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        out = self.upsampler(out)
        out += F.interpolate(x, scale_factor=self.upscale, mode='nearest')
        return out


class Wrapped(nn.Module):
    """Core ML feeds 0..1 (ImageType scale=1/255); emit 0..255 for an image output."""
    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, x):
        return torch.clamp(self.net(x), 0.0, 1.0) * 255.0


def main():
    net = SRVGGNetCompact()
    # weights_only=True: the .pth is a pure tensor state dict; this refuses to
    # unpickle arbitrary Python objects (avoids code execution on load).
    loadnet = torch.load(WEIGHTS, map_location="cpu", weights_only=True)
    key = "params" if "params" in loadnet else "params_ema"
    net.load_state_dict(loadnet[key], strict=True)
    net.eval()
    model = Wrapped(net).eval()

    example = torch.rand(1, 3, TILE, TILE)
    traced = torch.jit.trace(model, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, TILE, TILE),
                             scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name="output", color_layout=ct.colorlayout.RGB)],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )
    mlmodel.short_description = "realesr-general-x4v3 4x super-resolution (256->1024)"
    import os
    os.makedirs("scripts/enhance/out", exist_ok=True)
    mlmodel.save(OUT)
    print("saved", OUT)


if __name__ == "__main__":
    main()
