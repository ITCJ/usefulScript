#!/usr/bin/env python3
"""Inspect tensors stored in a sparse KV debug .pt file.

Examples:
    python3 inspect_pt_tensor.py operator_inputs.pt key_rope_write
    python3 inspect_pt_tensor.py host_write.pt 'source_kv[..., -64:]'
    python3 inspect_pt_tensor.py host_write.pt \
        'source_kv[..., -64:]' 'host_readback[..., -64:]'
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


def main() -> int:
    args = parse_args()
    payload = load_pt(args.pt_path)
    tensors = payload.get("tensors", payload) if isinstance(payload, dict) else payload
    if not isinstance(tensors, dict):
        raise TypeError(
            "Expected the PT file to contain a dictionary or a 'tensors' dictionary"
        )

    print(f"path: {args.pt_path.resolve()}")
    for index, expression in enumerate(args.expressions):
        if index:
            print()
        tensor = select_tensor(expression, tensors)
        print_statistics(expression, tensor)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
