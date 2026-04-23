#!/usr/bin/env python3
"""Update source commit map JSON and optionally commit/push it.

Expected env vars:
  SOURCE_MAP_PATH (required)
  DIND_DIGEST (required, must start with sha256:)
  SOURCE_DIGEST (optional)
  SOURCE_GIT_SHA (optional)
  IMAGE_REF (optional)
  IMAGE_TAG (optional)

CI commit/push controls:
  CI_COMMIT_MAP=true|false (default false)
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict


def _env(name: str, default: str | None = None) -> str | None:
    return os.environ.get(name, default)


def _run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True)


def _load_map(path: Path) -> Dict[str, Any]:
    if path.exists():
        return json.loads(path.read_text())
    return {"updated_at": None, "images": {}}


def _update_map(path: Path) -> bool:
    digest = _env("DIND_DIGEST", "") or ""
    if not digest.startswith("sha256:"):
        print("Skipping map update: unresolved image digest.")
        return False

    data = _load_map(path)
    images = data.setdefault("images", {})
    images[digest] = {
        "source_git_sha": _env("SOURCE_GIT_SHA"),
        "source_digest": _env("SOURCE_DIGEST"),
        "image_ref": _env("IMAGE_REF"),
        "version": _env("IMAGE_TAG"),
    }
    data["updated_at"] = datetime.now(timezone.utc).isoformat()

    before = path.read_text() if path.exists() else None
    after = json.dumps(data, indent=2, sort_keys=True) + "\n"
    if before == after:
        return False

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(after)
    return True


def _commit_and_push(path: Path) -> None:
    _run(["git", "config", "user.name", "github-actions[bot]"])
    _run(["git", "config", "user.email", "github-actions[bot]@users.noreply.github.com"])
    _run(["git", "add", str(path)])
    _run(["git", "commit", "-m", "chore: update ironclaw source commit map [skip ci]"])
    _run(["git", "push"])


def main() -> int:
    source_map_path = _env("SOURCE_MAP_PATH")
    if not source_map_path:
        print("SOURCE_MAP_PATH is required", file=sys.stderr)
        return 1

    path = Path(source_map_path)
    changed = _update_map(path)
    if not changed:
        print("No source map changes to commit.")
        return 0

    if (_env("CI_COMMIT_MAP", "false") or "false").lower() == "true":
        _commit_and_push(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
