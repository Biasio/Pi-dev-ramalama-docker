#!/bin/bash
# lib/env.sh — host bootstrap script
#
# ensure_environment() is safe to call on every run (it's called by
# --setup, --start, and --install-extensions): it only creates what's
# missing and only rebuilds the pi wrapper/image when their content
# actually changed. remove_env() is the destructive counterpart, only
# triggered by --remove.

ensure_environment() {
    render_mounts
    local REQUIRED_DIRS=(
        "$HOME/.pi/agent/skills"
        "$HOME/.pi/agent/extensions"
        "$HOME/.config/cortexkit"
        "$HOME/.local/share/cortexkit/magic-context"
        "$HOME/.local/bin"
    )

    for dir in "${REQUIRED_DIRS[@]}"; do
        [ -d "$dir" ] || mkdir -p "$dir"
    done

    if [ ! -f "$HOME/.pi/settings.json" ]; then
        mkdir -p "$HOME/.pi"
        echo "{}" > "$HOME/.pi/settings.json"
    fi

    local PI_WRAPPER="$HOME/.local/bin/pi"
    local PI_WRAPPER_CONTENT
    PI_WRAPPER_CONTENT="$(sed "s#__DIR__#$DIR#g" "$DIR/lib/pi-wrapper.sh.tmpl")"

    if [ ! -f "$PI_WRAPPER" ] || [ "$(cat "$PI_WRAPPER")" != "$PI_WRAPPER_CONTENT" ]; then
        echo "[Auto-Setup] Generating/updating host proxy at $PI_WRAPPER..."
        echo "$PI_WRAPPER_CONTENT" > "$PI_WRAPPER"
        chmod +x "$PI_WRAPPER"
    fi

    if ! $ENGINE image inspect pi-sandbox-image >/dev/null 2>&1; then
        echo "[Auto-Setup] Image 'pi-sandbox-image' not found. Building..."
        cd "$DIR" && compose build pi-agent
    fi
}

# Destroys containers, volumes and images.
remove_env() {
    echo "[Remove] Destroying containers and volumes..."
    cd "$DIR" && compose down -v
    echo "[Remove] Cleaning up images..."
    $ENGINE rmi pi-sandbox-image || true
    $ENGINE rmi llama-optimus-sandbox || true
}
