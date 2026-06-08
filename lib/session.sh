#!/bin/bash
# lib/session.sh — interactive/RPC session lifecycle.


# Tears down ramalama and pi-agent. Only registered inside start_env (the
# interactive session), never globally, so it can't kill a persistent RPC
# environment as a side effect of an unrelated command.
cleanup() {
    echo -e "\n[System] Shutting down..."

    if [ -n "${RAMALAMA_PID:-}" ] && kill -0 "$RAMALAMA_PID" 2>/dev/null; then
        echo "[Ramalama] Stopping PID $RAMALAMA_PID..."
        kill "$RAMALAMA_PID" || true
    fi

    echo "[Ramalama] Stopping remaining containers..."
    ramalama stop --all >/dev/null 2>&1 || true

    echo "[Compose] Stopping pi-agent..."
    cd "$DIR" && compose stop >/dev/null 2>&1 || true
    exit 0
}

# Interactive session: pick a model, serve it, launch pi-agent, attach in
# TUI. Tears everything down on exit (see cleanup). RPC is not offered here.
start_env() {
    trap cleanup EXIT SIGINT SIGTERM SIGHUP

    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
    [ -f "$MODELS_CONFIG_FILE" ] && source "$MODELS_CONFIG_FILE"
    resolve_ramalama || exit 1

    ensure_environment

    MODEL_PORT="${MODEL_PORT:-8080}"
    export MODEL_PORT

    mapfile -t MODELS < <(ramalama list | awk 'NR>1 {print $1}')
    [ ${#MODELS[@]} -eq 0 ] && echo "[Error] No models found in RamaLama." && exit 1

    for i in "${!MODELS[@]}"; do echo "$((i+1))) ${MODELS[$i]}"; done

    read -p "Select the model to start: " SELECTION
    local MODEL="${MODELS[$((SELECTION-1))]}"
    [ -z "$MODEL" ] && exit 1

    # pi.dev/docs/latest/usage#cli-reference: 'pi' with no args starts the
    # TUI; any args passed to start_env (e.g. '--session <id>') are forwarded
    # to the same 'pi' invocation so callers get the normal interactive
    # bootstrap below (model picker, healthcheck, cleanup-on-exit) without
    # going through RPC semantics/DEFAULT_RPC_MODEL.
    local PI_EXEC_CMD="pi $*"

    local MODEL_NAME
    MODEL_NAME=$(echo "$MODEL" | sed -E 's|^[a-z]+://||')

    SPECIFIC_PARAMS="${MODEL_PARAMS[$MODEL_NAME]:-}"
    if [ -z "$SPECIFIC_PARAMS" ]; then
        echo "[Notice] No MODEL_PARAMS entry for '$MODEL_NAME' in $CONFIG_FILE."
        read -p "[Benchmark] Run llama-optimus now (isolated container) before starting? [y/N]: " RUN_BENCH_NOW
        if [[ "$RUN_BENCH_NOW" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            if benchmark "$MODEL_NAME"; then
                SPECIFIC_PARAMS="$LAST_BENCHMARK_PARAMS"
            fi
        fi
        if [ -z "$SPECIFIC_PARAMS" ]; then
            SPECIFIC_PARAMS="${DEFAULT_MODEL_PARAMS}"
            echo "[System] Applying unoptimized default params: $SPECIFIC_PARAMS"
        fi
        update_model_params "$MODEL_NAME" "$SPECIFIC_PARAMS"
    fi

    COMBINED_ENV="${DEFAULT_RAMALAMA_ENV}"
    [ -n "$SPECIFIC_PARAMS" ] && COMBINED_ENV="${COMBINED_ENV},${SPECIFIC_PARAMS}"

    echo "[Start] RamaLama -> $MODEL (HTTP port: $MODEL_PORT)"
    env HK_SYSMEM=$HK_SYSMEM nice -n 10 taskset -c "$CPU_AFFINITY" \
        ramalama serve --network ai-net --name ramalama --device none \
        --image "$RAMALAMA_IMAGE" --rag-image "$RAMALAMA_RAG_IMAGE" \
        --env "$COMBINED_ENV" -t 8 --ngl 0 -p "$MODEL_PORT" "$MODEL" >/dev/null 2>&1 &

    RAMALAMA_PID=$!

    echo "[Healthcheck] Waiting for the L7 API (llama.cpp), timeout ${RAMALAMA_HEALTHCHECK_TIMEOUT:-60}s..."
    local ELAPSED=0
    local TIMEOUT="${RAMALAMA_HEALTHCHECK_TIMEOUT:-60}"
    until curl -s -f "http://127.0.0.1:${MODEL_PORT}/v1/models" >/dev/null 2>&1; do
        sleep 1
        ELAPSED=$((ELAPSED + 1))
        if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
            echo "[Error] Timeout (${TIMEOUT}s) waiting for ramalama on port ${MODEL_PORT}. Aborting."
            exit 1
        fi
    done

    ensure_pi_agent_removed
    echo "[Compose] Starting pi-agent..."
    export PI_RPC_PORT
    cd "$DIR" && compose up -d pi-agent

    $ENGINE exec -it pi-agent $PI_EXEC_CMD
}

# Non-interactive counterpart to start_env, for the 'pi --mode rpc' host
# wrapper. The environment stays
# up after this returns so later RPC calls can reuse it.
start_rpc() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
    [ -f "$MODELS_CONFIG_FILE" ] && source "$MODELS_CONFIG_FILE"
    resolve_ramalama || exit 1
    ensure_environment

    MODEL_PORT="${MODEL_PORT:-8080}"
    export MODEL_PORT

    if curl -s -f "http://127.0.0.1:${MODEL_PORT}/v1/models" >/dev/null 2>&1 \
       && $ENGINE ps --format '{{.Names}}' 2>/dev/null | grep -qx pi-agent; then
        echo "[RPC] Environment already up."
        return 0
    fi

    local MODEL="${DEFAULT_RPC_MODEL:-}"
    if [ -z "$MODEL" ]; then
        echo "[Error] DEFAULT_RPC_MODEL is not set in $CONFIG_FILE." >&2
        exit 1
    fi

    if ! ramalama list | awk 'NR>1{print $1}' | grep -qxF "$MODEL"; then
        echo "[Error] Default model '$MODEL' is not pulled locally." >&2
        echo "        Run first: $DIR/pi-ramalama --pull $MODEL" >&2
        exit 1
    fi

    local MODEL_NAME
    MODEL_NAME=$(echo "$MODEL" | sed -E 's|^[a-z]+://||')
    local SPECIFIC_PARAMS="${MODEL_PARAMS[$MODEL_NAME]:-$DEFAULT_MODEL_PARAMS}"
    local COMBINED_ENV="${DEFAULT_RAMALAMA_ENV},${SPECIFIC_PARAMS}"

    echo "[RPC][Start] RamaLama -> $MODEL (HTTP port: $MODEL_PORT)"
    env HK_SYSMEM=$HK_SYSMEM nice -n 10 taskset -c "$CPU_AFFINITY" \
        ramalama serve --network ai-net --name ramalama --device none \
        --image "$RAMALAMA_IMAGE" --rag-image "$RAMALAMA_RAG_IMAGE" \
        --env "$COMBINED_ENV" -t 8 --ngl 0 -p "$MODEL_PORT" "$MODEL" >/dev/null 2>&1 &
    disown

    local ELAPSED=0
    local TIMEOUT="${RAMALAMA_HEALTHCHECK_TIMEOUT:-60}"
    until curl -s -f "http://127.0.0.1:${MODEL_PORT}/v1/models" >/dev/null 2>&1; do
        sleep 1
        ELAPSED=$((ELAPSED + 1))
        if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
            echo "[Error] Timeout (${TIMEOUT}s) waiting for ramalama on port ${MODEL_PORT}." >&2
            exit 1
        fi
    done

    ensure_pi_agent_removed
    export PI_RPC_PORT
    cd "$DIR" && compose up -d pi-agent
    echo "[RPC] Environment ready."
}

# Fast, non-blocking bootstrap used by the 'pi --mode rpc' wrapper directly
# (all output redirected to stderr by the caller). Unlike start_rpc(), this
# does NOT wait for ramalama's healthcheck: Pi's RPC server attaches fine
# before a model is loaded and only needs one once a prompt is actually sent.
# Only the pi-agent container itself is waited on (seconds, not model-load time).
start_rpc_async() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
    [ -f "$MODELS_CONFIG_FILE" ] && source "$MODELS_CONFIG_FILE"
    resolve_ramalama || exit 1
    ensure_environment

    MODEL_PORT="${MODEL_PORT:-8080}"
    export MODEL_PORT

    if ! $ENGINE ps --format '{{.Names}}' 2>/dev/null | grep -qx ramalama; then
        local MODEL="${DEFAULT_RPC_MODEL:-}"
        if [ -z "$MODEL" ]; then
            echo "[Warning] DEFAULT_RPC_MODEL is not set in $CONFIG_FILE; starting RPC with no model." >&2
        elif ! ramalama list | awk 'NR>1{print $1}' | grep -qxF "$MODEL"; then
            echo "[Warning] Default model '$MODEL' is not pulled locally; starting RPC with no model." >&2
            echo "          Pull it with: $DIR/pi-ramalama --pull $MODEL" >&2
        else
            local MODEL_NAME SPECIFIC_PARAMS COMBINED_ENV
            MODEL_NAME=$(echo "$MODEL" | sed -E 's|^[a-z]+://||')
            SPECIFIC_PARAMS="${MODEL_PARAMS[$MODEL_NAME]:-$DEFAULT_MODEL_PARAMS}"
            COMBINED_ENV="${DEFAULT_RAMALAMA_ENV},${SPECIFIC_PARAMS}"
            echo "[RPC][Async] Starting RamaLama -> $MODEL in the background (not waited on)..." >&2
            env HK_SYSMEM=$HK_SYSMEM nice -n 10 taskset -c "$CPU_AFFINITY" \
                ramalama serve --network ai-net --name ramalama --device none \
                --image "$RAMALAMA_IMAGE" --rag-image "$RAMALAMA_RAG_IMAGE" \
                --env "$COMBINED_ENV" -t 8 --ngl 0 -p "$MODEL_PORT" "$MODEL" >/dev/null 2>&1 &
            disown
        fi
    fi

    # pi-agent itself must be reachable before Pi's RPC server can attach —
    # this is just container startup, so it's fine to wait on it.
    if ! $ENGINE ps --format '{{.Names}}' 2>/dev/null | grep -qx pi-agent; then
        ensure_pi_agent_removed
	export PI_RPC_PORT
        cd "$DIR" && compose up -d pi-agent

        local ELAPSED=0
        local TIMEOUT=15
        until $ENGINE ps --format '{{.Names}}' 2>/dev/null | grep -qx pi-agent; do
            sleep 1
            ELAPSED=$((ELAPSED + 1))
            if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
                echo "[Error] Container 'pi-agent' did not reach running state within ${TIMEOUT}s." >&2
                exit 1
            fi
        done
    fi
}

# Called by the 'pi --mode rpc' wrapper when its RPC session ends (VSCode
# closed, window reloaded, etc.). Waits RPC_STOP_GRACE_SECONDS, then stops
# ramalama and pi-agent only if no other 'pi --mode rpc' process is running
# inside the container — avoids tearing down on a quick reconnect.
stop_rpc() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
    [ -f "$MODELS_CONFIG_FILE" ] && source "$MODELS_CONFIG_FILE"
    resolve_ramalama || true

    sleep "${RPC_STOP_GRACE_SECONDS:-4}"

    if $ENGINE exec pi-agent pgrep -f "pi --mode rpc" >/dev/null 2>&1; then
        echo "[RPC] Another RPC session is active, not stopping." >&2
        return 0
    fi

    echo "[RPC] No active session left, stopping ramalama..." >&2
    ramalama stop --all >/dev/null 2>&1 || true
    echo "[RPC] Stopping pi-agent..." >&2
    cd "$DIR" && compose stop pi-agent >/dev/null 2>&1 || true
}
