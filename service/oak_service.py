"""OAK local inference service.

Run:  python oak_service.py [--host H] [--port 8420] [--logfile PATH]

Endpoints:
  GET  /health        -> {"status": "ok", "keywords": N}
  POST /tag           -> body: raw image bytes; query: ?top=N&threshold=T&rel=R
                         returns {"keywords": [{"keyword": ..., "confidence": ...}]}
  POST /vocab/reload  -> re-read vocab.txt and re-embed
  POST /shutdown      -> stop the service
"""

from __future__ import annotations

import argparse
import io
import logging
import os
import sys
import threading
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI, HTTPException, Request
from PIL import Image, UnidentifiedImageError

from oak_core import Tagger

log = logging.getLogger("uvicorn.error")

tagger: Tagger | None = None


@asynccontextmanager
async def _lifespan(_: FastAPI):
    global tagger
    tagger = Tagger()
    yield


app = FastAPI(title="OAK — Open Auto Keywording", lifespan=_lifespan)


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "keywords": len(tagger.vocab) if tagger else 0}


@app.post("/tag")
async def tag(request: Request, top: int = 10, threshold: float = 0.0005,
              rel: float = 0.2) -> dict:
    body = await request.body()
    if not body:
        raise HTTPException(400, "empty request body; send raw image bytes")
    try:
        image = Image.open(io.BytesIO(body))
        image.load()
    except UnidentifiedImageError:
        raise HTTPException(400, "body is not a decodable image")
    ranked = tagger.tag(image, top=max(top, 5), threshold=0.0, rel=0.0)
    # Log raw top scores (ignoring cutoffs) to aid threshold tuning
    log.info("tag: %s", ", ".join(f"{r['keyword']}={r['confidence']:.2%}"
                                  for r in ranked[:5]))
    cutoff = max(threshold, ranked[0]["confidence"] * rel) if ranked else 0
    return {"keywords": [r for r in ranked[:top] if r["confidence"] >= cutoff]}


@app.post("/vocab/reload")
def reload_vocab() -> dict:
    try:
        count = tagger.reload_vocab()
    except ValueError as e:
        raise HTTPException(400, str(e))
    return {"status": "ok", "keywords": count}


@app.post("/shutdown")
def shutdown() -> dict:
    log.info("shutdown requested")
    threading.Timer(0.5, os._exit, args=(0,)).start()
    return {"status": "shutting down"}


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="OAK local inference service")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8420)
    ap.add_argument("--logfile", default=None,
                    help="append logs to this file (required when running "
                         "without a console, e.g. via pythonw)")
    args = ap.parse_args()
    if args.logfile:
        logf = open(args.logfile, "a", buffering=1, encoding="utf-8")
        sys.stdout = sys.stderr = logf
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")
