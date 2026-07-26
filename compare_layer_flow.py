#!/usr/bin/env python3
"""Compare ordered DeepSeek layer-flow dumps and locate the first difference.

Example:
    python3 compare_layer_flow.py \
        /path/to/base/iter_1/tensor_dump \
        /path/to/ours/iter_1/tensor_dump \
        --phase decode --call 22 --layer 6
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path

import torch

from inspect_pt_tensor import get_tensors, load_pt, select_tensor


@dataclass(frozen=True)
class TensorCheck:
    stage: str
    layer: int
    checkpoint: str
    expression: str

    @property
    def label(self) -> str:
        return (
            f"layer_{self.layer:03d}/{self.stage}/{self.checkpoint}:{self.expression}"
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Compare baseline and ours in execution order and report the first "
            "non-bitwise-identical layer checkpoint."
        )
    )
    parser.add_argument("baseline_dump", type=Path)
    parser.add_argument("ours_dump", type=Path)
    parser.add_argument("--phase", choices=("prefill", "decode"), default="decode")
    parser.add_argument("--call", type=int, default=22, dest="call_id")
    parser.add_argument("--layer", type=int, default=6)
    parser.add_argument("--rank", type=int, default=0)
    parser.add_argument("--rtol", type=float, default=1e-5)
    parser.add_argument("--atol", type=float, default=1e-8)
    parser.add_argument(
        "--no-next-layer",
        action="store_true",
        help="Do not compare the next layer's input and sparse-attention query.",
    )
    parser.add_argument(
        "--stop-on-diff",
        action="store_true",
        help="Stop immediately after the first non-exact result.",
    )
    return parser.parse_args()


def build_checks(layer: int, include_next_layer: bool) -> list[TensorCheck]:
    checks = [
        TensorCheck("layer_flow", layer, "layer_input", "hidden_states"),
        TensorCheck("layer_flow", layer, "layer_input", "residual"),
        TensorCheck(
            "layer_flow",
            layer,
            "attention_input",
            "hidden_states_after_comm_pre_attn",
        ),
        TensorCheck(
            "layer_flow",
            layer,
            "attention_input",
            "residual_after_input_ln",
        ),
        TensorCheck(
            "mla_post_attention",
            layer,
            "operator_output",
            "attention_output",
        ),
        TensorCheck(
            "mla_post_attention",
            layer,
            "operator_output",
            "attn_bmm_output",
        ),
        TensorCheck(
            "mla_post_attention",
            layer,
            "operator_output",
            "o_proj_output",
        ),
        TensorCheck(
            "layer_flow",
            layer,
            "attention_module_output",
            "hidden_states_after_attn",
        ),
        TensorCheck(
            "layer_flow",
            layer,
            "mlp_input",
            "hidden_states_mlp_input",
        ),
        TensorCheck(
            "layer_flow",
            layer,
            "mlp_input",
            "residual_after_comm_pre_mlp",
        ),
        TensorCheck(
            "layer_flow",
            layer,
            "mlp_output",
            "hidden_states_mlp_output",
        ),
        TensorCheck("layer_flow", layer, "layer_output", "hidden_states"),
        TensorCheck("layer_flow", layer, "layer_output", "residual"),
    ]
    if include_next_layer:
        next_layer = layer + 1
        checks.extend(
            [
                TensorCheck(
                    "layer_flow",
                    next_layer,
                    "layer_input",
                    "hidden_states",
                ),
                TensorCheck(
                    "layer_flow",
                    next_layer,
                    "layer_input",
                    "residual",
                ),
                TensorCheck(
                    "layer_flow",
                    next_layer,
                    "attention_input",
                    "hidden_states_after_comm_pre_attn",
                ),
                TensorCheck(
                    "layer_flow",
                    next_layer,
                    "attention_input",
                    "residual_after_input_ln",
                ),
                TensorCheck(
                    "sparse_attention",
                    next_layer,
                    "operator_inputs",
                    "query.flatten()",
                ),
                TensorCheck(
                    "sparse_attention",
                    next_layer,
                    "operator_inputs",
                    "query_rope.flatten()",
                ),
            ]
        )
    return checks


def rank_root(dump_root: Path, rank: int) -> Path:
    expected_name = f"rank_{rank:03d}"
    if dump_root.name == expected_name:
        result = dump_root
    else:
        result = dump_root / expected_name
    if not result.is_dir():
        raise FileNotFoundError(f"Rank dump directory does not exist: {result}")
    return result


def checkpoint_path(
    root: Path,
    check: TensorCheck,
    *,
    phase: str,
    call_id: int,
) -> Path:
    return (
        root
        / check.stage
        / phase
        / f"layer_{check.layer:03d}"
        / f"call_{call_id:05d}"
        / f"{check.checkpoint}.pt"
    )


def compare(
    left: torch.Tensor,
    right: torch.Tensor,
    *,
    rtol: float,
    atol: float,
) -> tuple[str, str]:
    same_shape = left.shape == right.shape
    same_dtype = left.dtype == right.dtype
    if not same_shape:
        return "DIFFERENT", f"shape={list(left.shape)} vs {list(right.shape)}"

    exact = same_dtype and torch.equal(left, right)
    if exact:
        return "EXACT", f"shape={list(left.shape)} dtype={left.dtype}"

    if left.is_complex() or right.is_complex():
        return "DIFFERENT", "complex tensors are not supported"

    left_values = left.to(torch.float32)
    right_values = right.to(torch.float32)
    if left.is_floating_point() or right.is_floating_point():
        close_mask = torch.isclose(
            left_values,
            right_values,
            rtol=rtol,
            atol=atol,
            equal_nan=True,
        )
    else:
        close_mask = left_values == right_values

    difference = (left_values - right_values).abs()
    different_elements = int((~close_mask).sum().item())
    max_abs_diff = float(difference.max().item()) if difference.numel() > 0 else 0.0
    status = "CLOSE" if bool(close_mask.all().item()) else "DIFFERENT"
    details = (
        f"shape={list(left.shape)} dtype={left.dtype}/{right.dtype} "
        f"different_elements={different_elements} "
        f"max_abs_diff={max_abs_diff:.17g}"
    )
    return status, details


def diagnosis(first_check: TensorCheck) -> str:
    field = first_check.expression
    checkpoint = first_check.checkpoint
    if checkpoint == "layer_input":
        return (
            f"Difference already exists at layer {first_check.layer} input; "
            f"compare layer {first_check.layer - 1} layer_output next."
        )
    if checkpoint == "attention_input":
        return "First difference is in prepare_attn/input norm or residual handling."
    if field == "attention_output":
        return "First difference is produced by sparse attention."
    if field == "attn_bmm_output":
        return "First difference is produced by w_vc/batch_matmul_transpose."
    if field == "o_proj_output":
        return "First difference is produced by o_proj."
    if checkpoint == "mlp_input":
        return "First difference is in prepare_mlp/residual add/post-attention norm."
    if checkpoint == "mlp_output":
        return "First difference is produced by the MLP/MoE."
    if checkpoint == "layer_output":
        return "First difference is in layer postprocessing/residual communication."
    return "The first difference is at the reported checkpoint."


def main() -> int:
    args = parse_args()
    if args.call_id < 0 or args.layer < 0 or args.rank < 0:
        raise ValueError("--call, --layer, and --rank must be non-negative")

    baseline_root = rank_root(args.baseline_dump, args.rank)
    ours_root = rank_root(args.ours_dump, args.rank)
    checks = build_checks(args.layer, not args.no_next_layer)

    first_non_exact: TensorCheck | None = None
    errors = 0
    counts = {"EXACT": 0, "CLOSE": 0, "DIFFERENT": 0}

    for check in checks:
        baseline_path = checkpoint_path(
            baseline_root,
            check,
            phase=args.phase,
            call_id=args.call_id,
        )
        ours_path = checkpoint_path(
            ours_root,
            check,
            phase=args.phase,
            call_id=args.call_id,
        )
        try:
            baseline_tensor = select_tensor(
                check.expression,
                get_tensors(load_pt(baseline_path)),
            )
            ours_tensor = select_tensor(
                check.expression,
                get_tensors(load_pt(ours_path)),
            )
            status, details = compare(
                baseline_tensor,
                ours_tensor,
                rtol=args.rtol,
                atol=args.atol,
            )
            counts[status] += 1
            print(f"{status:<9} {check.label} {details}")
        except (
            FileNotFoundError,
            KeyError,
            RuntimeError,
            TypeError,
            ValueError,
        ) as exc:
            status = "ERROR"
            errors += 1
            print(f"{status:<9} {check.label} {exc}")

        if status != "EXACT" and first_non_exact is None:
            first_non_exact = check
        if args.stop_on_diff and status != "EXACT":
            break

    print(
        "summary: "
        f"exact={counts['EXACT']} close={counts['CLOSE']} "
        f"different={counts['DIFFERENT']} error={errors}"
    )
    if first_non_exact is None:
        print("first_non_exact: none")
        return 0

    print(f"first_non_exact: {first_non_exact.label}")
    if errors == 0:
        print(f"diagnosis: {diagnosis(first_non_exact)}")
    return 2 if errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
