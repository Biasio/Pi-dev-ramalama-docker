#!/bin/bash
# lib/model.sh — Manages models' lifecycle: pull, benchmark, param bookkeeping, removal.

# Atomically replaces or appends one MODEL_PARAMS entry in env.conf.
update_model_params() {
    local MODEL_NAME="$1" PARAMS="$2"
    echo "[System] Updating $MODELS_CONFIG_FILE..."
    awk -v target="MODEL_PARAMS[\"$MODEL_NAME\"]" 'index($0, target) != 1' "$MODELS_CONFIG_FILE" > "${MODELS_CONFIG_FILE}.tmp"
    mv "${MODELS_CONFIG_FILE}.tmp" "$MODELS_CONFIG_FILE"
    echo "MODEL_PARAMS[\"$MODEL_NAME\"]=\"$PARAMS\"" >> "$MODELS_CONFIG_FILE"
}

# Pulls a model via ramalama, optionally benchmarks it, and records its
# params (or the shared default) in MODELS_CONFIG_FILE.
pull_model() {
    local MODEL_URI="$1"
    if [ -z "$MODEL_URI" ]; then
        echo "[Error] Missing model URI."
        exit 1
    fi

    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
    [ -f "$MODELS_CONFIG_FILE" ] && source "$MODELS_CONFIG_FILE"
    resolve_ramalama || exit 1

    echo "[Ramalama] Pulling $MODEL_URI..."
    set +e
    ramalama pull "$MODEL_URI"
    local PULL_STATUS=$?
    set -e

    if [ $PULL_STATUS -ne 0 ]; then
        echo "[Error] Pull failed."
        exit 1
    fi

    local MODEL_NAME
    MODEL_NAME=$(echo "$MODEL_URI" | sed -E 's|^[a-z]+://||')

    read -p "[Benchmark] Run llama-optimus (isolated container)? Requires $ENGINE. [y/N]: " RUN_BENCH
    local NEW_PARAMS="${DEFAULT_MODEL_PARAMS}"

    if [[ "$RUN_BENCH" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        benchmark "$MODEL_NAME" && NEW_PARAMS="${LAST_BENCHMARK_PARAMS:-$NEW_PARAMS}"
    fi

    update_model_params "$MODEL_NAME" "$NEW_PARAMS"
}

# Interactively removes a pulled model and its MODEL_PARAMS entry.
remove_model() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
    [ -f "$MODELS_CONFIG_FILE" ] && source "$MODELS_CONFIG_FILE"
    resolve_ramalama || exit 1

    mapfile -t MODELS < <(ramalama list | awk 'NR>1 {print $1}')
    [ ${#MODELS[@]} -eq 0 ] && echo "No models available." && exit 1

    for i in "${!MODELS[@]}"; do echo "$((i+1))) ${MODELS[$i]}"; done
    read -p "Select model to remove: " SELECTION
    local MODEL_NAME="${MODELS[$((SELECTION-1))]}"
    [ -z "$MODEL_NAME" ] && exit 1

    set +e
    ramalama rm "$MODEL_NAME"
    set -e

    awk -v target="MODEL_PARAMS[\"$MODEL_NAME\"]" 'index($0, target) != 1' "$MODELS_CONFIG_FILE" > "${MODELS_CONFIG_FILE}.tmp"
    mv "${MODELS_CONFIG_FILE}.tmp" "$MODELS_CONFIG_FILE"
}

# Runs llama-optimus AND its output parser in isolated containers to derive optimal llama.cpp params
# for a model, then stores them via update_model_params.
benchmark() {
    local MODEL_NAME="$1"
    local MODEL_PATH_HOST="${2:-}"

    if [ -z "$MODEL_PATH_HOST" ]; then
        # RamaLama's on-disk layout varies by transport
        # (huggingface/ollama/oci) and by install method, so search the whole
        # home tree for anything matching the model's basename.
        local NEEDLE="${MODEL_NAME##*/}"
        NEEDLE="${NEEDLE%%:*}"
        local DIR_MATCHES=()

        mapfile -t DIR_MATCHES < <(find "$HOME" -xdev \
             \( -path '*/.cache/*' -o -path '*/.git/*' -o -path '*/node_modules/*' \) -prune -o \
             \( -type d -o -type l \) -iname "*${NEEDLE}*" -print 2>/dev/null)

        # Expand each matched dir into any .gguf files under it
        local MATCHES=()
        local d f
        for d in "${DIR_MATCHES[@]}"; do
            [ -d "$d" ] || continue
            while IFS= read -r f; do
                MATCHES+=("$f")
            done < <(find "$d" \( -type f -o -type l \) -iname '*.gguf' 2>/dev/null)
        done

        case "${#MATCHES[@]}" in
            1)
                echo "[Benchmark] Found on host: ${MATCHES[0]}"
                read -p "[Benchmark] Use this path? [Y/n]: " CONFIRM
                if [[ "$CONFIRM" =~ ^([nN][oO]|[nN])$ ]]; then
                    read -p "[Benchmark] Actual model file path on host (empty to cancel): " MODEL_PATH_HOST
                else
                    MODEL_PATH_HOST="${MATCHES[0]}"
                fi
                ;;
            0)
                echo "[Notice] No .gguf match for '$NEEDLE' under $HOME"
                ;;
            *)
                echo "[Notice] Multiple .gguf files found for '$NEEDLE' (e.g. different quantizations):"
                for i in "${!MATCHES[@]}"; do echo "  $((i+1))) ${MATCHES[$i]}"; done
                read -p "[Benchmark] Select one (empty to enter a path manually): " SELECTION
                if [ -n "$SELECTION" ]; then
                    MODEL_PATH_HOST="${MATCHES[$((SELECTION-1))]:-}"
                fi
                ;;
        esac
    fi

    if [ -z "$MODEL_PATH_HOST" ] || [ ! -e "$MODEL_PATH_HOST" ]; then
        read -p "[Benchmark] Actual model file path on host (empty to cancel): " MODEL_PATH_HOST
        if [ -z "$MODEL_PATH_HOST" ] || [ ! -e "$MODEL_PATH_HOST" ]; then
            echo "[Error] Model path not found on host: ${MODEL_PATH_HOST:-<empty>}"
            return 1
        fi
    fi

    export MODEL_DIR_HOST
    if [[ "$MODEL_PATH_HOST" == *"/snapshots/"* ]]; then
        MODEL_DIR_HOST="${MODEL_PATH_HOST%%/snapshots/*}"
    else
        MODEL_DIR_HOST="$(dirname "$MODEL_PATH_HOST")"
    fi
    export MODEL_PATH_CONTAINER_DIR="/models"
    export MODEL_PATH_CONTAINER="/models${MODEL_PATH_HOST#"$MODEL_DIR_HOST"}"

    echo "[Benchmark] Starting llama-optimus container..."
    cd "$DIR"
    local RAW_OUTPUT
    RAW_OUTPUT=$(compose --profile benchmark run --rm llama-optimus --model "$MODEL_PATH_CONTAINER" 2>&1)
    echo "$RAW_OUTPUT"

    # Parses optimus.py's "Best config: {...}" output via lib/parse_benchmark.py
    # It runs INSIDE the llama-optimus container
    LAST_BENCHMARK_PARAMS=$(echo "$RAW_OUTPUT" | compose --profile benchmark run --rm -T \
        --entrypoint python3 \
        -v "$DIR/lib/parse_benchmark.py:/opt/parse_benchmark.py:ro,Z" \
        llama-optimus /opt/parse_benchmark.py)

    if [ -n "$LAST_BENCHMARK_PARAMS" ]; then
        echo "[Benchmark] Extracted params: $LAST_BENCHMARK_PARAMS"
        update_model_params "$MODEL_NAME" "$LAST_BENCHMARK_PARAMS"
    else
        echo "[Error] Parsing failed, no params extracted. Check the output above."
        return 1
    fi
}



# CLI entry point for benchmark(): resolves a model by URI or interactive
# selection, then runs it.
benchmark_cli() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
    [ -f "$MODELS_CONFIG_FILE" ] && source "$MODELS_CONFIG_FILE"
    resolve_ramalama || exit 1
    ensure_environment

    local TARGET_INPUT="${1:-}"
    local MODEL_NAME=""

    if [ -n "$TARGET_INPUT" ]; then
        MODEL_NAME=$(echo "$TARGET_INPUT" | sed -E 's|^[a-z]+://||')
    else
        mapfile -t MODELS < <(ramalama list | awk 'NR>1 {print $1}')
        if [ ${#MODELS[@]} -eq 0 ]; then
            echo "[Error] No models available in RamaLama to benchmark."
            exit 1
        fi
        echo "Models available for benchmarking:"
        for i in "${!MODELS[@]}"; do
            echo "  $((i+1))) ${MODELS[$i]}"
        done
        read -p "Select the model to analyze: " SELECTION
        MODEL_NAME="${MODELS[$((SELECTION-1))]}"
        if [ -z "$MODEL_NAME" ]; then
            echo "[Error] Invalid selection."
            exit 1
        fi
    fi

    benchmark "$MODEL_NAME"
}
