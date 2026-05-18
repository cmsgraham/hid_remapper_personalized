#!/usr/bin/env python3
"""Tiny dev server for the HID Remapper config tool.

Same as `python3 -m http.server` for GETs, plus:

    PUT    /profiles/<name>.json    -> writes JSON to ../profiles/<name>.json
                                        and adds <name> to profiles-manifest.json
    DELETE /profiles/<name>.json    -> deletes file and manifest entry

Binds to 127.0.0.1 only. Intended for local development; do NOT expose to a
network. Profile names are restricted to [A-Za-z0-9._-]+ so the path can never
escape the profiles directory.
"""
from __future__ import annotations

import json
import os
import re
import sys
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = 8765
HOST = "127.0.0.1"
WEB_DIR = Path(__file__).resolve().parent
PROFILES_DIR = (WEB_DIR / ".." / "profiles").resolve()
MANIFEST = WEB_DIR / "profiles-manifest.json"
NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")
MAX_BODY = 2 * 1024 * 1024  # 2 MB sanity cap


def _parse_profile_path(path: str) -> str | None:
    # Accept /profiles/<name>.json with optional query string.
    path = path.split("?", 1)[0]
    if not path.startswith("/profiles/") or not path.endswith(".json"):
        return None
    name = path[len("/profiles/") : -len(".json")]
    if not NAME_RE.match(name):
        return None
    return name


def _read_manifest() -> list[str]:
    try:
        data = json.loads(MANIFEST.read_text())
    except (OSError, json.JSONDecodeError):
        return []
    return [x for x in data if isinstance(x, str)] if isinstance(data, list) else []


def _write_manifest(names: list[str]) -> None:
    MANIFEST.write_text(json.dumps(sorted(set(names)), indent=4) + "\n")


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(WEB_DIR), **kw)

    def log_message(self, fmt, *args):
        sys.stderr.write("[serve] %s - %s\n" % (self.address_string(), fmt % args))

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_PUT(self):  # noqa: N802
        name = _parse_profile_path(self.path)
        if name is None:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid profile path"})
            return
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "missing or oversized body"})
            return
        raw = self.rfile.read(length)
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as e:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": f"invalid json: {e}"})
            return
        if not isinstance(parsed, dict):
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "expected json object"})
            return
        PROFILES_DIR.mkdir(parents=True, exist_ok=True)
        target = PROFILES_DIR / f"{name}.json"
        target.write_text(json.dumps(parsed, indent=4) + "\n")
        names = _read_manifest()
        if name not in names:
            names.append(name)
            _write_manifest(names)
        self._send_json(HTTPStatus.OK, {"saved": name, "path": str(target)})

    def do_DELETE(self):  # noqa: N802
        name = _parse_profile_path(self.path)
        if name is None:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid profile path"})
            return
        target = PROFILES_DIR / f"{name}.json"
        try:
            target.unlink()
        except FileNotFoundError:
            pass
        names = [n for n in _read_manifest() if n != name]
        _write_manifest(names)
        self._send_json(HTTPStatus.OK, {"deleted": name})


def main() -> None:
    PROFILES_DIR.mkdir(parents=True, exist_ok=True)
    if not MANIFEST.exists():
        _write_manifest([])
    with ThreadingHTTPServer((HOST, PORT), Handler) as srv:
        print(f"[serve] http://{HOST}:{PORT}/  (cwd={WEB_DIR}, profiles={PROFILES_DIR})")
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            print("\n[serve] bye")


if __name__ == "__main__":
    main()
