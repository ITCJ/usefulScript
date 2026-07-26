#!/usr/bin/env python3
"""Replay the two NPU sparse-flash-attention paths from saved PT dumps.

The baseline path is replayed as TND + PA_BSND + sparse_mode=3.
The offload path is replayed as BSND + BSND + sparse_mode=0.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

import torch
import torch_npu


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-input", type=Path, required=True)
    parser.add_argument("--baseline-output", type=Path, required=True)
    parser.add_argument("--ours-input", type=Path, required=True)
    parser.add_argument("--ours-output", type=Path, required=True)
    parser.add_argument(
        "--model-config",
        type=Path,
        help="Model config.json used to reproduce the MLA/YaRN scale",
    )
    parser.add_argument(
        "--scale",
        type=float,
        help="Exact scale_value; overrides --model-config",
    )
    parser.add_argument("--device", default="npu:0")
    parser.add_argument(
        "--repeats",
        type=int,
        default=3,
        help="Recorded invocations per path after one warmup (default: %(default)s)",
    )
    parser.add_argument("--rtol", type=float, default=1e-5)
    parser.add_argument("--atol", type=float, default=1e-8)
    return parser.parse_args()


def load_pt(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise FileNotFoundError(f"PT file does not exist: {path}")
    try:
        payload = torch.load(path, map_location="cpu", weights_only=True)
    except TypeError:
        payload = torch.load(path, map_location="cpu")
    tensors = payload.get("tensors", payload) if isinstance(payload, dict) else payload
    if not isinstance(tensors, dict):
        raise TypeError(f"{path}: expected a tensor dictionary")
    return tensors


def require_tensor(
    tensors: dict[str, Any], name: str, source: Path
) -> torch.Tensor:
    value = tensors.get(name)
    if not isinstance(value, torch.Tensor):
        available = ", ".join(sorted(tensors))
        raise KeyError(
            f"{source}: required tensor {name!r} is missing; "
            f"available fields: {available}"
        )
    return value.detach().cpu().contiguous()


def find_config_value(config: dict[str, Any], name: str) -> Any:
    if name in config:
        return config[name]
    text_config = config.get("text_config")
    if isinstance(text_config, dict) and name in text_config:
        return text_config[name]
    return None


def yarn_get_mscale(factor: float, mscale: float) -> float:
    if factor <= 1:
        return 1.0
    return 0.1 * mscale * math.log(factor) + 1.0


def resolve_scale(
    args: argparse.Namespace,
    baseline_tensors: dict[str, Any],
) -> tuple[float, str]:
    if args.scale is not None:
        return args.scale, "--scale"

    query_rope = require_tensor(
        baseline_tensors, "query_rope", args.baseline_input
    )
    if args.model_config is None:
        raise ValueError(
            "The absorbed MLA query width in the dump is not the original "
            "qk_nope_head_dim, so scale_value cannot be inferred safely. "
            "Provide --model-config or --scale."
        )

    if not args.model_config.is_file():
        raise FileNotFoundError(f"Model config does not exist: {args.model_config}")
    with args.model_config.open(encoding="utf-8") as file:
        config = json.load(file)
    if not isinstance(config, dict):
        raise TypeError(f"{args.model_config}: expected a JSON object")

    configured_nope = find_config_value(config, "qk_nope_head_dim")
    configured_rope = find_config_value(config, "qk_rope_head_dim")
    if configured_nope is None or configured_rope is None:
        raise KeyError(
            f"{args.model_config}: qk_nope_head_dim and qk_rope_head_dim "
            "are required"
        )
    configured_nope = int(configured_nope)
    configured_rope = int(configured_rope)
    if configured_rope != query_rope.shape[-1]:
        raise ValueError(
            "qk_rope_head_dim does not match the dump: "
            f"config={configured_rope}, dump={query_rope.shape[-1]}"
        )
    qk_head_dim = configured_nope + configured_rope
    scale = qk_head_dim**-0.5
    source = (
        f"config dimensions: ({configured_nope} + {configured_rope})^-0.5"
    )

    rope_scaling = find_config_value(config, "rope_scaling")
    if isinstance(rope_scaling, dict) and rope_scaling.get(
        "apply_yarn_scaling", True
    ):
        factor = float(rope_scaling.get("factor", 1.0))
        mscale_all_dim = float(rope_scaling.get("mscale_all_dim", False))
        mscale = yarn_get_mscale(factor, mscale_all_dim)
        scale *= mscale * mscale
        source += (
            f", YaRN factor={factor:g}, mscale_all_dim={mscale_all_dim:g}"
        )
    source += f", config={args.model_config}"
    return scale, source


def to_device(tensor: torch.Tensor, device: torch.device) -> torch.Tensor:
    return tensor.to(device=device, non_blocking=False).contiguous()


def remap_block_table(
    block_table: torch.Tensor,
    active_page_ids: torch.Tensor,
) -> torch.Tensor:
    page_ids = active_page_ids.to(torch.long).flatten()
    if page_ids.numel() == 0:
        raise ValueError("active_page_ids is empty")
    if torch.unique(page_ids).numel() != page_ids.numel():
        raise ValueError("active_page_ids contains duplicates")

    original = block_table.to(torch.long)
    remapped = torch.full_like(original, -1)
    for compact_id, physical_id in enumerate(page_ids.tolist()):
        remapped[original == physical_id] = compact_id

    negative_padding = original < 0
    remapped[negative_padding] = 0
    missing = torch.unique(original[(remapped < 0) & (~negative_padding)])
    if missing.numel() > 0:
        raise ValueError(
            "block_table references pages absent from active_page_ids: "
            f"{missing[:20].tolist()}"
        )
    return remapped.to(dtype=block_table.dtype).contiguous()


def first_output(result: Any) -> torch.Tensor:
    output = result[0] if isinstance(result, tuple) else result
    if not isinstance(output, torch.Tensor):
        raise TypeError(f"Kernel returned {type(output).__name__}, not a tensor")
    return output


def normalize_output(
    output: torch.Tensor,
    saved_output: torch.Tensor,
    path_name: str,
) -> torch.Tensor:
    if output.numel() == saved_output.numel():
        return output.reshape(saved_output.shape)

    # The compact BSND kernel may return padded query heads. The serving path
    # removes them before saving operator_output.pt.
    if output.dim() == 4 and saved_output.numel() % output.shape[-1] == 0:
        prefix = math.prod(output.shape[:-2])
        wanted_heads = saved_output.numel() // (prefix * output.shape[-1])
        if 0 < wanted_heads <= output.shape[-2]:
            sliced = output[..., :wanted_heads, :]
            if sliced.numel() == saved_output.numel():
                return sliced.reshape(saved_output.shape)

    raise ValueError(
        f"{path_name} replay output cannot be normalized to its saved output: "
        f"replay={list(output.shape)}, saved={list(saved_output.shape)}"
    )


def replay_baseline(
    tensors: dict[str, Any],
    source: Path,
    saved_output: torch.Tensor,
    device: torch.device,
    scale: float,
) -> torch.Tensor:
    query = to_device(require_tensor(tensors, "query", source), device)
    key = to_device(require_tensor(tensors, "key_active_pages", source), device)
    key_rope = to_device(
        require_tensor(tensors, "key_rope_active_pages", source), device
    )
    block_table = remap_block_table(
        require_tensor(tensors, "block_table", source),
        require_tensor(tensors, "active_page_ids", source),
    )

    result = torch_npu.npu_sparse_flash_attention(
        query=query,
        key=key,
        value=key,
        query_rope=to_device(
            require_tensor(tensors, "query_rope", source), device
        ),
        key_rope=key_rope,
        sparse_indices=to_device(
            require_tensor(tensors, "topk_indices", source), device
        ),
        scale_value=scale,
        actual_seq_lengths_query=to_device(
            require_tensor(tensors, "actual_seq_lengths_query", source).to(
                torch.int32
            ),
            device,
        ),
        actual_seq_lengths_kv=to_device(
            require_tensor(tensors, "actual_seq_lengths_kv", source).to(
                torch.int32
            ),
            device,
        ),
        block_table=to_device(block_table, device),
        sparse_block_size=1,
        layout_query="TND",
        layout_kv="PA_BSND",
        sparse_mode=3,
        attention_mode=2,
        return_softmax_lse=False,
    )
    return normalize_output(first_output(result), saved_output, "baseline")


def replay_ours(
    tensors: dict[str, Any],
    source: Path,
    saved_output: torch.Tensor,
    device: torch.device,
    scale: float,
) -> torch.Tensor:
    query = to_device(require_tensor(tensors, "query", source), device)
    key = to_device(require_tensor(tensors, "key", source), device)

    result = torch_npu.npu_sparse_flash_attention(
        query,
        key,
        key,
        to_device(require_tensor(tensors, "sparse_indices", source), device),
        scale,
        actual_seq_lengths_query=to_device(
            require_tensor(tensors, "actual_seq_lengths_query", source).to(
                torch.int32
            ),
            device,
        ),
        actual_seq_lengths_kv=to_device(
            require_tensor(tensors, "actual_seq_lengths_kv", source).to(
                torch.int32
            ),
            device,
        ),
        query_rope=to_device(
            require_tensor(tensors, "query_rope", source), device
        ),
        key_rope=to_device(
            require_tensor(tensors, "key_rope", source), device
        ),
        sparse_block_size=1,
        layout_query="BSND",
        layout_kv="BSND",
        sparse_mode=0,
        attention_mode=2,
        return_softmax_lse=False,
    )
    return normalize_output(first_output(result), saved_output, "ours")


def compare(
    name: str,
    left: torch.Tensor,
    right: torch.Tensor,
    *,
    rtol: float,
    atol: float,
) -> None:
    left = left.detach().cpu().contiguous()
    right = right.detach().cpu().contiguous()
    print(f"\n===== {name} =====")
    print(
        f"left: shape={list(left.shape)} dtype={left.dtype}; "
        f"right: shape={list(right.shape)} dtype={right.dtype}"
    )
    if left.numel() != right.numel():
        print("same_numel: False")
        return

    left = left.flatten()
    right = right.flatten()
    left_float = left.float()
    right_float = right.float()
    finite = torch.isfinite(left_float) & torch.isfinite(right_float)
    close = torch.isclose(
        left_float, right_float, rtol=rtol, atol=atol, equal_nan=True
    )
    exact = torch.eq(left, right) | (
        torch.isnan(left_float) & torch.isnan(right_float)
    )
    difference = (left_float - right_float).abs()
    finite_difference = difference[finite]

    print(f"torch_equal: {torch.equal(left, right)}")
    print(f"allclose: {bool(close.all().item())}")
    print(f"exact_different_elements: {int((~exact).sum().item())}")
    print(f"not_close_elements: {int((~close).sum().item())}")
    if finite_difference.numel() > 0:
        print(f"max_abs_diff: {finite_difference.max().item():.17g}")
        print(f"mean_abs_diff: {finite_difference.mean().item():.17g}")

    mismatch = (~exact).nonzero().flatten()
    if mismatch.numel() > 0:
        index = int(mismatch[0].item())
        print(
            f"first_exact_difference: flat_index={index} "
            f"left={left_float[index].item():.17g} "
            f"right={right_float[index].item():.17g}"
        )


def run_repeated(
    name: str,
    function: Any,
    repeats: int,
    device: torch.device,
    rtol: float,
    atol: float,
) -> list[torch.Tensor]:
    function()  # Warm up allocations and the operator path.
    torch.npu.synchronize(device)
    outputs = []
    for _ in range(repeats):
        output = function()
        torch.npu.synchronize(device)
        outputs.append(output.detach().cpu().contiguous())
    for index, output in enumerate(outputs[1:], start=2):
        compare(
            f"{name} replay #1 vs #{index}",
            outputs[0],
            output,
            rtol=rtol,
            atol=atol,
        )
    return outputs


def main() -> int:
    args = parse_args()
    if args.repeats < 1:
        raise ValueError("--repeats must be at least 1")

    baseline_tensors = load_pt(args.baseline_input)
    ours_tensors = load_pt(args.ours_input)
    baseline_output_tensors = load_pt(args.baseline_output)
    ours_output_tensors = load_pt(args.ours_output)
    saved_baseline = require_tensor(
        baseline_output_tensors, "attention_output", args.baseline_output
    )
    saved_ours = require_tensor(
        ours_output_tensors, "attention_output", args.ours_output
    )
    scale, scale_source = resolve_scale(args, baseline_tensors)

    device = torch.device(args.device)
    torch.npu.set_device(device)
    print(f"device: {device}")
    print(f"scale_value: {scale:.17g}")
    print(f"scale_source: {scale_source}")
    print(
        "baseline path: layout_query=TND layout_kv=PA_BSND sparse_mode=3"
    )
    print("ours path: layout_query=BSND layout_kv=BSND sparse_mode=0")

    baseline_outputs = run_repeated(
        "baseline",
        lambda: replay_baseline(
            baseline_tensors,
            args.baseline_input,
            saved_baseline,
            device,
            scale,
        ),
        args.repeats,
        device,
        args.rtol,
        args.atol,
    )
    ours_outputs = run_repeated(
        "ours",
        lambda: replay_ours(
            ours_tensors,
            args.ours_input,
            saved_ours,
            device,
            scale,
        ),
        args.repeats,
        device,
        args.rtol,
        args.atol,
    )

    compare(
        "saved baseline vs saved ours",
        saved_baseline,
        saved_ours,
        rtol=args.rtol,
        atol=args.atol,
    )
    compare(
        "baseline replay vs saved baseline",
        baseline_outputs[0],
        saved_baseline,
        rtol=args.rtol,
        atol=args.atol,
    )
    compare(
        "ours replay vs saved ours",
        ours_outputs[0],
        saved_ours,
        rtol=args.rtol,
        atol=args.atol,
    )
    compare(
        "baseline replay vs ours replay",
        baseline_outputs[0],
        ours_outputs[0],
        rtol=args.rtol,
        atol=args.atol,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
