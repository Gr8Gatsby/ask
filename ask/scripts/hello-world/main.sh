#!/bin/bash
# hello-world — Ask daemon script (zero dependencies)
# Communicates with AskMac via JSON-RPC 2.0 over stdio.

CONFIRM_ID="hello-world-confirm"
STATUS_ID="hello-world-status"
CHECK_INTERVAL=3600
RESET_DELAY=30
TEST_INTERVAL=10

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
}
reader_loop &
READER_PID=$!

TEST_MODE=false
[[ "${1:-}" == "test" || "${1:-}" == "--test" ]] && TEST_MODE=true
$TEST_MODE && printf '[hello-world] running in test mode\n' >&2

interval=$CHECK_INTERVAL
$TEST_MODE && interval=$TEST_INTERVAL
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

    sleep "$interval"
done
