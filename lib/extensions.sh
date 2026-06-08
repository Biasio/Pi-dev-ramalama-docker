#!/bin/bash
# lib/extensions.sh — runs pi-extensions.conf inside pi-agent.

# Runs each command in pi-extensions.conf inside pi-agent, one at a time,
# with a TTY attached so interactive prompts/choices work. Requires
# pi-agent to be up with its final volumes already mounted (render_mounts
# + a running/restarted container) to avoid extensions writing into paths
# that a mount added afterwards would shadow.
install_extensions() {
    local SRC="$DIR/conf/pi-extensions.conf"
    [ -f "$SRC" ] || { echo "[Error] pi-extensions.conf not found." >&2; exit 1; }

    ensure_environment

    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
    [ -f "$MODELS_CONFIG_FILE" ] && source "$MODELS_CONFIG_FILE"
    export PI_RPC_PORT

    if ! $ENGINE ps --format '{{.Names}}' 2>/dev/null | grep -qx pi-agent; then
        echo "[Extensions] pi-agent not running — starting it (mounts only, no model needed)..."
        cd "$DIR" && compose up -d pi-agent
    fi

    local FAILED=()
    local n=0
    local FAILED=()
    local n=0
    while IFS= read -r cmd <&3; do
	cmd="${cmd%%#*}"
	cmd="$(echo "$cmd" | xargs)"
	[ -z "$cmd" ] && continue
	n=$((n+1))

	echo "[Extensions] ($n) $cmd"
	if ! $ENGINE exec -it pi-agent bash -c "$cmd"; then
		echo "[Extensions] Command failed: $cmd" >&2
        	FAILED+=("$cmd")
	fi
    done 3< "$SRC"

    echo "[Extensions] Done: $n command(s) run, ${#FAILED[@]} failed."
    for f in "${FAILED[@]:-}"; do [ -n "$f" ] && echo "  - $f"; done
    [ "${#FAILED[@]}" -eq 0 ]
}
