"""OAK core: SigLIP 2 zero-shot keyword scoring against a vocabulary."""

from __future__ import annotations

import sys
from pathlib import Path

import torch
from PIL import Image
from transformers import AutoModel, AutoProcessor

MODEL_ID = "google/siglip2-base-patch16-384"
# SigLIP sigmoid scores are calibrated against many negatives, so true matches
# land around 1-10% and non-matches at ~0.0%. Threshold accordingly.
PROMPT = "a photo of a {}."
DEFAULT_VOCAB = Path(__file__).parent / "vocab.txt"


def load_vocab(path: Path = DEFAULT_VOCAB) -> list[str]:
    words = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            words.append(line)
    if not words:
        raise ValueError(f"vocabulary file {path} contains no keywords")
    return words


def _as_embedding(features) -> torch.Tensor:
    # transformers may return a tensor or a model-output object depending on version
    if isinstance(features, torch.Tensor):
        emb = features
    else:
        emb = getattr(features, "pooler_output", None)
        if emb is None:
            emb = features.last_hidden_state[:, 0]
    return emb / emb.norm(dim=-1, keepdim=True)


class Tagger:
    def __init__(self, vocab_path: Path = DEFAULT_VOCAB, device: str | None = None):
        self.device = device or ("cuda" if torch.cuda.is_available() else "cpu")
        self.vocab_path = vocab_path
        self.vocab = load_vocab(vocab_path)
        print(f"oak: loading {MODEL_ID} on {self.device} "
              f"({len(self.vocab)} keywords)...", file=sys.stderr)
        self.model = AutoModel.from_pretrained(MODEL_ID).to(self.device).eval()
        self.processor = AutoProcessor.from_pretrained(MODEL_ID)
        self._text_emb = self._embed_vocab()
        print("oak: model ready", file=sys.stderr)

    def reload_vocab(self) -> int:
        """Re-read the vocabulary file and re-embed. Returns keyword count."""
        self.vocab = load_vocab(self.vocab_path)
        self._text_emb = self._embed_vocab()
        print(f"oak: vocabulary reloaded ({len(self.vocab)} keywords)",
              file=sys.stderr)
        return len(self.vocab)

    def _embed_vocab(self) -> torch.Tensor:
        texts = [PROMPT.format(w) for w in self.vocab]
        with torch.no_grad():
            inputs = self.processor(text=texts, padding="max_length", max_length=64,
                                    return_tensors="pt").to(self.device)
            return _as_embedding(self.model.get_text_features(**inputs))

    def tag(self, image: Image.Image, top: int = 10,
            threshold: float = 0.0005, rel: float = 0.2) -> list[dict]:
        """Return ranked [{keyword, confidence}] for a PIL image.

        Absolute SigLIP scores vary wildly between photos, so keywords are kept
        if they score within `rel` of the photo's best keyword AND above the
        small absolute floor `threshold`.
        """
        with torch.no_grad():
            inputs = self.processor(images=image.convert("RGB"),
                                    return_tensors="pt").to(self.device)
            img_emb = _as_embedding(self.model.get_image_features(**inputs))
            logits = ((img_emb @ self._text_emb.T) * self.model.logit_scale.exp()
                      + self.model.logit_bias)
            probs = torch.sigmoid(logits)[0]

        ranked = sorted(zip(self.vocab, probs.tolist()), key=lambda x: -x[1])
        cutoff = max(threshold, ranked[0][1] * rel)
        return [{"keyword": w, "confidence": round(p, 5)}
                for w, p in ranked[:top] if p >= cutoff]
