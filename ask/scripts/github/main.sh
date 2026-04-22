#!/bin/bash
# github — monitors local git repositories. Zero dependencies.
# Communicates with AskMac via JSON-RPC 2.0 over stdio.
#
# Note: Per-repo detail views and commit/push/pull flows from the Python
# version require concurrent callbacks which bash cannot support. This version
# surfaces repo status and runs operations via confirmation blocks sequentially.

# Single-instance guard — exit if another copy is already running
_LOCK="$HOME/.ask/run/github.lock"
mkdir -p "$(dirname "$_LOCK")"
exec 9>"$_LOCK"
flock -n 9 || { printf '[github] another instance already running, exiting\n' >&2; exit 0; }

REFRESH_SECS=300  # 5 minutes
MAX_REPOS=100

BLOCK_TILE="git-tile"
BLOCK_STATUS="git-status"
BLOCK_LIST="git-list"
BLOCK_CONFIRM="git-confirm"

# Directories that should never be entered during repo scanning.
PRUNE_NAMES="Library|node_modules|.Trash|Pods|DerivedData|.build|build|dist|vendor|venv|.venv|.cache|.npm|.yarn|__pycache__|target|Volumes|.Spotlight-V100|.fseventsd"

# Developer-focused candidate roots. Scanning only these avoids macOS TCC prompts.
# ~/Documents and ~/Desktop are NOT listed as roots — on iCloud Drive setups macOS
# treats broad Documents access as "access data from other apps" (a different TCC
# category). Instead we list common developer subdirectory names under Documents.
SCAN_CANDIDATES=(
    "$HOME/Developer"
    "$HOME/developer"
    "$HOME/Code"
    "$HOME/code"
    "$HOME/Projects"
    "$HOME/projects"
    "$HOME/src"
    "$HOME/repos"
    "$HOME/workspace"
    "$HOME/git"
    "$HOME/dev"
    "$HOME/Documents/code"
    "$HOME/Documents/Code"
    "$HOME/Documents/dev"
    "$HOME/Documents/Dev"
    "$HOME/Documents/projects"
    "$HOME/Documents/Projects"
    "$HOME/Documents/repos"
    "$HOME/Documents/src"
    "$HOME/Documents/Developer"
    "$HOME/Documents/developer"
    "$HOME/Documents/workspace"
)

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

send '{"jsonrpc":"2.0","id":'"$(next_id)"',"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"github","version":"2.0"}}}'
IFS= read -r _
send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
printf '[github] MCP initialized\n' >&2

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
$TEST_MODE && printf '[github] running in test mode\n' >&2

interval=$REFRESH_SECS
$TEST_MODE && interval=10
runs=0

# --- Git helpers ---

git_cmd() {
    local path="$1"; shift
    git -C "$path" "$@" 2>/dev/null
}

repo_status() {
    local path="$1"
    local branch ahead=0 behind=0 dirty=0 dirty_count=0 has_remote=0

    branch=$(git_cmd "$path" rev-parse --abbrev-ref HEAD 2>/dev/null)
    [[ -z "$branch" || "$branch" == "HEAD" ]] && return 1

    local tracking
    tracking=$(git_cmd "$path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)

    if [[ -n "$tracking" ]]; then
        local counts
        counts=$(git_cmd "$path" rev-list --left-right --count "HEAD...$tracking" 2>/dev/null)
        ahead=$(echo "$counts" | awk '{print $1}')
        behind=$(echo "$counts" | awk '{print $2}')
        ahead=${ahead:-0}; behind=${behind:-0}
    fi

    git_cmd "$path" remote | grep -q . && has_remote=1

    local porcelain
    porcelain=$(git_cmd "$path" status --porcelain 2>/dev/null)
    if [[ -n "$porcelain" ]]; then
        dirty=1
        dirty_count=$(echo "$porcelain" | wc -l | tr -d ' ')
    fi

    printf '%s|%s|%s|%s|%s|%s|%s\n' \
        "$path" "$branch" "$ahead" "$behind" "$dirty" "$dirty_count" "$has_remote"
}

find_repos() {
    local count=0

    # Build the list of directories to search from SCAN_CANDIDATES (those that exist).
    local search_dirs=()
    for candidate in "${SCAN_CANDIDATES[@]}"; do
        [[ -d "$candidate" ]] && search_dirs+=("$candidate")
    done

    [[ ${#search_dirs[@]} -eq 0 ]] && return

    # Prune skip dirs during traversal — never let find enter them so the OS
    # doesn't log access and trigger TCC prompts.
    local prune_expr=()
    IFS='|' read -ra names <<< "$PRUNE_NAMES"
    for name in "${names[@]}"; do
        prune_expr+=(-o -name "$name")
    done
    # Remove leading "-o" to form a valid expression
    prune_expr=("${prune_expr[@]:1}")

    while IFS= read -r gitdir; do
        local repo="${gitdir%/.git}"
        echo "$repo"
        count=$((count+1))
        [[ $count -ge $MAX_REPOS ]] && break
    done < <(find "${search_dirs[@]}" \
        \( "${prune_expr[@]}" \) -prune \
        -o -name ".git" -type d -print 2>/dev/null \
        | sort -u)
}

state_label() {
    local ahead="$1" behind="$2" dirty="$3" dirty_count="$4" has_remote="$5"
    local parts=()
    [[ "$ahead" -gt 0 ]]  && parts+=("${ahead} to push")
    [[ "$behind" -gt 0 ]] && parts+=("${behind} to pull")
    [[ "$dirty" -eq 1 ]]  && parts+=("${dirty_count} changed")
    if [[ ${#parts[@]} -eq 0 ]]; then
        [[ "$has_remote" -eq 0 ]] && parts+=("local only") || parts+=("up to date")
    fi
    local IFS=" · "; echo "${parts[*]}"
}

run_git_op() {
    local repo="$1" op="$2" label="$3"; shift 3
    local tid; tid=$(task_id)
    local now; now=$(now_str)

    open_task "$tid" "$label · $(basename "$repo") · $now"
    append_message "$tid" "user" "$label in $(basename "$repo")"

    emit_block "$BLOCK_STATUS" "status" \
        '{"label":"'"$(json_str "$label")"'...","icon":"arrow.clockwise","color":"blue"}' 60

    local output rc
    output=$(git -C "$repo" "$@" 2>&1)
    rc=$?

    clear_block "$BLOCK_STATUS"

    local tmp; tmp=$(mktemp /tmp/git-op-XXXXXX.md)
    local filename; filename="git-$(echo "$op" | tr ' ' '-')-$(date +%Y%m%d-%H%M).md"
    {
        printf '# %s — %s\n\n' "$label" "$now"
        printf '**Repository:** %s\n\n' "$repo"
        printf '## Output\n\n```\n%s\n```\n' "$output"
    } > "$tmp"

    if [[ $rc -eq 0 ]]; then
        append_message "$tid" "assistant" "$label completed successfully."
        put_artifact "$tid" "git-op-$(task_id)" "$filename" "text/plain" \
            "$label output" "$tmp"
        open_task "$tid" "$label · $(basename "$repo") · $now" "completed"
        emit_block "$BLOCK_STATUS" "status" \
            '{"label":"'"$(json_str "$label")"' complete","icon":"checkmark.circle","color":"green"}' 10
        sleep 2
    else
        local err; err=$(echo "$output" | tail -1)
        append_message "$tid" "assistant" "$label failed: $err"
        put_artifact "$tid" "git-op-$(task_id)" "$filename" "text/plain" \
            "$label output (errors)" "$tmp"
        open_task "$tid" "$label · $(basename "$repo") · $now" "failed"
        emit_block "$BLOCK_STATUS" "status" \
            '{"label":"Failed: '"$(json_str "$err")"'","icon":"exclamationmark.triangle","color":"red"}' 15
        sleep 5
    fi

    rm -f "$tmp"
    clear_block "$BLOCK_STATUS"
}

scan() {
    local tid; tid=$(task_id)
    local now; now=$(now_str)

    printf '[github] scanning repos...\n' >&2
    emit_block "$BLOCK_STATUS" "status" \
        '{"label":"Scanning repositories...","icon":"arrow.clockwise","color":"blue"}' 60

    local repos=() needs_attn=() total=0

    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        local info
        info=$(repo_status "$path")
        [[ -z "$info" ]] && continue
        repos+=("$info")
        total=$((total+1))

        local ahead dirty
        ahead=$(echo "$info" | cut -d'|' -f3)
        dirty=$(echo "$info" | cut -d'|' -f5)
        [[ "$ahead" -gt 0 || "$dirty" -eq 1 ]] && needs_attn+=("$info")
    done < <(find_repos)

    clear_block "$BLOCK_STATUS"
    printf '[github] found %s repos, %s need attention\n' "$total" "${#needs_attn[@]}" >&2

    # Tile
    local attn="${#needs_attn[@]}"
    local tile_label tile_color
    if [[ $total -eq 0 ]]; then
        tile_label="No repos found in ~/Developer, ~/Code, ~/Projects…"; tile_color="orange"
    elif [[ $attn -gt 0 ]]; then
        local noun="repos"; [[ $attn -eq 1 ]] && noun="repo"
        tile_label="$attn $noun with uncommitted changes"; tile_color="blue"
    else
        tile_label="All $total repos up to date"; tile_color="green"
    fi

    emit_block "$BLOCK_TILE" "tile" \
        '{"label":"'"$(json_str "$tile_label")"'","status_color":"'"$tile_color"'"}' 600

    # A2A scan report
    local tmp; tmp=$(mktemp /tmp/git-scan-XXXXXX.md)
    local filename; filename="git-scan-$(date +%Y%m%d-%H%M).md"
    {
        printf '# Git Repo Scan — %s\n\n' "$now"
        printf '**Total repos:** %s  **Need attention:** %s\n\n' "$total" "$attn"
        if [[ $attn -gt 0 ]]; then
            printf '## Repos Needing Attention\n\n'
            for info in "${needs_attn[@]}"; do
                local path branch ahead behind dirty dirty_count has_remote
                IFS='|' read -r path branch ahead behind dirty dirty_count has_remote <<< "$info"
                local label; label=$(state_label "$ahead" "$behind" "$dirty" "$dirty_count" "$has_remote")
                printf '- **%s** (%s) — %s\n' "$(basename "$path")" "$branch" "$label"
            done
            printf '\n'
        fi
        if [[ $total -gt 0 ]]; then
            printf '## All Repos\n\n'
            for info in "${repos[@]}"; do
                local path branch ahead behind dirty dirty_count has_remote
                IFS='|' read -r path branch ahead behind dirty dirty_count has_remote <<< "$info"
                local label; label=$(state_label "$ahead" "$behind" "$dirty" "$dirty_count" "$has_remote")
                printf '- **%s** (%s) — %s\n' "$(basename "$path")" "$branch" "$label"
            done
        fi
    } > "$tmp"

    open_task "$tid" "Git repo scan · $now"
    append_message "$tid" "user" "Scan local git repositories for status."
    if [[ $attn -gt 0 ]]; then
        append_message "$tid" "assistant" "Found $total repos. $attn need attention (uncommitted changes or unpushed commits)."
    else
        append_message "$tid" "assistant" "Found $total repos. All up to date."
    fi
    put_artifact "$tid" "git-scan-$(task_id)" "$filename" "text/plain" \
        "Git repo scan — $total repos" "$tmp"
    open_task "$tid" "Git repo scan · $now" "completed"
    rm -f "$tmp"

    # If nothing needs attention just show the tile
    if [[ ${#needs_attn[@]} -eq 0 ]]; then
        clear_block "$BLOCK_LIST"
        return
    fi

    # Build body listing repos that need attention
    local body_lines=()
    local options=("Refresh")
    local action_repos=()

    for info in "${needs_attn[@]}"; do
        local path branch ahead behind dirty dirty_count has_remote
        IFS='|' read -r path branch ahead behind dirty dirty_count has_remote <<< "$info"
        local name; name=$(basename "$path")
        local label; label=$(state_label "$ahead" "$behind" "$dirty" "$dirty_count" "$has_remote")
        body_lines+=("$name ($branch) — $label")

        # Offer actions for repos with a single clear operation
        if [[ "$dirty" -eq 1 && "$ahead" -eq 0 && "$behind" -eq 0 ]]; then
            options+=("Commit $name")
            action_repos+=("commit|$path|$name")
        elif [[ "$ahead" -gt 0 && "$behind" -eq 0 && "$has_remote" -eq 1 ]]; then
            options+=("Push $name")
            action_repos+=("push|$path|$name")
        elif [[ "$behind" -gt 0 && "$dirty" -eq 0 && "$has_remote" -eq 1 ]]; then
            options+=("Pull $name")
            action_repos+=("pull|$path|$name")
        fi
    done

    local body; body=$(printf '%s\n' "${body_lines[@]}" | tr '\n' '|' | sed 's/|/\\n/g;s/\\n$//')
    local opts_json; opts_json=$(printf '"%s",' "${options[@]}" | sed 's/,$//')

    emit_block "$BLOCK_LIST" "confirmation" \
        '{"title":"'"$attn repos need attention"'","body":"'"$body"'","options":['"$opts_json"']}' \
        "$REFRESH_SECS"

    local response; response=$(cat "$FIFO")
    clear_block "$BLOCK_LIST"

    if [[ "$response" == "Refresh" ]]; then
        return  # loop re-scans immediately
    fi

    # Match response to an action
    for entry in "${action_repos[@]}"; do
        local op path name
        IFS='|' read -r op path name <<< "$entry"
        if [[ "$response" == "$op $name" || "$response" == "$(echo "$op" | sed 's/./\u&/') $name" ]]; then
            case "$op" in
                commit) run_git_op "$path" "commit" "Committing" add -A \&\& git -C "$path" commit -m "Update $name" ;;
                push)   run_git_op "$path" "push"   "Pushing"   push ;;
                pull)   run_git_op "$path" "pull"   "Pulling"   pull ;;
            esac
            break
        fi
    done
}

while true; do
    scan

    runs=$((runs+1))
    if $TEST_MODE && [[ $runs -ge 1 ]]; then
        printf '[github] test mode complete\n' >&2
        sleep 60; exit 0
    fi
    sleep "$interval"
done
