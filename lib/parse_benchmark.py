#!/usr/bin/env python3
"""Parses optimus.py's "Best config: {...}" line from stdin into a
comma-separated LLAMA_ARG_* list on stdout. Used by lib/model.sh:benchmark().

Maintenance note: key_map is empty by default (fallback: automatic
uppercasing of the param name). If optimus.py returns keys that don't map
directly to LLAMA_ARG_<UPPERCASE_KEY>, add explicit exceptions here.

override_tensor is a special case: optimus.py's search_space.py reports it
as a short preset name (e.g. "ffn_cpu_up"), not the --override-tensor value
llama.cpp actually expects. OVERRIDE_PATTERNS below is copied from the
pinned llama-optimus commit's src/llama_optimus/override_patterns.py
(OPTIMUS_COMMIT in optimus/Dockerfile) and must be kept in sync with it if
that commit is ever bumped.
"""
import sys
import re
import ast

key_map = {
    "batch": "BATCH_SIZE",
    "u_batch": "UBATCH_SIZE",
    "gpu_layers": "N_GPU_LAYERS",
}

OVERRIDE_PATTERNS = {
    "none": "",
    "ffn_cpu_all": r"blk\.\d+\.ffn_.*_exps\.=CPU",
    "ffn_cpu_even": r"blk\.(?:[0-9]*[02468])\.ffn_.*_exps\.=CPU",
    "ffn_cpu_odd": r"blk\.(?:[0-9]*[13579])\.ffn_.*_exps\.=CPU",
    "ffn_cpu_updown": r"blk\.\d+\.ffn_(?:up|down)_exps\.=CPU",
    "ffn_cpu_up": r"blk\.\d+\.ffn_up_exps\.=CPU",
    "ffn_cpu_down": r"blk\.\d+\.ffn_down_exps\.=CPU",
    "ffn_cpu_last_quarter": r"blk\.(6[0-9]|7[0-9])\.ffn_.*_exps\.=CPU",
    "ffn_cpu_from_6": r"blk\.(6|7|8|9|[1-9][0-9]+)\.ffn_.*_exps\.=CPU",
}


def format_params(config: dict) -> list[str]:
    params = []
    for k, v in config.items():
        if k.lower() == "override_tensor":
            pattern = OVERRIDE_PATTERNS.get(v)
            if pattern is None:
                # Unknown preset name: pass it through raw rather than
                # silently dropping it, so a future optimus.py preset
                # isn't lost without a trace.
                pattern = v
            if pattern == "":
                continue
            params.append(f"LLAMA_ARG_OVERRIDE_TENSOR={pattern}")
            continue
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
