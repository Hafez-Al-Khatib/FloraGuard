"""Quick disease-classification client for local testing.

Throw any plant-leaf image (a URL or a local file) at the running API and get
back the predicted PlantVillage class, confidence, and treatment advice.

The image is re-encoded to a sane-sized JPEG first, so it works with any
online image regardless of format (PNG/WebP/JPEG) or resolution, and stays
under the API's 2 MB upload limit.

Usage (from edge-server/, with the venv active or via the venv python):
    python classify.py <image-url-or-path> [node_id]

Examples:
    python classify.py https://example.com/tomato_blight.jpg
    python classify.py C:\\Users\\me\\Downloads\\leaf.png cam-greenhouse-a

Env overrides:
    PMS_API    base URL of the API   (default http://localhost:8000)
    PMS_TOKEN  bearer token          (default pms-local-dev-token-change-in-production)
"""
from __future__ import annotations

import io
import os
import sys

import httpx
from PIL import Image

API = os.environ.get("PMS_API", "http://localhost:8000")
TOKEN = os.environ.get("PMS_TOKEN", "pms-local-dev-token-change-in-production")
MAX_EDGE = 1024  # downscale longest side to this before upload


def load_bytes(src: str) -> bytes:
    """Read raw image bytes from an http(s) URL or a local file path."""
    if src.startswith(("http://", "https://")):
        print(f"[1/4] Downloading {src} ...")
        resp = httpx.get(src, timeout=30, follow_redirects=True)
        resp.raise_for_status()
        return resp.content
    print(f"[1/4] Reading local file {src} ...")
    with open(src, "rb") as f:
        return f.read()


def to_jpeg(raw: bytes) -> bytes:
    """Normalize any image to a downscaled RGB JPEG the API will accept."""
    img = Image.open(io.BytesIO(raw)).convert("RGB")
    if max(img.size) > MAX_EDGE:
        img.thumbnail((MAX_EDGE, MAX_EDGE))
    out = io.BytesIO()
    img.save(out, "JPEG", quality=88)
    data = out.getvalue()
    print(f"[2/4] Normalized to JPEG: {img.size[0]}x{img.size[1]}, {len(data)//1024} KB")
    return data


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2

    src = sys.argv[1]
    node_id = sys.argv[2] if len(sys.argv) > 2 else "cam-test"
    headers = {"Authorization": f"Bearer {TOKEN}"}

    try:
        jpeg = to_jpeg(load_bytes(src))
    except Exception as exc:
        print(f"ERROR preparing image: {exc}")
        return 1

    with httpx.Client(timeout=30) as client:
        # Upload the frame (raw binary body, image/jpeg).
        up = client.post(
            f"{API}/api/v1/node/{node_id}/upload-frame",
            content=jpeg,
            headers={**headers, "Content-Type": "image/jpeg"},
        )
        print(f"[3/4] upload-frame -> {up.status_code}")
        if up.status_code != 200:
            print(up.text)
            return 1

        # Run inference.
        an = client.get(f"{API}/api/v1/node/{node_id}/analyze", headers=headers)
        print(f"[4/4] analyze -> {an.status_code}\n")
        if an.status_code != 200:
            print(an.text)
            return 1

    body = an.json()
    issue = body["anomalies"]["issue"]
    conf = body["anomalies"]["confidence"]
    print("=" * 52)
    print(f"  DIAGNOSIS : {issue}")
    print(f"  CONFIDENCE: {conf * 100:.1f}%")
    print(f"  LATENCY   : {body.get('inference_ms')} ms")
    print("=" * 52)

    treatments = body.get("treatments")
    if treatments:
        print("\n  Recommended treatments:")
        for t in treatments:
            print(f"\n  [{t['type'].upper()}]")
            for action in t["actions"]:
                print(f"    - {action}")
    else:
        print("\n  No treatment needed (healthy / no known disease).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
