#!/usr/bin/env python3
"""Register a Docker image ref on orchestrator-api (allowlist) and refresh registry digests.

Auth: same bearer as CRABSHACK_ADMIN_SECRET on the API (Authorization: Bearer ...).
  ORCH_ADMIN_SECRET — preferred for local use
  AGENTS_STG_ORCHESTRATOR_ADMIN_SECRET — common in GitHub Actions
  CRABSHACK_ADMIN_SECRET — alias

Examples:
  ORCH_ADMIN_SECRET=… python3 scripts/register_orchestrator_allowlist.py
  ORCH_ADMIN_SECRET=… python3 scripts/register_orchestrator_allowlist.py \\
    --orch-url https://api.agents-staging.near.ai \\
    --image-ref docker.io/nearaidev/ironclaw-dind:staging \\
    --note-suffix "manual 2026-04-10"
"""

import argparse
import json
import os
import sys
from typing import Dict, Optional, Tuple
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

DEFAULT_ORCH_URL = "https://api.agents-staging.near.ai"
DEFAULT_IMAGE_REF = "docker.io/nearaidev/ironclaw-dind:staging"
DEFAULT_LABEL = "Ironclaw DinD (staging)"
DEFAULT_SERVICE_TYPE = "ironclaw-dind"

SECRET_KEYS = (
    "ORCH_ADMIN_SECRET",
    "AGENTS_STG_ORCHESTRATOR_ADMIN_SECRET",
    "CRABSHACK_ADMIN_SECRET",
)


def resolve_secret() -> Optional[str]:
    for key in SECRET_KEYS:
        v = os.environ.get(key)
        if v:
            return v
    return None


def http_post_json(url: str, token: str, body: Optional[bytes] = None) -> Tuple[int, bytes]:
    # urllib uses GET when data is None; empty POST must use b"".
    payload = b"" if body is None else body
    headers: Dict[str, str] = {"Authorization": f"Bearer {token}"}
    if body is not None:
        headers["Content-Type"] = "application/json"
    req = Request(url, data=payload, method="POST", headers=headers)
    try:
        with urlopen(req, timeout=120) as resp:
            return resp.status, resp.read()
    except HTTPError as e:
        return e.code, e.read()


def main() -> int:
    env = os.environ
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument(
        "--orch-url",
        default=env.get("ORCH_URL", DEFAULT_ORCH_URL).rstrip("/"),
        help="API base URL (no trailing slash)",
    )
    p.add_argument(
        "--image-ref",
        default=env.get("IMAGE_REF", DEFAULT_IMAGE_REF),
        help="Full image ref",
    )
    p.add_argument("--label", default=DEFAULT_LABEL)
    p.add_argument("--service-type", default=DEFAULT_SERVICE_TYPE)
    p.add_argument(
        "--note",
        default=None,
        help="Full note (overrides default + --note-suffix)",
    )
    p.add_argument("--note-suffix", default="", help="Appended to default note")
    p.add_argument(
        "--no-resolve-digests",
        action="store_true",
        help="Skip POST /images/resolve-digests",
    )
    args = p.parse_args()

    secret = resolve_secret()
    if not secret:
        print(
            "ERROR: set one of: "
            + ", ".join(SECRET_KEYS),
            file=sys.stderr,
        )
        return 1

    if args.note is not None:
        note = args.note
    else:
        note = "ironclaw-dind allowlist"
        if args.note_suffix:
            note = f"{note} {args.note_suffix}"

    payload = {
        "ref": args.image_ref,
        "label": args.label,
        "service_type": args.service_type,
        "status": "allow-create",
        "preferred": 0,
        "note": note,
    }
    body = json.dumps(payload).encode()

    images_url = f"{args.orch_url}/images"
    print(f"==> POST {images_url} ({args.image_ref})")
    try:
        code, resp_body = http_post_json(images_url, secret, body)
    except URLError as e:
        print(f"ERROR: request failed: {e}", file=sys.stderr)
        return 1

    if code not in (201, 409):
        print(f"ERROR: POST /images HTTP {code}", file=sys.stderr)
        print(resp_body.decode("utf-8", errors="replace"), end="", file=sys.stderr)
        if resp_body and not resp_body.endswith(b"\n"):
            print(file=sys.stderr)
        return 1
    if code == 201:
        print("    Created allowlist entry")
    else:
        print("    Allowlist entry already exists (409)")

    if not args.no_resolve_digests:
        rd_url = f"{args.orch_url}/images/resolve-digests"
        print(f"==> POST {rd_url}")
        try:
            rd_code, rd_body = http_post_json(rd_url, secret, None)
        except URLError as e:
            print(f"ERROR: request failed: {e}", file=sys.stderr)
            return 1
        if rd_code != 200:
            print(f"ERROR: POST /images/resolve-digests HTTP {rd_code}", file=sys.stderr)
            print(rd_body.decode("utf-8", errors="replace"), end="", file=sys.stderr)
            if rd_body and not rd_body.endswith(b"\n"):
                print(file=sys.stderr)
            return 1
        print("    Digest refresh completed")

    return 0


if __name__ == "__main__":
    sys.exit(main())
