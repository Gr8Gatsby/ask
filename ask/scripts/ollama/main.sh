#!/bin/bash
# ollama — monitors Ollama status and updates. Zero dependencies.
# Communicates with AskMac via JSON-RPC 2.0 over stdio.

UPDATE_CHECK_INTERVAL=21600  # 6 hours
OLLAMA_URL="http://localhost:11434"

BLOCK_STATUS="ollama-status"
BLOCK_UPDATE="ollama-update"

ID=0
send()    { printf '%s\n' "$1"; }
next_id() { ID=$((ID+1)); echo "$ID"; }

json_str() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

task_id() { uuidgen | tr '[:upper:]' '[:lower:]'; }
now_str() { date "+%Y-%m-%d %H:%M"; }

find_bin() {
    local name="$1"
    for p in "/opt/homebrew/bin/$name" "/usr/local/bin/$name" "/usr/bin/$name"; do
        [[ -x "$p" ]] && { echo "$p"; return; }
    done
    command -v "$name" 2>/dev/null
}

# --- MCP helpers ---

emit_block() {
    local block_id="$1" block_type="$2" payload="$3" ttl="${4:-}"
    local args='{"blockId":"'"$block_id"'","blockType":"'"$block_type"'","payload":'"$payload"'}'
    [[ -n "$ttl" ]] && args='{"blockId":"'"$block_id"'","blockType":"'"$block_type"'","payload":'"$payload"',"ttl":'"$ttl"'}'
    send '{"jsonrpc":"2.0","id":'"$(next_id)"',"method":"tools/call","params":{"name":"emit_block","arguments":'"$args"'}}'
}

clear_block() {
    send '{"jsonrpc":"2.0","id":'"$(next_id)"',"method":"tools/call","params":{"name":"clear_block","arguments":{"blockId":"'"$1"'"}}}'
}

# --- A2A helpers ---

open_task() {
    local task_id="$1" title="$2" status="${3:-working}"
    send '{"jsonrpc":"2.0","id":'"$(next_id)"',"method":"tools/call","params":{"name":"open_task","arguments":{"taskId":"'"$task_id"'","title":"'"$(json_str "$title")"'","status":"'"$status"'"}}}'
}

append_message() {
    local task_id="$1" role="$2" text="$3"
    send '{"jsonrpc":"2.0","id":'"$(next_id)"',"method":"tools/call","params":{"name":"append_message","arguments":{"taskId":"'"$task_id"'","role":"'"$role"'","parts":[{"type":"text","text":"'"$(json_str "$text")"'"}]}}}'
}

put_artifact() {
    local task_id="$1" artifact_id="$2" filename="$3" mime="$4" desc="$5" filepath="$6"
    send '{"jsonrpc":"2.0","id":'"$(next_id)"',"method":"tools/call","params":{"name":"put_artifact","arguments":{"taskId":"'"$task_id"'","artifactId":"'"$artifact_id"'","filename":"'"$filename"'","mimeType":"'"$mime"'","description":"'"$(json_str "$desc")"'","filePath":"'"$filepath"'"}}}'
}

# --- MCP handshake ---

send '{"jsonrpc":"2.0","id":'"$(next_id)"',"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"ollama","version":"2.0"}}}'
IFS= read -r _
send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
printf '[ollama] MCP initialized\n' >&2

# FIFO for async user responses
FIFO=$(mktemp -u)
mkfifo "$FIFO"
cleanup() { rm -f "$FIFO"; kill "$READER_PID" 2>/dev/null || true; }
trap cleanup EXIT

reader_loop() {
    while IFS= read -r line; do
        if [[ "$line" == *'"user_response"'* ]]; then
            printf '%s' "$line" | grep -o '"value":"[^"]*"' | head -1 \
                | sed 's/"value":"//;s/"$//' > "$FIFO"
        fi
    done
}
reader_loop <&0 &
READER_PID=$!

TEST_MODE=false
[[ "${1:-}" == "test" || "${1:-}" == "--test" ]] && TEST_MODE=true
$TEST_MODE && printf '[ollama] running in test mode\n' >&2

interval=$UPDATE_CHECK_INTERVAL
$TEST_MODE && interval=10
runs=0

OLLAMA_BIN=$(find_bin ollama)
BREW_BIN=$(find_bin brew)

local_version() {
    [[ -z "$OLLAMA_BIN" ]] && { echo "unknown"; return; }
    local v
    v=$("$OLLAMA_BIN" --version 2>/dev/null | awk '{print $NF}')
    echo "${v:-unknown}"
}

latest_version() {
    curl -sf "https://api.github.com/repos/ollama/ollama/releases/latest" \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"v//;s/".*//'
}

is_newer() {
    # Returns 0 (true) if $2 > $1 using sort -V
    local newer
    newer=$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)
    [[ "$newer" == "$2" && "$1" != "$2" ]]
}

ollama_running() {
    curl -sf "$OLLAMA_URL/api/tags" >/dev/null 2>&1
}

do_update() {
    local current="$1" latest="$2"
    local tid; tid=$(task_id)
    local now; now=$(now_str)

    open_task "$tid" "Ollama update · $now"
    append_message "$tid" "user" "Update Ollama from $current to $latest."

    emit_block "$BLOCK_UPDATE" "status" \
        '{"label":"Updating Ollama...","icon":"arrow.down.circle","color":"blue"}' 360

    local success=false output=""

    # Try brew first if ollama was installed via brew
    if [[ -n "$BREW_BIN" ]] && "$BREW_BIN" list --formula ollama >/dev/null 2>&1; then
        output=$("$BREW_BIN" upgrade ollama 2>&1)
        [[ $? -eq 0 ]] && success=true
    fi

    # Fall back to official install script
    if ! $success; then
        output=$(curl -fsSL https://ollama.com/install.sh | sh 2>&1)
        [[ $? -eq 0 ]] && success=true
    fi

    local tmp; tmp=$(mktemp /tmp/ollama-update-XXXXXX.md)
    local filename; filename="ollama-update-$(date +%Y%m%d-%H%M).md"
    {
        printf '# Ollama Update — %s\n\n' "$now"
        printf '**From:** %s  **To:** %s\n\n' "$current" "$latest"
        printf '## Output\n\n```\n%s\n```\n' "$output"
    } > "$tmp"

    if $success; then
        append_message "$tid" "assistant" "Ollama updated to $latest successfully. Restart Ollama to use the new version."
        put_artifact "$tid" "ollama-update-$(task_id)" "$filename" "text/plain" \
            "Ollama update log — $current to $latest" "$tmp"
        open_task "$tid" "Ollama update · $now" "completed"
        emit_block "$BLOCK_UPDATE" "status" \
            '{"label":"Updated to Ollama '"$latest"'","detail":"Restart Ollama to apply","icon":"checkmark.circle","color":"green"}' \
            "$UPDATE_CHECK_INTERVAL"
    else
        append_message "$tid" "assistant" "Update failed. See the attached log."
        put_artifact "$tid" "ollama-update-$(task_id)" "$filename" "text/plain" \
            "Ollama update log (errors)" "$tmp"
        open_task "$tid" "Ollama update · $now" "failed"
        emit_block "$BLOCK_UPDATE" "status" \
            '{"label":"Update failed","icon":"xmark.circle","color":"red"}' 3600
    fi

    rm -f "$tmp"
}

check() {
    local tid; tid=$(task_id)
    local now; now=$(now_str)

    printf '[ollama] checking status and updates...\n' >&2

    # Status check
    if ! ollama_running; then
        printf '[ollama] not running\n' >&2
        emit_block "$BLOCK_STATUS" "status" \
            '{"label":"Ollama not running","detail":"Start Ollama to enable monitoring","icon":"xmark.circle","color":"red"}' \
            "$UPDATE_CHECK_INTERVAL"

        open_task "$tid" "Ollama status · $now"
        append_message "$tid" "user" "Check Ollama status."
        append_message "$tid" "assistant" "Ollama is not running."
        open_task "$tid" "Ollama status · $now" "completed"
        return
    fi

    local current; current=$(local_version)
    printf '[ollama] running, version %s\n' "$current" >&2

    emit_block "$BLOCK_STATUS" "status" \
        '{"label":"Ollama '"$current"'","icon":"cpu","color":"green"}' \
        "$UPDATE_CHECK_INTERVAL"

    # Version check
    local latest
    latest=$(latest_version 2>/dev/null)

    open_task "$tid" "Ollama status · $now"
    append_message "$tid" "user" "Check Ollama version and available updates."

    if [[ -z "$latest" ]]; then
        append_message "$tid" "assistant" "Ollama $current is running. Could not fetch latest version from GitHub."
        open_task "$tid" "Ollama status · $now" "completed"
        return
    fi

    if is_newer "$current" "$latest"; then
        printf '[ollama] update available: %s -> %s\n' "$current" "$latest" >&2
        append_message "$tid" "assistant" "Ollama $current is running. Update available: $latest."
        open_task "$tid" "Ollama status · $now" "completed"

        clear_block "$BLOCK_UPDATE"
        emit_block "$BLOCK_UPDATE" "confirmation" \
            '{"title":"Ollama Update Available","body":"Current: '"$current"'\nLatest:  '"$latest"'","options":["Update Now","Skip"]}' \
            "$UPDATE_CHECK_INTERVAL"

        local response; response=$(cat "$FIFO")
        clear_block "$BLOCK_UPDATE"
        [[ "$response" == "Update Now" ]] && do_update "$current" "$latest"
    else
        printf '[ollama] up to date (%s)\n' "$current" >&2
        append_message "$tid" "assistant" "Ollama $current is running and up to date."
        open_task "$tid" "Ollama status · $now" "completed"
        clear_block "$BLOCK_UPDATE"
    fi
}

while true; do
    check

    runs=$((runs+1))
    if $TEST_MODE && [[ $runs -ge 1 ]]; then
        printf '[ollama] test mode complete\n' >&2
        sleep 60; exit 0
    fi
    sleep "$interval"
done
