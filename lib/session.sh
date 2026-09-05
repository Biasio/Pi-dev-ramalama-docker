#!/bin/bash
# lib/session.sh — interactive/RPC session lifecycle.

# Per-session bookkeeping for the (possibly multiple) 'ramalama serve'
# instances started by start_env().
RAMALAMA_PIDS=()
RAMALAMA_NAMES=()
RAMALAMA_PORTS=()
RAMALAMA_MODEL_URIS=()
RAMALAMA_MODEL_NAMES=()

# Tears down every RamaLama instance started this session, plus pi-agent
# and the session's ephemeral artifacts. Only registered inside start_env,
# never globally, so it can't kill a persistent RPC environment as a side
# effect of an unrelated command.
cleanup() {
    echo -e "\n[System] Shutting down..."

    local pid
    for pid in "${RAMALAMA_PIDS[@]}"; do
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "[Ramalama] Stopping PID $pid..."
            kill "$pid" || true
        fi
    done

    echo "[Ramalama] Stopping remaining containers..."
    local name
    for name in "${RAMALAMA_NAMES[@]}"; do
        $ENGINE stop "$name" >/dev/null 2>&1 || true
    done
    ramalama stop --all >/dev/null 2>&1 || true

    echo "[Compose] Stopping pi-agent..."
    cd "$DIR" && compose stop >/dev/null 2>&1 || true

    remove_session_artifacts
    exit 0
}

# Resolves a model URI to its bare name and combined llama.cpp env string:
# DEFAULT_RAMALAMA_ENV plus that model's MODEL_PARAMS entry (or
# DEFAULT_MODEL_PARAMS if it has none).
resolve_model_env() {
    local MODEL="$1"
    MODEL_NAME=$(echo "$MODEL" | sed -E 's|^[a-z]+://||')
    local SPECIFIC_PARAMS="${MODEL_PARAMS[$MODEL_NAME]:-$DEFAULT_MODEL_PARAMS}"
    COMBINED_ENV="${DEFAULT_RAMALAMA_ENV}"
    [ -n "$SPECIFIC_PARAMS" ] && COMBINED_ENV="${COMBINED_ENV},${SPECIFIC_PARAMS}"
}

# Launches one 'ramalama serve' instance under an explicit container name
# and port, so multiple instances can run concurrently without colliding.
_serve_ramalama() {
    local combined_env="$1"
    local model="$2"
    local name="$3"
    local port="$4"

    local -a cmd=(nice -n 10)
    [ -n "${CPU_AFFINITY:-}" ] && cmd+=(taskset -c "$CPU_AFFINITY")

    cmd+=(ramalama serve --network ai-net --name "$name"
          --image "$RAMALAMA_IMAGE" --rag-image "$RAMALAMA_RAG_IMAGE")

    local IFS=','
    local pair
    for pair in $combined_env; do
        [ -n "$pair" ] && cmd+=(--env "$pair")
    done
    unset IFS

    cmd+=(-p "$port")
    [ -n "${RAMALAMA_ADDITIONAL_ARGS:-}" ] && cmd+=($RAMALAMA_ADDITIONAL_ARGS)
    cmd+=("$model")

    RAMALAMA_SERVE_LOG="$(mktemp -t "$(date +"%Y%m%d-%H%M%S")-${name}-XXXXXX.log")"
    "${cmd[@]}" >"$RAMALAMA_SERVE_LOG" 2>&1 &
}

# Waits for either the healthcheck to pass or the background 'ramalama
# serve' process (RAMALAMA_PID, set by the caller right after
# _serve_ramalama) to die.
wait_for_ramalama() {
    local port="$1"
    local timeout="${2:-60}"
    local elapsed=0

    until curl -s -f "http://127.0.0.1:${port}/v1/models" >/dev/null 2>&1; do
        if [ -n "${RAMALAMA_PID:-}" ] && ! kill -0 "$RAMALAMA_PID" 2>/dev/null; then
            echo "[Error] 'ramalama serve' exited before becoming healthy. Last log lines:" >&2
            tail -n 40 "$RAMALAMA_SERVE_LOG" >&2 2>/dev/null
            echo "[Error] Full log: $RAMALAMA_SERVE_LOG" >&2
            return 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
        if [ "$elapsed" -ge "$timeout" ]; then
            echo "[Error] Timeout (${timeout}s) waiting for ramalama on port ${port}. Last log lines:" >&2
            tail -n 40 "$RAMALAMA_SERVE_LOG" >&2 2>/dev/null
            echo "[Error] Full log: $RAMALAMA_SERVE_LOG" >&2
            return 1
        fi
    done
    return 0
}

# Interactive multi-model picker: pick one model, then choose whether to
# add another, continue with what's selected, or abort. Populates
# SELECTED_MODEL_URIS on success; leaves it empty and returns 1 on abort
# or when no models exist to choose from.
select_models() {
    SELECTED_MODEL_URIS=()

    mapfile -t MODELS < <(ramalama list | awk 'NR>1 {print $1}')
    if [ ${#MODELS[@]} -eq 0 ]; then
        echo "[Error] No models found in RamaLama." >&2
        return 1
    fi

    while true; do
        echo
        echo "Available models:"
        for i in "${!MODELS[@]}"; do echo "  $((i+1))) ${MODELS[$i]}"; done
        [ ${#SELECTED_MODEL_URIS[@]} -gt 0 ] && echo "Selected so far: ${SELECTED_MODEL_URIS[*]}"

        read -p "Select a model to add [1-${#MODELS[@]}]: " SELECTION
        local MODEL="${MODELS[$((SELECTION-1))]:-}"
        if [ -z "$MODEL" ]; then
            echo "[Error] Invalid selection."
            continue
        fi
        SELECTED_MODEL_URIS+=("$MODEL")

        echo
        echo "  a) Add another model"
        echo "  c) Continue with the ${#SELECTED_MODEL_URIS[@]} model(s) selected"
        echo "  x) Abort"
        read -p "Choice [a/c/x]: " NEXT
        case "$NEXT" in
            c|C) return 0 ;;
            x|X) SELECTED_MODEL_URIS=(); return 1 ;;
            *)   continue ;;
        esac
    done
}

# Interactive session: pick one or more models, serve each in its own
# RamaLama instance on a randomized free port, expose all of them to
# pi-agent via a session-only shadow models.json, attach in TUI. Tears
# everything down together on exit.
start_env() {
    trap cleanup EXIT SIGINT SIGTERM SIGHUP

    bootstrap_config

    select_models || { echo "[Aborted] No models selected."; exit 1; }

    local PI_EXEC_CMD="pi $*"

    local idx=0 MODEL NAME PORT
    for MODEL in "${SELECTED_MODEL_URIS[@]}"; do
        idx=$((idx + 1))
        NAME="ramalama-${idx}"

        resolve_model_env "$MODEL"   # sets MODEL_NAME, COMBINED_ENV

        if [ -z "${MODEL_PARAMS[$MODEL_NAME]:-}" ]; then
            echo "[Notice] No MODEL_PARAMS entry for '$MODEL_NAME' in $CONFIG_FILE."
            read -p "[Benchmark] Run llama-optimus now (isolated container) before starting? [y/N]: " RUN_BENCH_NOW
            local SPECIFIC_PARAMS=""
            if [[ "$RUN_BENCH_NOW" =~ ^([yY][eE][sS]|[yY])$ ]]; then
                benchmark "$MODEL_NAME" && SPECIFIC_PARAMS="$LAST_BENCHMARK_PARAMS"
            fi
            if [ -z "$SPECIFIC_PARAMS" ]; then
                SPECIFIC_PARAMS="${DEFAULT_MODEL_PARAMS}"
                echo "[System] Applying unoptimized default params: $SPECIFIC_PARAMS"
            fi
            update_model_params "$MODEL_NAME" "$SPECIFIC_PARAMS"
            COMBINED_ENV="${DEFAULT_RAMALAMA_ENV}"
            [ -n "$SPECIFIC_PARAMS" ] && COMBINED_ENV="${COMBINED_ENV},${SPECIFIC_PARAMS}"
        fi

        PORT="$(find_free_port "$MODEL_PORT")" || exit 1

        echo "[Start] RamaLama[$NAME] -> $MODEL (HTTP port: $PORT)"
        _serve_ramalama "$COMBINED_ENV" "$MODEL" "$NAME" "$PORT"
        RAMALAMA_PID="$!"

        RAMALAMA_PIDS+=("$RAMALAMA_PID")
        RAMALAMA_NAMES+=("$NAME")
        RAMALAMA_PORTS+=("$PORT")
        RAMALAMA_MODEL_URIS+=("$MODEL")
        RAMALAMA_MODEL_NAMES+=("$MODEL_NAME")

        echo "[Healthcheck] Waiting for $NAME, timeout ${RAMALAMA_HEALTHCHECK_TIMEOUT:-60}s... (log: $RAMALAMA_SERVE_LOG)"
        wait_for_ramalama "$PORT" "${RAMALAMA_HEALTHCHECK_TIMEOUT:-60}" || exit 1
    done

    render_shadow_models_json || exit 1
    render_session_override

    ensure_pi_agent_removed
    echo "[Compose] Starting pi-agent..."
    export PI_RPC_PORT
    cd "$DIR" && compose up -d pi-agent

    $ENGINE exec -it pi-agent $PI_EXEC_CMD
}

# Non-interactive counterpart to start_env, for the 'pi --mode rpc' host
# wrapper. Single-model only — explicitly out of scope for multi-instance
# (see README's RPC section). The environment stays up after this returns
# so later RPC calls can reuse it.
start_rpc() {
    bootstrap_config

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

    local MODEL_NAME COMBINED_ENV
    resolve_model_env "$MODEL"

    echo "[RPC][Start] RamaLama -> $MODEL (HTTP port: $MODEL_PORT)"
    _serve_ramalama "$COMBINED_ENV" "$MODEL" "ramalama" "$MODEL_PORT"
    RAMALAMA_PID=$!
    disown

    echo "[RPC] Log: $RAMALAMA_SERVE_LOG"
    wait_for_ramalama "$MODEL_PORT" "${RAMALAMA_HEALTHCHECK_TIMEOUT:-60}" || exit 1

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
    bootstrap_config

    if ! $ENGINE ps --format '{{.Names}}' 2>/dev/null | grep -qx ramalama; then
        local MODEL="${DEFAULT_RPC_MODEL:-}"
        if [ -z "$MODEL" ]; then
            echo "[Warning] DEFAULT_RPC_MODEL is not set in $CONFIG_FILE; starting RPC with no model." >&2
        elif ! ramalama list | awk 'NR>1{print $1}' | grep -qxF "$MODEL"; then
            echo "[Warning] Default model '$MODEL' is not pulled locally; starting RPC with no model." >&2
            echo "          Pull it with: $DIR/pi-ramalama --pull $MODEL" >&2
        else
            local MODEL_NAME COMBINED_ENV
            resolve_model_env "$MODEL"
            echo "[RPC][Async] Starting RamaLama -> $MODEL in the background (not waited on)..." >&2
            _serve_ramalama "$COMBINED_ENV" "$MODEL" "ramalama" "$MODEL_PORT"
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
