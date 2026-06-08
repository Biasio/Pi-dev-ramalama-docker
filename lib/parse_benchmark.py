#!/usr/bin/env python3
"""Parses optimus.py's "Best config: {...}" line from stdin into a
comma-separated LLAMA_ARG_* list on stdout. Used by lib/model.sh:benchmark().

Maintenance note: key_map is empty by default (fallback: automatic
uppercasing of the param name). If optimus.py returns keys that don't map
directly to LLAMA_ARG_<UPPERCASE_KEY>, add explicit exceptions here.
"""
import sys
import re
import ast

key_map = {
    "batch": "BATCH_SIZE",
    "u_batch": "UBATCH_SIZE",
    "gpu_layers": "N_GPU_LAYERS",
}


def format_params(config: dict) -> list[str]:
    params = []
    for k, v in config.items():
        env_key = key_map.get(k.lower(), k.upper())
        if isinstance(v, bool):
            val_str = "1" if v else "0"
        else:
            val_str = str(v)
        params.append(f"LLAMA_ARG_{env_key}={val_str}")
    return params


def main() -> None:
    text = sys.stdin.read()
    matches = re.findall(r"Best config Stage_\d+:\s*(\{.*?\})", text)

    for match in reversed(matches):
        try:
            config = ast.literal_eval(match)
        except (SyntaxError, ValueError):
            continue
        if not isinstance(config, dict):
            continue
        print(",".join(format_params(config)))
        return

    print("")


if __name__ == "__main__":
    main()
