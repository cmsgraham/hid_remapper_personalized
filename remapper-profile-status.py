#!/usr/bin/env python3
"""Show which saved profile is currently active on the HID Remapper.

Reads the live config off the device via the config-tool's get_config.py logic,
canonicalises it, and compares its fingerprint against each profile JSON in
the profiles directory.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path


# Keys we use to compute the profile fingerprint. We intentionally exclude
# noisy / non-portable fields like the version number so a profile still
# matches across firmware updates.
FINGERPRINT_KEYS = (
    "unmapped_passthrough_layers",
    "partial_scroll_timeout",
    "tap_hold_threshold",
    "gpio_debounce_time_ms",
    "interval_override",
    "our_descriptor_number",
    "ignore_auth_dev_inputs",
    "macro_entry_duration",
    "gpio_output_mode",
    "normalize_gamepad_inputs",
    "mappings",
    "macros",
    "expressions",
    "quirks",
)


_EXPR_COMMENT_RE = re.compile(r"/\*.*?\*/", re.DOTALL)


def _normalise_expression(expr: str) -> str:
    """Strip /* comments */ and collapse whitespace so file-side comments
    don't break fingerprint comparison with the device (which doesn't store them)."""
    if not expr:
        return ""
    return " ".join(_EXPR_COMMENT_RE.sub(" ", expr).split())


def _normalise_mapping(m):
    # Drop placeholder all-zero mappings so an "empty" profile compares equal
    # whether or not the UI inserted a blank row.
    if m.get("source_usage", "").lower() in ("0x00000000", "0x0") and \
       m.get("target_usage", "").lower() in ("0x00000000", "0x0"):
        return None
    return {
        "source_usage": m.get("source_usage", "").lower(),
        "target_usage": m.get("target_usage", "").lower(),
        "scaling": m.get("scaling", 1000),
        "layers": sorted(m.get("layers", [])),
        "sticky": bool(m.get("sticky", False)),
        "tap": bool(m.get("tap", False)),
        "hold": bool(m.get("hold", False)),
        "source_port": m.get("source_port", 0),
        "target_port": m.get("target_port", 0),
    }


def fingerprint(config):
    normalised = {}
    for key in FINGERPRINT_KEYS:
        val = config.get(key)
        if key == "mappings":
            mapped = [_normalise_mapping(m) for m in (val or [])]
            mapped = [m for m in mapped if m is not None]
            mapped.sort(key=lambda m: (m["source_usage"], m["target_usage"],
                                      tuple(m["layers"])))
            normalised[key] = mapped
        elif key == "macros":
            # Trim trailing empty macros so the count doesn't matter.
            macros = list(val or [])
            while macros and not macros[-1]:
                macros.pop()
            normalised[key] = macros
        elif key == "expressions":
            exprs = [_normalise_expression(e) for e in (val or [])]
            while exprs and not exprs[-1]:
                exprs.pop()
            normalised[key] = exprs
        elif key == "quirks":
            normalised[key] = sorted(val or [], key=lambda q: json.dumps(q, sort_keys=True))
        else:
            normalised[key] = val
    blob = json.dumps(normalised, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def read_device_config(config_tool_dir: Path) -> dict:
    """Invoke get_config.py and parse its JSON output."""
    proc = subprocess.run(
        [sys.executable, "get_config.py"],
        cwd=config_tool_dir,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        msg = proc.stderr.strip() or proc.stdout.strip() or "(no output)"
        raise RuntimeError(f"get_config.py failed (exit {proc.returncode}): {msg}")
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"get_config.py returned non-JSON output: {e}\n--- stdout ---\n{proc.stdout}")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--profiles", required=True, type=Path)
    p.add_argument("--config-tool", required=True, type=Path)
    p.add_argument("--last", required=True, type=Path)
    args = p.parse_args()

    profile_files = sorted(args.profiles.glob("*.json"))
    if not profile_files:
        print(f"no profiles found in {args.profiles}", file=sys.stderr)
        return 2

    profile_fps = {}
    for pf in profile_files:
        try:
            data = json.loads(pf.read_text())
        except Exception as e:
            print(f"warning: could not parse {pf.name}: {e}", file=sys.stderr)
            continue
        profile_fps[pf.stem] = fingerprint(data)

    try:
        device_cfg = read_device_config(args.config_tool)
    except RuntimeError as e:
        print(f"error reading device: {e}", file=sys.stderr)
        last_hint = args.last.read_text().strip() if args.last.exists() else "(none)"
        print(f"last applied profile (cached): {last_hint}", file=sys.stderr)
        return 3

    device_fp = fingerprint(device_cfg)

    last_applied = args.last.read_text().strip() if args.last.exists() else None

    match = None
    for name, fp in profile_fps.items():
        if fp == device_fp:
            match = name
            break

    print("HID Remapper profile status")
    print("---------------------------")
    print(f"  device fingerprint : {device_fp[:16]}")
    print(f"  active profile     : {match or '(unknown / custom)'}")
    print(f"  last applied (cache): {last_applied or '(none)'}")
    print()
    print("known profiles:")
    for name, fp in profile_fps.items():
        marker = "* " if name == match else "  "
        print(f"  {marker}{name:<10} {fp[:16]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
