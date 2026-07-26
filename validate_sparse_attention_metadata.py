#!/usr/bin/env python3
"""Validate semantic metadata for baseline PA and ours compact SFA inputs."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

import torch

from inspect_pt_tensor import get_tensors, load_pt


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("baseline_pt", type=Path)
    parser.add_argument("ours_pt", type=Path)
    return parser.parse_args()


def require_tensor(tensors: dict[str, Any], name: str) -> torch.Tensor:
    value = tensors.get(name)
    if not isinstance(value, torch.Tensor):
        raise TypeError(f"{name!r} is missing or is not a tensor")
    return value.detach().cpu().contiguous()


def report(name: str, passed: bool, details: str) -> bool:
    print(f"{'PASS' if passed else 'FAIL'} {name}: {details}")
    return passed


def main() -> int:
    args = parse_args()
    baseline = get_tensors(load_pt(args.baseline_pt))
    ours = get_tensors(load_pt(args.ours_pt))
    passed = True

    baseline_query_lens = require_tensor(baseline, "actual_seq_lengths_query").flatten()
    ours_query_lens = require_tensor(ours, "actual_seq_lengths_query").flatten()
    query_lens_equal = (
        baseline_query_lens.dtype == ours_query_lens.dtype
        and torch.equal(baseline_query_lens, ours_query_lens)
    )
    passed &= report(
        "actual_seq_lengths_query",
        query_lens_equal,
        f"baseline={baseline_query_lens.tolist()} ours={ours_query_lens.tolist()}",
    )

    baseline_valid_mask = require_tensor(baseline, "last_query_topk_valid_mask").to(
        torch.bool
    )
    baseline_valid_topk_count = int(baseline_valid_mask.sum().item())
    ours_kv_lens = require_tensor(ours, "actual_seq_lengths_kv").to(torch.long)
    ours_kv_lens = ours_kv_lens.flatten()
    if ours_kv_lens.numel() == 0:
        raise ValueError("ours actual_seq_lengths_kv is empty")

    last_kv_len = int(ours_kv_lens[-1].item())
    valid_count_equal = baseline_valid_topk_count == last_kv_len
    passed &= report(
        "baseline valid top-k count == ours actual_seq_lengths_kv",
        valid_count_equal,
        (
            f"baseline_valid_topk_count={baseline_valid_topk_count} "
            f"ours={ours_kv_lens.tolist()}"
        ),
    )

    sparse_indices = require_tensor(ours, "sparse_indices").to(torch.long)
    if sparse_indices.dim() < 2:
        raise ValueError(
            f"ours sparse_indices must have at least 2 dimensions: "
            f"shape={list(sparse_indices.shape)}"
        )
    if sparse_indices.shape[0] != ours_kv_lens.numel():
        raise ValueError(
            "sparse_indices batch dimension does not match "
            f"actual_seq_lengths_kv: {sparse_indices.shape[0]} vs "
            f"{ours_kv_lens.numel()}"
        )

    width = sparse_indices.shape[-1]
    rows = sparse_indices.reshape(sparse_indices.shape[0], -1, width)
    bad_rows = []
    for batch_index in range(rows.shape[0]):
        valid_count = int(ours_kv_lens[batch_index].item())
        if valid_count < 0 or valid_count > width:
            bad_rows.append(f"batch={batch_index} invalid_actual_seq_len={valid_count}")
            continue

        expected = torch.full((width,), -1, dtype=torch.long)
        expected[:valid_count] = torch.arange(valid_count, dtype=torch.long)
        for lane_index in range(rows.shape[1]):
            row = rows[batch_index, lane_index]
            if not torch.equal(row, expected):
                mismatch = (row != expected).nonzero().flatten()
                first_mismatch = int(mismatch[0].item()) if mismatch.numel() > 0 else -1
                bad_rows.append(
                    f"batch={batch_index} lane={lane_index} "
                    f"first_mismatch={first_mismatch}"
                )

    compact_indices_valid = not bad_rows
    details = (
        f"shape={list(sparse_indices.shape)} "
        f"actual_seq_lengths_kv={ours_kv_lens.tolist()}"
    )
    if bad_rows:
        details += f" bad_rows={bad_rows[:10]}"
    passed &= report(
        "ours sparse_indices == [0..K-1, -1...]",
        compact_indices_valid,
        details,
    )

    baseline_kv_lens = require_tensor(baseline, "actual_seq_lengths_kv").flatten()
    print(
        "INFO baseline actual_seq_lengths_kv "
        f"(physical/logical PA range)={baseline_kv_lens.tolist()}"
    )
    print(f"overall: {'PASS' if passed else 'FAIL'}")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
