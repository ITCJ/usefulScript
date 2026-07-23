#!/usr/bin/env python3
"""Inspect tensors stored in a sparse KV debug .pt file.

Examples:
    python3 inspect_pt_tensor.py operator_inputs.pt key_rope_write
    python3 inspect_pt_tensor.py host_write.pt 'source_kv[..., -64:]'
    python3 inspect_pt_tensor.py host_write.pt \
        'source_kv[..., -64:]' 'host_readback[..., -64:]'
    python3 inspect_pt_tensor.py baseline.pt key_rope_write \
        --compare ours.pt 'source_kv[..., -64:]'
"""

from __future__ import annotations

import argparse
import ast
from pathlib import Path
from typing import Any

import torch


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Load a .pt file, select tensors from its top-level 'tensors' mapping, "
            "and print summary statistics."
        )
    )
    parser.add_argument("pt_path", type=Path, help="Path to the .pt dump file")
    parser.add_argument(
        "expressions",
        nargs="+",
        help="Tensor name with an optional slice, e.g. source_kv[..., -64:]",
    )
    parser.add_argument(
        "--compare",
        nargs=2,
        metavar=("PT_PATH", "EXPRESSION"),
        help="Compare the first selected tensor with a tensor from another PT file",
    )
    parser.add_argument(
        "--rtol",
        type=float,
        default=1e-5,
        help="Relative tolerance used by allclose (default: %(default)s)",
    )
    parser.add_argument(
        "--atol",
        type=float,
        default=1e-8,
        help="Absolute tolerance used by allclose (default: %(default)s)",
    )
    return parser.parse_args()


def load_pt(path: Path) -> Any:
    if not path.is_file():
        raise FileNotFoundError(f"PT file does not exist: {path}")

    try:
        return torch.load(path, map_location="cpu", weights_only=True)
    except TypeError:
        # Compatibility with PyTorch versions that predate weights_only.
        return torch.load(path, map_location="cpu")


def parse_integer(node: ast.AST) -> int:
    if isinstance(node, ast.Constant) and isinstance(node.value, int):
        return node.value
    if (
        isinstance(node, ast.UnaryOp)
        and isinstance(node.op, (ast.USub, ast.UAdd))
        and isinstance(node.operand, ast.Constant)
        and isinstance(node.operand.value, int)
    ):
        value = node.operand.value
        return -value if isinstance(node.op, ast.USub) else value
    raise ValueError("Only integer indices are allowed")


def parse_index(node: ast.AST) -> Any:
    if isinstance(node, ast.Tuple):
        return tuple(parse_index(item) for item in node.elts)
    if isinstance(node, ast.Slice):
        return slice(
            parse_integer(node.lower) if node.lower is not None else None,
            parse_integer(node.upper) if node.upper is not None else None,
            parse_integer(node.step) if node.step is not None else None,
        )
    if isinstance(node, ast.Constant) and node.value is Ellipsis:
        return Ellipsis
    return parse_integer(node)


def evaluate_expression(node: ast.AST, tensors: dict[str, Any]) -> Any:
    if isinstance(node, ast.Name):
        if node.id not in tensors:
            available = ", ".join(sorted(tensors))
            raise KeyError(
                f"Tensor {node.id!r} was not found. Available fields: {available}"
            )
        return tensors[node.id]
    if isinstance(node, ast.Subscript):
        value = evaluate_expression(node.value, tensors)
        return value[parse_index(node.slice)]
    raise ValueError(
        "Only a tensor name followed by optional integer/slice indexing is allowed"
    )


def select_tensor(expression: str, tensors: dict[str, Any]) -> torch.Tensor:
    try:
        parsed = ast.parse(expression, mode="eval")
        value = evaluate_expression(parsed.body, tensors)
    except (SyntaxError, KeyError, IndexError, TypeError, ValueError) as exc:
        raise ValueError(f"Invalid expression {expression!r}: {exc}") from exc

    if not isinstance(value, torch.Tensor):
        raise TypeError(
            f"Expression {expression!r} selected {type(value).__name__}, not a tensor"
        )
    return value.detach().cpu().contiguous()


def format_number(value: torch.Tensor) -> str:
    return f"{value.item():.17g}"


def print_statistics(expression: str, tensor: torch.Tensor) -> None:
    print(f"expression: {expression}")
    print(f"shape: {list(tensor.shape)}")
    print(f"dtype: {tensor.dtype}")
    print(f"numel: {tensor.numel()}")

    if tensor.numel() == 0:
        print("min: n/a")
        print("max: n/a")
        print("mean: n/a")
        print("std: n/a")
        return
    if tensor.is_complex():
        raise TypeError("Complex tensors are not supported")

    values = tensor.to(torch.float32)
    print(f"min: {format_number(values.min())}")
    print(f"max: {format_number(values.max())}")
    print(f"mean: {format_number(values.mean())}")
    print(f"std: {format_number(values.std(unbiased=False))}")

    if tensor.is_floating_point():
        print(f"nan: {int(torch.isnan(values).sum().item())}")
        print(f"inf: {int(torch.isinf(values).sum().item())}")


def get_tensors(payload: Any) -> dict[str, Any]:
    tensors = payload.get("tensors", payload) if isinstance(payload, dict) else payload
    if not isinstance(tensors, dict):
        raise TypeError(
            "Expected the PT file to contain a dictionary or a 'tensors' dictionary"
        )
    return tensors


def compare_tensors(
    left: torch.Tensor,
    right: torch.Tensor,
    *,
    rtol: float,
    atol: float,
) -> None:
    same_shape = left.shape == right.shape
    same_dtype = left.dtype == right.dtype

    print("comparison:")
    print(f"same_shape: {same_shape}")
    print(f"same_dtype: {same_dtype}")
    if not same_shape:
        print("torch_equal: False")
        print("allclose: False")
        print("different_elements: n/a")
        print("max_abs_diff: n/a")
        print("mean_abs_diff: n/a")
        return

    torch_equal = torch.equal(left, right)
    left_values = left.to(torch.float32)
    right_values = right.to(torch.float32)
    close_mask = torch.isclose(
        left_values,
        right_values,
        rtol=rtol,
        atol=atol,
        equal_nan=True,
    )
    difference = (left_values - right_values).abs()

    print(f"torch_equal: {torch_equal}")
    print(f"allclose: {bool(close_mask.all().item())}")
    print(f"rtol: {rtol:.17g}")
    print(f"atol: {atol:.17g}")
    print(f"different_elements: {int((~close_mask).sum().item())}")
    if difference.numel() == 0:
        print("max_abs_diff: n/a")
        print("mean_abs_diff: n/a")
        return
    print(f"max_abs_diff: {format_number(difference.max())}")
    print(f"mean_abs_diff: {format_number(difference.mean())}")


def main() -> int:
    args = parse_args()
    payload = load_pt(args.pt_path)
    tensors = get_tensors(payload)

    print(f"path: {args.pt_path.resolve()}")
    selected_tensors = []
    for index, expression in enumerate(args.expressions):
        if index:
            print()
        tensor = select_tensor(expression, tensors)
        selected_tensors.append(tensor)
        print_statistics(expression, tensor)

    comparison_pair = None
    if args.compare is not None:
        if len(selected_tensors) != 1:
            raise ValueError(
                "--compare requires exactly one expression for the first PT file"
            )
        other_path = Path(args.compare[0])
        other_expression = args.compare[1]
        other_tensors = get_tensors(load_pt(other_path))
        other_tensor = select_tensor(other_expression, other_tensors)
        print()
        print(f"path: {other_path.resolve()}")
        print_statistics(other_expression, other_tensor)
        comparison_pair = (selected_tensors[0], other_tensor)
    elif len(selected_tensors) == 2:
        comparison_pair = (selected_tensors[0], selected_tensors[1])

    if comparison_pair is not None:
        print()
        compare_tensors(
            *comparison_pair,
            rtol=args.rtol,
            atol=args.atol,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
