#!/usr/bin/env python3
"""Export OpenCLIP ViT-B/32 (MIT) as drop-in replacements for the MobileCLIP .mlpackages.

Produces both encoders in exactly the contract EmbedStage already speaks — input names `image` /
`text`, output `final_emb_1`, L2-normalised — so the Swift side needs only new resource names, a
new image side, and a new modelID.

The tokenizer needs no change at all: laion's B/32 uses the same CLIP BPE vocabulary OpenPhoto
already ships (49408 tokens, BOS 49406, EOS 49407, 77-token context).

One real mismatch to bridge: transformers pads with EOS, while OpenPhoto's CLIPTokenizer
zero-pads. The exported graph therefore builds its attention mask from `ids != 0` and pools at the
EOS position, so it is correct for the ids Swift actually sends. That is verified numerically
against the PyTorch reference at the end of this script rather than assumed — a text encoder that
is subtly wrong would degrade search silently.

    ./.venv/bin/python export_app_model.py
"""

import pathlib

import numpy as np
import torch
import coremltools as ct
from transformers import AutoModel, AutoProcessor

HF = "laion/CLIP-ViT-B-32-laion2B-s34B-b79K"
SIDE = 224
CONTEXT = 77
OUT = pathlib.Path(__file__).parent / "app-models"
OUT.mkdir(exist_ok=True)

print(f"loading {HF} …")
model = AutoModel.from_pretrained(HF, attn_implementation="eager").eval()
proc = AutoProcessor.from_pretrained(HF)
MEAN, STD = proc.image_processor.image_mean, proc.image_processor.image_std


def _vec(out):
    return out if isinstance(out, torch.Tensor) else out.pooler_output


class ImageEncoder(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m
        # Core ML's ImageType allows only a scalar scale with per-channel bias, but CLIP's std is
        # per-channel — so normalisation happens here, inside the graph, still on the ANE.
        self.register_buffer("mean", torch.tensor(MEAN, dtype=torch.float32).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(STD, dtype=torch.float32).view(1, 3, 1, 1))

    def forward(self, image):
        x = (image - self.mean) / self.std
        f = _vec(self.m.get_image_features(pixel_values=x))
        return f / f.norm(dim=-1, keepdim=True)


class TextEncoder(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, text):
        ids = text.long()
        # No attention_mask on purpose. CLIP's text transformer is causal, so the EOS-position
        # output — the only position pooled — cannot attend to anything after it, which is exactly
        # where OpenPhoto's zero padding lives. Passing a mask would be a no-op numerically and
        # drags in a `new_ones` op coremltools cannot lower. Verified below against PyTorch.
        f = _vec(self.m.get_text_features(input_ids=ids))
        return f / f.norm(dim=-1, keepdim=True)


def export_image():
    w = ImageEncoder(model).eval()
    ex = torch.rand(1, 3, SIDE, SIDE)
    with torch.no_grad():
        traced = torch.jit.trace(w, ex)
    ml = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, SIDE, SIDE),
                             scale=1.0 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="final_emb_1")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
    )
    p = OUT / "openclip_b32_image.mlpackage"
    ml.save(str(p))
    print("wrote", p.name)
    return ml, w


def export_text():
    w = TextEncoder(model).eval()
    ex = torch.zeros(1, CONTEXT, dtype=torch.int32)
    ex[0, 0], ex[0, 1], ex[0, 2] = 49406, 320, 49407
    with torch.no_grad():
        traced = torch.jit.trace(w, ex)
    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name="text", shape=(1, CONTEXT), dtype=np.int32)],
        outputs=[ct.TensorType(name="final_emb_1")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
    )
    p = OUT / "openclip_b32_text.mlpackage"
    ml.save(str(p))
    print("wrote", p.name)
    return ml, w


def zero_padded_ids(text):
    """Reproduce OpenPhoto's CLIPTokenizer output: BOS … EOS then zeros."""
    core = proc.tokenizer(text, add_special_tokens=True)["input_ids"]
    core = core[:CONTEXT]
    return np.array([core + [0] * (CONTEXT - len(core))], dtype=np.int32)


def verify(img_ml, img_pt, txt_ml, txt_pt):
    """Core ML must agree with PyTorch, and text/image must agree with each other."""
    print("\nverifying …")
    from PIL import Image
    rng = np.random.default_rng(0)
    arr = (rng.random((SIDE, SIDE, 3)) * 255).astype(np.uint8)   # HWC, what PIL/Core ML take
    got_i = img_ml.predict({"image": Image.fromarray(arr)})["final_emb_1"][0]
    # The wrapper expects 0-1 (Core ML's ImageType scale=1/255 does that division on its side), so
    # the reference must divide too — feeding raw 0-255 here is what made this check fail at 0.81.
    with torch.no_grad():
        chw = arr.transpose(2, 0, 1)[None].astype(np.float32) / 255.0
        ref_i = img_pt(torch.from_numpy(chw)).numpy()[0]
    ci = float(np.dot(ref_i, got_i) / (np.linalg.norm(ref_i) * np.linalg.norm(got_i)))
    print(f"  image  torch vs coreml cosine: {ci:.5f}")

    worst = 1.0
    for phrase in ["a dog", "a birthday cake with candles", "a snowy mountain at sunset"]:
        ids = zero_padded_ids(phrase)
        with torch.no_grad():
            ref_t = txt_pt(torch.from_numpy(ids)).numpy()[0]
        got_t = txt_ml.predict({"text": ids.astype(np.float32)})["final_emb_1"][0]
        c = float(np.dot(ref_t, got_t) / (np.linalg.norm(ref_t) * np.linalg.norm(got_t)))
        worst = min(worst, c)
        print(f"  text   {phrase!r:40s} cosine: {c:.5f}")

    ok = ci > 0.99 and worst > 0.99
    print("\n" + ("VERIFY OK" if ok else "VERIFY FAILED — do not ship these models"))
    return ok


if __name__ == "__main__":
    img_ml, img_pt = export_image()
    txt_ml, txt_pt = export_text()
    raise SystemExit(0 if verify(img_ml, img_pt, txt_ml, txt_pt) else 1)
