#!/usr/bin/env python3
"""Diagnose nputop device discovery without printing confidential NPU data."""

from __future__ import annotations

import inspect
import subprocess
import time


def print_result(name: str, value: object) -> None:
    """Print one stable, easy-to-copy diagnostic field."""
    print(f"{name}: {value}")


def main() -> int:
    try:
        import nputop
        from nputop.api import libascend
    except Exception as ex:  # pylint: disable=broad-exception-caught
        print_result("import_ok", False)
        print_result("import_error_type", type(ex).__name__)
        return 2

    refresh = getattr(libascend, "_refresh_cache", None)
    refresh_source = inspect.getsource(refresh) if refresh is not None else ""

    print_result("import_ok", True)
    print_result("nputop_version", getattr(nputop, "__version__", "unknown"))
    print_result("has_resilient_refresh", refresh is not None)
    print_result("has_patch2_parser", "pending_device" in refresh_source)

    started_at = time.monotonic()
    try:
        result = subprocess.run(
            ["npu-smi", "info"],
            capture_output=True,
            text=True,
            timeout=6,
        )
    except subprocess.TimeoutExpired:
        print_result("npu_smi_timeout", True)
        print_result("npu_smi_elapsed_seconds", round(time.monotonic() - started_at, 3))
        return 3
    except Exception as ex:  # pylint: disable=broad-exception-caught
        print_result("npu_smi_error_type", type(ex).__name__)
        return 3

    elapsed = time.monotonic() - started_at
    lines = result.stdout.splitlines()
    print_result("npu_smi_timeout", False)
    print_result("npu_smi_elapsed_seconds", round(elapsed, 3))
    print_result("npu_smi_returncode", result.returncode)
    print_result("stdout_line_count", len(lines))
    print_result("stdout_size", len(result.stdout))
    print_result("stderr_size", len(result.stderr))

    device_pattern = getattr(libascend, "_RE_L1", None)
    detail_pattern = getattr(libascend, "_RE_L2", None)
    process_pattern = getattr(libascend, "_RE_P", None)
    patterns = (
        ("device_line_matches", device_pattern),
        ("detail_line_matches", detail_pattern),
        ("process_line_matches", process_pattern),
    )
    for name, pattern in patterns:
        matches = (
            sum(bool(pattern.match(line.strip())) for line in lines)
            if pattern is not None
            else "unsupported"
        )
        print_result(name, matches)

    if refresh is None:
        print_result("refresh_ok", "unsupported_old_version")
        return 4

    try:
        refresh_ok = refresh(result.stdout)
        parsed_device_count = len(getattr(libascend, "_IDX", ()))
    except Exception as ex:  # pylint: disable=broad-exception-caught
        print_result("refresh_ok", False)
        print_result("refresh_error_type", type(ex).__name__)
        return 5

    print_result("refresh_ok", refresh_ok)
    print_result("parsed_device_count", parsed_device_count)

    return 0 if result.returncode == 0 and refresh_ok and parsed_device_count > 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
