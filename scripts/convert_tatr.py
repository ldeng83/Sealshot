# scripts/convert_tatr.py  — run in a throwaway venv:
#   python3 -m venv /tmp/tatrconv && source /tmp/tatrconv/bin/activate
#   pip install torch transformers coremltools pillow timm==1.0.27
#   (timm is required by TATR's ResNet-18 backbone; conversion fails without it)
#
# Converts microsoft/table-transformer-detection to FP16 Core ML with
# ImageNet normalization baked into a ct.ImageType input.
import torch
import coremltools as ct
from transformers import TableTransformerForObjectDetection

W, H = 800, 1000  # fixed letterbox target (matches the validated spike)

print("Loading model from HuggingFace...")
model = TableTransformerForObjectDetection.from_pretrained(
    "microsoft/table-transformer-detection").eval()

class Wrap(torch.nn.Module):
    def __init__(self, m): super().__init__(); self.m = m
    def forward(self, x):
        out = self.m(pixel_values=x)
        return out.logits, out.pred_boxes   # (1,Q,C), (1,Q,4)

print("Tracing model...")
example = torch.rand(1, 3, H, W)
traced = torch.jit.trace(Wrap(model), example)

# ImageNet normalization baked into the image input:
# normalized = (pixel/255 - mean) / std  →  scale=1/(255*std), bias=-mean/std
std  = [0.229, 0.224, 0.225]
mean = [0.485, 0.456, 0.406]
# LOSSY APPROXIMATION: ct.ImageType supports only a SCALAR scale, so we apply
# channel-0's std (0.229) to all three channels. G/B are off by ~2% from exact
# per-channel normalization. This is a leading suspect for lower-than-spike
# detection confidence — for exact normalization, bake it as an explicit op in
# the traced torch model (feed raw 0-255, subtract mean / divide per-channel std
# inside the graph) instead of relying on ImageType's scalar scale.
scale = 1.0 / (255.0 * std[0])  # scalar (lossy on G/B); per-channel bias below
image_input = ct.ImageType(
    name="pixel_values", shape=(1, 3, H, W),
    scale=scale,
    bias=[-mean[0]/std[0], -mean[1]/std[1], -mean[2]/std[2]],
    color_layout=ct.colorlayout.RGB,
)

print("Converting to Core ML FP16...")
mlmodel = ct.convert(
    traced, inputs=[image_input],
    outputs=[ct.TensorType(name="logits"), ct.TensorType(name="pred_boxes")],
    minimum_deployment_target=ct.target.macOS14,
    compute_precision=ct.precision.FLOAT16,
    convert_to="mlprogram",
)

output_path = "app/Resources/Models/TATRDetection.mlpackage"
print(f"Saving to {output_path} ...")
mlmodel.save(output_path)

print("\n=== Model Spec (record these values into TATRModelContract.swift) ===")
print(mlmodel)
print("=== Done ===")
