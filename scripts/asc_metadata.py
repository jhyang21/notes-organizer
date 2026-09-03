#!/usr/bin/env python3
"""Push the App Store listing in docs/appstore/metadata.md to App Store Connect.

The doc is the source of truth. This script reads its fenced blocks and
PATCHes the objects whose IDs the doc records, then reads them back and
fails unless the live value is byte-identical.

  python scripts/asc_metadata.py check
  python scripts/asc_metadata.py push
  python scripts/asc_metadata.py review-screenshots monthly.png annual.png

Environment: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 (path to the .p8 file).
Needs pyjwt and cryptography. No secret is read from the repo or written to it.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import jwt

API = "https://api.appstoreconnect.apple.com/v1"
DOC = Path(__file__).resolve().parent.parent / "docs" / "appstore" / "metadata.md"

VERSION_LOCALIZATION = "1606cd73-b50b-4bbe-a43e-5c86f8dd58cc"
REVIEW_DETAIL = "eb9ff962-5d41-4c12-8ed1-d3c70a7b7450"
SUBSCRIPTIONS = {"monthly": "6799343950", "annual": "6799344100"}

# (doc heading, ASC object type, object id, attribute, character cap)
FIELDS = [
    ("Promotional text", "appStoreVersionLocalizations", VERSION_LOCALIZATION, "promotionalText", 170),
    ("Keywords", "appStoreVersionLocalizations", VERSION_LOCALIZATION, "keywords", 100),
    ("Description", "appStoreVersionLocalizations", VERSION_LOCALIZATION, "description", 4000),
    ("App Review notes", "appStoreReviewDetails", REVIEW_DETAIL, "notes", 4000),
]


def token() -> str:
    key_id = os.environ["ASC_KEY_ID"]
    issuer = os.environ["ASC_ISSUER_ID"]
    key = Path(os.environ["ASC_KEY_P8"]).read_text()
    now = int(time.time())
    payload = {"iss": issuer, "iat": now, "exp": now + 19 * 60, "aud": "appstoreconnect-v1"}
    return jwt.encode(payload, key, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})


def call(method: str, path: str, body: dict | None = None, *, raw: bytes | None = None,
         url: str | None = None, headers: dict | None = None) -> dict:
    req = urllib.request.Request(url or f"{API}/{path}", method=method)
    if url is None:
        req.add_header("Authorization", f"Bearer {token()}")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    data = raw
    if body is not None:
        req.add_header("Content-Type", "application/json")
        data = json.dumps(body).encode()
    try:
        with urllib.request.urlopen(req, data=data, timeout=120) as r:
            text = r.read()
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path or url}: HTTP {e.code}\n{e.read().decode(errors='replace')[:2000]}")
    return json.loads(text) if text else {}


def doc_block(heading: str) -> str:
    text = DOC.read_text(encoding="utf-8")
    m = re.search(r"^## " + re.escape(heading) + r"[^\n]*\n\n```\n(.*?)\n```", text, re.S | re.M)
    if not m:
        sys.exit(f"metadata.md: no fenced block under '## {heading}'")
    return m.group(1)


def live_value(obj_type: str, obj_id: str, attribute: str) -> str:
    return call("GET", f"{obj_type}/{obj_id}")["data"]["attributes"].get(attribute) or ""


def diff_fields() -> list[tuple]:
    """Return the FIELDS entries whose doc value differs from the live value."""
    stale = []
    for heading, obj_type, obj_id, attribute, cap in FIELDS:
        wanted = doc_block(heading)
        if len(wanted) > cap:
            sys.exit(f"{heading}: {len(wanted)} chars, cap is {cap}. Fix the doc first.")
        live = live_value(obj_type, obj_id, attribute)
        state = "same" if live == wanted else "DIFFERS"
        print(f"{heading:18} doc {len(wanted):5} live {len(live):5}  {state}")
        if live != wanted:
            stale.append((heading, obj_type, obj_id, attribute, wanted))
    return stale


def cmd_check() -> None:
    diff_fields()


def cmd_push() -> None:
    stale = diff_fields()
    if not stale:
        print("Nothing to push.")
        return
    for heading, obj_type, obj_id, attribute, wanted in stale:
        call("PATCH", f"{obj_type}/{obj_id}",
             {"data": {"type": obj_type, "id": obj_id, "attributes": {attribute: wanted}}})
        live = live_value(obj_type, obj_id, attribute)
        if live != wanted:
            sys.exit(f"{heading}: read-back differs after PATCH")
        print(f"{heading}: pushed, read back byte-identical ({len(live)} chars)")


def current_screenshot(sub_id: str) -> str | None:
    data = call("GET", f"subscriptions/{sub_id}/appStoreReviewScreenshot").get("data")
    return data["id"] if data else None


def upload_screenshot(sub_id: str, png: Path) -> str:
    blob = png.read_bytes()
    created = call("POST", "subscriptionAppStoreReviewScreenshots", {"data": {
        "type": "subscriptionAppStoreReviewScreenshots",
        "attributes": {"fileName": png.name, "fileSize": len(blob)},
        "relationships": {"subscription": {"data": {"type": "subscriptions", "id": sub_id}}},
    }})["data"]
    for op in created["attributes"]["uploadOperations"]:
        chunk = blob[op["offset"]:op["offset"] + op["length"]]
        call(op["method"], "", raw=chunk, url=op["url"],
             headers={h["name"]: h["value"] for h in op["requestHeaders"]})
    call("PATCH", f"subscriptionAppStoreReviewScreenshots/{created['id']}", {"data": {
        "type": "subscriptionAppStoreReviewScreenshots", "id": created["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(blob).hexdigest()},
    }})
    for _ in range(30):
        state = call("GET", f"subscriptionAppStoreReviewScreenshots/{created['id']}")
        state = state["data"]["attributes"]["assetDeliveryState"]["state"]
        if state == "COMPLETE":
            return created["id"]
        if state == "FAILED":
            sys.exit(f"{png.name}: asset delivery FAILED")
        time.sleep(5)
    sys.exit(f"{png.name}: asset delivery still {state} after 150 s")


def cmd_review_screenshots(monthly: str, annual: str) -> None:
    for name, png in (("monthly", Path(monthly)), ("annual", Path(annual))):
        sub_id = SUBSCRIPTIONS[name]
        old = current_screenshot(sub_id)
        if old:
            call("DELETE", f"subscriptionAppStoreReviewScreenshots/{old}")
        new = upload_screenshot(sub_id, png)
        state = call("GET", f"subscriptions/{sub_id}")["data"]["attributes"]["state"]
        print(f"{name}: screenshot {new} delivered ({png.name}); subscription state {state}")


def main(argv: list[str]) -> None:
    if argv[:1] == ["check"]:
        cmd_check()
    elif argv[:1] == ["push"]:
        cmd_push()
    elif argv[:1] == ["review-screenshots"] and len(argv) == 3:
        cmd_review_screenshots(argv[1], argv[2])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
