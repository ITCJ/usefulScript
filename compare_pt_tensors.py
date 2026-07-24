#!/usr/bin/env python3
"""Compare one tensor expression across matching PT dump trees.

Example:
    python3 compare_pt_tensors.py \
        /path/to/baseline/rank_000/sparse_attention/decode \
        /path/to/ours/rank_000/sparse_attention/decode \
        'attention_output.flatten()' \
        --glob 'layer_*/call_00044/operator_output.pt'
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Find matching PT files under two roots and compare one tensor "
            "expression by invoking inspect_pt_tensor.py."
        )
    )
    parser.add_argument("baseline_path", type=Path)
    parser.add_argument("ours_path", type=Path)
    parser.add_argument(
        "expression",
        help="Tensor expression accepted by inspect_pt_tensor.py",
    )
    parser.add_argument(
        "--glob",
        default="**/*.pt",
        help="Relative PT glob used below both directory roots (default: %(default)s)",
    )
    parser.add_argument(
        "--rtol",
        type=float,
        default=1e-5,
        help="Relative tolerance passed to inspect_pt_tensor.py",
    )
    parser.add_argument(
        "--atol",
        type=float,
        default=1e-8,
        help="Absolute tolerance passed to inspect_pt_tensor.py",
    )
    parser.add_argument(
        "--max-diff-rows",
        type=int,
        default=10,
        help="Differing rows shown with --show-details (default: %(default)s)",
    )
    parser.add_argument(
        "--show-details",
        action="store_true",
        help="Print complete inspect output for CLOSE, DIFFERENT, and ERROR results",
    )
    parser.add_argument(
        "--stop-on-diff",
        action="store_true",
        help="Stop after the first non-exact comparison",
    )
    return parser.parse_args()


def find_file_pairs(
    baseline_path: Path,
    ours_path: Path,
    pattern: str,
) -> list[tuple[str, Path, Path]]:
    if baseline_path.is_file() or ours_path.is_file():
        if not baseline_path.is_file() or not ours_path.is_file():
            raise ValueError(
                "baseline_path and ours_path must either both be files or "
                "both be directories"
            )
        return [(baseline_path.name, baseline_path, ours_path)]

    if not baseline_path.is_dir():
        raise FileNotFoundError(f"Baseline directory does not exist: {baseline_path}")
    if not ours_path.is_dir():
        raise FileNotFoundError(f"Ours directory does not exist: {ours_path}")

    pairs = []
    for baseline_file in sorted(baseline_path.glob(pattern)):
        if not baseline_file.is_file():
            continue
        relative_path = baseline_file.relative_to(baseline_path)
        pairs.append(
            (
                str(relative_path),
                baseline_file,
                ours_path / relative_path,
            )
        )
    if not pairs:
        raise FileNotFoundError(
            f"No baseline PT files matched {pattern!r} below {baseline_path}"
        )
    return pairs


def parse_comparison_output(output: str) -> dict[str, str]:
    fields = {}
    expected_fields = {
        "same_shape",
        "same_dtype",
        "torch_equal",
        "allclose",
        "different_elements",
        "different_rows",
        "max_abs_diff",
        "mean_abs_diff",
    }
    for line in output.splitlines():
        key, separator, value = line.partition(":")
        if separator and key in expected_fields:
            fields[key] = value.strip()
    return fields


def compare_one(
    inspect_script: Path,
    baseline_file: Path,
    ours_file: Path,
    expression: str,
    *,
    rtol: float,
    atol: float,
    max_diff_rows: int,
) -> tuple[str, dict[str, str], str]:
    if not ours_file.is_file():
        return "ERROR", {}, f"Ours PT file does not exist: {ours_file}"

    command = [
        sys.executable,
        str(inspect_script),
        str(baseline_file),
        expression,
        "--compare",
        str(ours_file),
        expression,
        "--rtol",
        str(rtol),
        "--atol",
        str(atol),
        "--max-diff-rows",
        str(max_diff_rows),
    ]
    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
    )
    output = result.stdout
    if result.returncode != 0:
        error_output = result.stderr.strip() or output.strip()
        return "ERROR", {}, error_output

    fields = parse_comparison_output(output)
    if fields.get("torch_equal") == "True":
        return "EXACT", fields, output
    if fields.get("allclose") == "True":
        return "CLOSE", fields, output
    if "torch_equal" not in fields:
        return "ERROR", fields, output
    return "DIFFERENT", fields, output


def format_result(status: str, relative_path: str, fields: dict[str, str]) -> str:
    details = []
    for key in ("different_elements", "different_rows", "max_abs_diff"):
        if key in fields:
            details.append(f"{key}={fields[key]}")
    suffix = f" {' '.join(details)}" if details else ""
    return f"{status:<9} {relative_path}{suffix}"


def main() -> int:
    args = parse_args()
    if args.max_diff_rows < 0:
        raise ValueError("--max-diff-rows must be non-negative")

    inspect_script = Path(__file__).with_name("inspect_pt_tensor.py")
    if not inspect_script.is_file():
        raise FileNotFoundError(f"Inspector script does not exist: {inspect_script}")

    pairs = find_file_pairs(args.baseline_path, args.ours_path, args.glob)
    counts = {"EXACT": 0, "CLOSE": 0, "DIFFERENT": 0, "ERROR": 0}
    first_non_exact = None

    for relative_path, baseline_file, ours_file in pairs:
        status, fields, output = compare_one(
            inspect_script,
            baseline_file,
            ours_file,
            args.expression,
            rtol=args.rtol,
            atol=args.atol,
            max_diff_rows=args.max_diff_rows,
        )
        counts[status] += 1
        print(format_result(status, relative_path, fields), flush=True)

        if status != "EXACT" and first_non_exact is None:
            first_non_exact = relative_path
        if args.show_details and status != "EXACT":
            print(output.rstrip())
            print()
        if args.stop_on_diff and status != "EXACT":
            break

    print(
        "summary: "
        + " ".join(
            f"{status.lower()}={counts[status]}"
            for status in ("EXACT", "CLOSE", "DIFFERENT", "ERROR")
        )
    )
    if first_non_exact is not None:
        print(f"first_non_exact: {first_non_exact}")

    if counts["ERROR"]:
        return 2
    if counts["CLOSE"] or counts["DIFFERENT"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
