#!/bin/bash
# hello-world — Ask daemon script (zero dependencies)
# Communicates with AskMac via JSON-RPC 2.0 over stdio.

# Single-instance guard — exit if another copy is already running
_LOCK="$HOME/.ask/run/hello-world.lock"
mkdir -p "$(dirname "$_LOCK")"
if [ -f "$_LOCK" ]; then
    _holder=$(cat "$_LOCK" 2>/dev/null)
    if [ -n "$_holder" ] && kill -0 "$_holder" 2>/dev/null; then
        printf '[hello-world] another instance already running (pid=%s), exiting\n' "$_holder" >&2
        exit 0
    fi
fi
echo "$$" > "$_LOCK"
trap 'rm -f "$_LOCK"' EXIT

# Parent-death watchdog — exit if AskMac (parent) goes away.
_ASK_PARENT=$PPID
( while kill -0 "$_ASK_PARENT" 2>/dev/null; do sleep 5; done
  pkill -P $$ 2>/dev/null; kill -TERM $$ 2>/dev/null ) &

CONFIRM_ID="hello-world-confirm"
STATUS_ID="hello-world-status"
RESET_DELAY=30

ID=0

send() {
    printf '%s\n' "$1"
}

next_id() {
    ID=$((ID + 1))
    echo "$ID"
}

emit_block() {
    local block_id="$1" block_type="$2" payload="$3" ttl="$4"
    local args
    args='{"blockId":"'"$block_id"'","blockType":"'"$block_type"'","payload":'"$payload"'}'
    if [[ -n "$ttl" ]]; then
        args='{"blockId":"'"$block_id"'","blockType":"'"$block_type"'","payload":'"$payload"',"ttl":'"$ttl"'}'
    fi
    local rid
    rid=$(next_id)
    send '{"jsonrpc":"2.0","id":'"$rid"',"method":"tools/call","params":{"name":"emit_block","arguments":'"$args"'}}'
}

clear_block() {
    local rid
    rid=$(next_id)
    send '{"jsonrpc":"2.0","id":'"$rid"',"method":"tools/call","params":{"name":"clear_block","arguments":{"blockId":"'"$1"'"}}}'
}

# Initialize MCP handshake
rid=$(next_id)
send '{"jsonrpc":"2.0","id":'"$rid"',"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"hello-world","version":"1.0"}}}'
IFS= read -r _  # consume initialize response
send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
printf '[hello-world] MCP initialized\n' >&2

# FIFO lets the background reader pass user responses to the main loop
FIFO=$(mktemp -u)
mkfifo "$FIFO"
cleanup() { rm -f "$FIFO"; kill "$READER_PID" 2>/dev/null || true; }
trap cleanup EXIT

# Background stdin reader — extracts user_response values and writes to FIFO
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
$TEST_MODE && printf '[hello-world] running in test mode\n' >&2

runs=0

while true; do
    printf '[hello-world] greeting...\n' >&2

    emit_block "$CONFIRM_ID" "confirmation" \
        '{"title":"Hello, World!","body":"Greetings from your Ask script.\nWhat would you like to do?","options":["Say it back","Dismiss"]}' \
        86400

    response=$(cat "$FIFO")
    clear_block "$CONFIRM_ID"

    if [[ "$response" == "Say it back" ]]; then
        emit_block "$STATUS_ID" "status" \
            '{"label":"Hello back at ya!","icon":"heart.fill","color":"green"}' \
            "$RESET_DELAY"
        sleep "$RESET_DELAY"
        clear_block "$STATUS_ID"
    fi

    runs=$((runs + 1))
    if $TEST_MODE && [[ $runs -ge 1 ]]; then
        printf '[hello-world] test mode complete\n' >&2
        sleep 60
        exit 0
    fi
done
