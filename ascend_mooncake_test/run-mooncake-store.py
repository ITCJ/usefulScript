#!/usr/bin/env python3
"""Initialize one Ascend device, then run Mooncake Store in the same process."""

import asyncio
import os

import torch
import torch_npu  # noqa: F401


def main() -> None:
    logical_device_id = int(os.environ.get("MOONCAKE_STORE_LOGICAL_NPU_ID", "0"))
    device_count = torch.npu.device_count()
    if device_count <= logical_device_id:
        raise RuntimeError(
            f"Mooncake Store requires logical NPU {logical_device_id}, "
            f"but torch_npu sees only {device_count} device(s)"
        )

    torch.npu.set_device(logical_device_id)
    print(
        "Mooncake Store Ascend context initialized:",
        f"logical_device={logical_device_id}",
        f"visible_device_count={device_count}",
        flush=True,
    )

    # Import only after set_device so Ascend-linked native components inherit
    # a valid ACL context in this same long-running process.
    from mooncake.mooncake_store_service import main as store_main

    asyncio.run(store_main())


if __name__ == "__main__":
    main()
