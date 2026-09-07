#!/usr/bin/env python3
"""Convert candidate CLIP-family image encoders to Core ML, and precompute text embeddings.

Why the split: comparing encoders needs BOTH halves, but each family tokenizes differently
(CLIP BPE vs SigLIP sentencepiece). Reimplementing three tokenizers in Swift to benchmark them
would be a lot of work to throw away. So:

  * IMAGE encoders  -> Core ML .mlpackage, run natively in Swift (ANE/GPU). This is the half that
    matters for speed: it runs once per photo across a 21k library.
  * TEXT embeddings -> computed here in PyTorch for a fixed query set and written to JSON. A query
    set is tiny and fixed, so there is nothing to benchmark and nothing to reimplement.

Output layout (all under models/):
    <key>_image.mlpackage      image encoder
    manifest.json              per-candidate dim / input side / IO names / licence
    queries.json               query text -> per-candidate unit-normalised text embedding

Run:
    ./.venv/bin/python convert.py            # all candidates
    ./.venv/bin/python convert.py siglip     # one
"""

import json
import pathlib
import sys

import numpy as np
import torch
import coremltools as ct

HERE = pathlib.Path(__file__).parent
OUT = HERE / "models"
OUT.mkdir(exist_ok=True)

# Matches EmbedStage's Core ML contract so the Swift side stays identical across candidates.
IMAGE_INPUT = "image"
OUTPUT_NAME = "final_emb_1"

# The queries the report ranks photos against. Deliberately a spread of subject, scene, text-in-image
# and abstract phrasing — the cases where encoders diverge most.
QUERIES = [
    "a dog", "a cat", "a birthday cake with candles", "people at the beach",
    "a snowy mountain", "a screenshot of a text conversation", "a plate of food",
    "a child laughing", "fireworks at night", "a whiteboard with diagrams",
    "someone riding a bicycle", "a sunset over water", "a passport or ID document",
    "a concert crowd", "a car on a road", "flowers close up",
]

CANDIDATES = {
    # Baseline: what ships today. Research-only licence — see docs/model-licensing.md.
    "mobileclip_s2": {
        "kind": "prebuilt",
        "licence": "Apple ML Research Model License (research only)",
        "note": "already converted; reused from .models/Resources",
        "side": 256,
    },
    "openclip_b32": {
        "kind": "hf_clip",
        "hf": "laion/CLIP-ViT-B-32-laion2B-s34B-b79K",
        "licence": "MIT",
        "side": 224,
    },
    # Quality ceiling among permissive options: bigger and slower, included to price what the
    # extra accuracy costs per photo across a 20k+ library.
    # (laion's B/16 repo is open_clip-format — no model_type in config.json — so it can't load
    # through transformers; L/14 is the next MIT option that can.)
    "openclip_l14": {
        "kind": "hf_clip",
        "hf": "laion/CLIP-ViT-L-14-laion2B-s32B-b82K",
        "licence": "MIT",
        "side": 224,
    },
    # SigLIP (Apache-2.0) was the intended third candidate and is worth revisiting: its
    # MultiheadAttentionPoolingHead fails coremltools conversion with
    #   "converting 'int' op (located at: 'vision_model/head/attention/…')"
    # under both SDPA and eager attention. Would need the torch.export path or a hand-written
    # replacement head. Licence is fine; only the conversion is blocked.
    # "siglip_b16": {"kind": "hf_siglip", "hf": "google/siglip-base-patch16-224",
    #                "licence": "Apache-2.0", "side": 224},
}


class ImageEncoder(torch.nn.Module):
    """Wraps get_image_features and L2-normalises, so Swift compares raw cosine without post-work."""

    def __init__(self, model, mean, std):
        super().__init__()
        self.model = model
        # Core ML's ImageType supports only a SCALAR scale with per-channel bias, but CLIP's std is
        # per-channel — so normalisation lives here, inside the traced graph, where it still runs on
        # the ANE. The image input then just maps 0-255 to 0-1.
        self.register_buffer("mean", torch.tensor(mean, dtype=torch.float32).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(std, dtype=torch.float32).view(1, 3, 1, 1))

    def forward(self, pixel_values):
        pixel_values = (pixel_values - self.mean) / self.std
        f = self.model.get_image_features(pixel_values=pixel_values)
        # transformers 5.x returns BaseModelOutputWithPooling here rather than a bare tensor; its
        # pooler_output is the projected embedding (512-d for ViT-B/32, vs 768-d hidden state).
        if not isinstance(f, torch.Tensor):
            f = f.pooler_output
        return f / f.norm(dim=-1, keepdim=True)


def convert_hf(key, spec):
    from transformers import AutoModel, AutoProcessor

    print(f"[{key}] loading {spec['hf']} …")
    # eager attention: SDPA's fused path traces into ops coremltools can't lower (SigLIP's
    # attention-pooling head fails outright), and the eager path is mathematically identical.
    model = AutoModel.from_pretrained(spec["hf"], attn_implementation="eager").eval()
    proc = AutoProcessor.from_pretrained(spec["hf"])

    side = spec["side"]
    ip = proc.image_processor
    wrapper = ImageEncoder(model, ip.image_mean, ip.image_std).eval()
    example = torch.rand(1, 3, side, side)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example)
        dim = int(wrapper(example).shape[-1])

    # Swift hands over a plain 0-255 pixel buffer, exactly as EmbedStage already does; this maps it
    # to 0-1 and the wrapper above applies the per-channel mean/std.
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name=IMAGE_INPUT, shape=(1, 3, side, side),
                             scale=1.0 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name=OUTPUT_NAME)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
    )
    path = OUT / f"{key}_image.mlpackage"
    mlmodel.save(str(path))
    print(f"[{key}] wrote {path.name}  dim={dim}")

    # Text side, in PyTorch — one pass over a fixed query set.
    with torch.no_grad():
        toks = proc.tokenizer(QUERIES, padding="max_length", return_tensors="pt")
        tf = model.get_text_features(**toks)
        if not isinstance(tf, torch.Tensor):   # same transformers 5.x wrapping as the image side
            tf = tf.pooler_output
        tf = tf / tf.norm(dim=-1, keepdim=True)
    return dim, tf.numpy().astype(np.float32)


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else None
    manifest, queries = {}, {q: {} for q in QUERIES}

    for key, spec in CANDIDATES.items():
        if only and only != key:
            continue
        if spec["kind"] == "prebuilt":
            print(f"[{key}] {spec['note']} — skipping conversion")
            manifest[key] = {"dim": 512, "side": spec["side"], "licence": spec["licence"],
                             "prebuilt": True, "image_input": IMAGE_INPUT, "output": OUTPUT_NAME}
            continue
        dim, tvecs = convert_hf(key, spec)
        manifest[key] = {"dim": dim, "side": spec["side"], "licence": spec["licence"],
                         "prebuilt": False, "image_input": IMAGE_INPUT, "output": OUTPUT_NAME,
                         "hf": spec["hf"]}
        for i, q in enumerate(QUERIES):
            queries[q][key] = tvecs[i].tolist()

    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2))
    (OUT / "queries.json").write_text(json.dumps(queries))
    print(f"\nwrote manifest.json ({len(manifest)} candidates) and queries.json "
          f"({len(QUERIES)} queries)")


if __name__ == "__main__":
    main()
