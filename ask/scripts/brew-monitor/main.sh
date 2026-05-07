#!/bin/bash
# brew-monitor — surfaces outdated Homebrew packages. Zero dependencies.
# Communicates with AskMac via JSON-RPC 2.0 over stdio.

# Single-instance guard — exit if another copy is already running
_LOCK="$HOME/.ask/run/brew-monitor.lock"
mkdir -p "$(dirname "$_LOCK")"
exec 9>"$_LOCK"
flock -n 9 || { printf '[brew-monitor] another instance already running, exiting\n' >&2; exit 0; }

# Parent-death watchdog — exit if AskMac (parent) goes away. Without this, when
# AskMac is force-quit or crashes the script gets reparented to launchd and
# lingers forever, retaining AskMac's TCC identity (causing ghost prompts).
_ASK_PARENT=$PPID
( while kill -0 "$_ASK_PARENT" 2>/dev/null; do sleep 5; done
  pkill -P $$ 2>/dev/null; kill -TERM $$ 2>/dev/null ) &

CHECK_INTERVAL=14400  # 4 hours

BLOCK_UPDATES="brew-monitor-updates"
BLOCK_STATUS="brew-monitor-status"

ID=0
send()    { printf '%s\n' "$1"; }
next_id() { ID=$((ID+1)); echo "$ID"; }

# Escape a string for use as a JSON string value (no surrounding quotes)
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

find_brew() {
    for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [[ -x "$p" ]] && { echo "$p"; return; }
    done
    command -v brew 2>/dev/null
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

send '{"jsonrpc":"2.0","id":'"$(next_id)"',"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"brew-monitor","version":"3.0"}}}'
IFS= read -r _
send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
printf '[brew-monitor] MCP initialized\n' >&2

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
    # stdin closed — terminate the main process
    kill "$$" 2>/dev/null || true
}
reader_loop <&0 &
READER_PID=$!

TEST_MODE=false
[[ "${1:-}" == "test" || "${1:-}" == "--test" ]] && TEST_MODE=true
$TEST_MODE && printf '[brew-monitor] running in test mode\n' >&2

interval=$CHECK_INTERVAL
$TEST_MODE && interval=10
runs=0

BREW=$(find_brew)

upgrade() {
    local outdated="$1"
    local tid; tid=$(task_id)
    local now; now=$(now_str)
    local count; count=$(printf '%s\n' "$outdated" | wc -l | tr -d ' ')
    local noun="packages"; [[ "$count" -eq 1 ]] && noun="package"

    printf '[brew-monitor] running brew upgrade... task=%s\n' "$tid" >&2

    open_task "$tid" "Homebrew upgrade · $now"
    append_message "$tid" "user" "Upgrade all outdated Homebrew packages."
    append_message "$tid" "assistant" "Upgrading $count $noun:\n\n$outdated"

    emit_block "$BLOCK_STATUS" "status" \
        '{"label":"Upgrading Homebrew packages...","icon":"arrow.down.circle","color":"blue"}' \
        10800

    local output rc
    output=$("$BREW" upgrade 2>&1)
    rc=$?

    printf '[brew-monitor] brew upgrade exited %s\n' "$rc" >&2

    # Write report to temp file for artifact
    local tmp; tmp=$(mktemp /tmp/brew-upgrade-XXXXXX.md)
    local filename; filename="brew-upgrade-$(date +%Y%m%d-%H%M).md"
    {
        printf '# Homebrew Upgrade Report — %s\n\n' "$now"
        if [[ $rc -eq 0 ]]; then
            printf '## %s %s upgraded\n\n' "$count" "$noun"
        else
            printf '## Upgrade failed (%s %s attempted)\n\n' "$count" "$noun"
        fi
        printf '## Packages\n\n```\n%s\n```\n\n' "$outdated"
        printf '## Output\n\n```\n%s\n```\n\n' "$output"
        printf '---\nGenerated by brew-monitor at %s\n' "$now"
    } > "$tmp"

    if [[ $rc -eq 0 ]]; then
        append_message "$tid" "assistant" "Upgrade complete. $count $noun updated successfully."
        put_artifact "$tid" "brew-report-$(task_id)" "$filename" "text/plain" \
            "Full upgrade log — $count $noun" "$tmp"
        open_task "$tid" "Homebrew upgrade · $now" "completed"
        emit_block "$BLOCK_STATUS" "status" \
            '{"label":"Upgrades complete","icon":"checkmark.circle","color":"green"}' 30
        sleep 5
    else
        append_message "$tid" "assistant" "Upgrade finished with errors (exit code $rc). See the attached report."
        put_artifact "$tid" "brew-report-$(task_id)" "$filename" "text/plain" \
            "Upgrade log (errors)" "$tmp"
        open_task "$tid" "Homebrew upgrade · $now" "failed"
        emit_block "$BLOCK_STATUS" "status" \
            '{"label":"Upgrade finished with errors","icon":"exclamationmark.triangle","color":"orange"}' 60
        sleep 10
    fi

    rm -f "$tmp"
    clear_block "$BLOCK_STATUS"
}

check() {
    if [[ -z "$BREW" ]]; then
        emit_block "$BLOCK_STATUS" "status" \
            '{"label":"brew not found","icon":"exclamationmark.triangle","color":"orange"}' \
            "$CHECK_INTERVAL"
        return
    fi

    printf '[brew-monitor] checking for outdated packages...\n' >&2
    emit_block "$BLOCK_STATUS" "status" \
        '{"label":"Checking for Homebrew updates...","icon":"arrow.clockwise","color":"blue"}' 60

    local outdated
    outdated=$("$BREW" outdated 2>/dev/null)
    clear_block "$BLOCK_STATUS"

    local now; now=$(now_str)
    local tid; tid=$(task_id)

    if [[ -z "$outdated" ]]; then
        printf '[brew-monitor] all packages up to date\n' >&2
        clear_block "$BLOCK_UPDATES"

        # A2A: log the all-clear check
        local tmp; tmp=$(mktemp /tmp/brew-check-XXXXXX.md)
        local filename; filename="brew-check-$(date +%Y%m%d-%H%M).md"
        {
            printf '# Homebrew Check — %s\n\n' "$now"
            printf '**Result:** All packages are up to date.\n\n'
            printf '---\nGenerated by brew-monitor at %s\n' "$now"
        } > "$tmp"

        open_task "$tid" "Homebrew check · $now"
        append_message "$tid" "user" "Check for outdated Homebrew packages."
        append_message "$tid" "assistant" "All packages are up to date. No upgrades needed."
        put_artifact "$tid" "brew-check-$(task_id)" "$filename" "text/plain" \
            "Homebrew check — all packages up to date" "$tmp"
        open_task "$tid" "Homebrew check · $now" "completed"
        rm -f "$tmp"

        emit_block "$BLOCK_STATUS" "status" \
            '{"label":"All packages up to date","icon":"checkmark.circle","color":"green"}' \
            "$CHECK_INTERVAL"
        return
    fi

    local count; count=$(printf '%s\n' "$outdated" | wc -l | tr -d ' ')
    local noun="updates"; [[ "$count" -eq 1 ]] && noun="update"
    local body; body=$(printf '%s' "$outdated" | head -20 | tr '\n' '|' | sed 's/|/\\n/g;s/\\n$//')

    printf '[brew-monitor] %s %s available\n' "$count" "$noun" >&2

    emit_block "$BLOCK_UPDATES" "confirmation" \
        '{"title":"'"$count Homebrew $noun"' available","body":"'"$body"'","options":["Upgrade All","Sync Now","Later"]}' \
        86400

    local response; response=$(cat "$FIFO")
    clear_block "$BLOCK_UPDATES"

    case "$response" in
        "Upgrade All") upgrade "$outdated"; check ;;
        "Sync Now")    ;;  # re-runs check on next loop iteration
    esac
}

while true; do
    check

    runs=$((runs+1))
    if $TEST_MODE && [[ $runs -ge 1 ]]; then
        printf '[brew-monitor] test mode complete\n' >&2
        sleep 60; exit 0
    fi
    sleep "$interval"
done
