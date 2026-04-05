#!/usr/bin/env python3
from __future__ import annotations
"""
git-repos — Ask daemon script
Monitors local git repositories on this Mac. Push and pull from your iPhone.
"""
import os
import sys
import json
import asyncio
import subprocess
import hashlib
import urllib.request
import urllib.error
import re

# CRITICAL: unbuffered stdout so JSON-RPC messages reach the daemon immediately.
sys.stdout = open(sys.stdout.fileno(), mode='w', encoding='utf-8', buffering=1)


# ---------------------------------------------------------------------------
# MCPClient — JSON-RPC 2.0 over stdio
# ---------------------------------------------------------------------------

class MCPClient:
    def __init__(self):
        self._id      = 0
        self._pending = {}
        self._cbs     = {}

    def _send(self, obj):
        sys.stdout.write(json.dumps(obj) + '\n')

    async def _rpc(self, method, params=None, timeout=30):
        self._id += 1
        rid = self._id
        loop = asyncio.get_running_loop()
        fut  = loop.create_future()
        self._pending[rid] = fut
        msg = {'jsonrpc': '2.0', 'id': rid, 'method': method}
        if params:
            msg['params'] = params
        self._send(msg)
        return await asyncio.wait_for(fut, timeout=timeout)

    async def initialize(self, client_name='script'):
        await self._rpc('initialize', {
            'protocolVersion': '2024-11-05',
            'capabilities': {},
            'clientInfo': {'name': client_name, 'version': '1.0'}
        }, timeout=15)
        self._send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        print(f'[{client_name}] MCP initialized', file=sys.stderr)

    async def emit_block(self, block_id, block_type, payload, ttl=None, inbox=False):
        args = {'blockId': block_id, 'blockType': block_type, 'payload': payload}
        if ttl is not None:
            args['ttl'] = ttl
        if inbox:
            args['inbox'] = True
        await self._rpc('tools/call', {'name': 'emit_block', 'arguments': args})

    async def clear_block(self, block_id):
        try:
            await self._rpc('tools/call', {'name': 'clear_block', 'arguments': {'blockId': block_id}}, timeout=10)
        except Exception:
            pass

    def set_callback(self, block_id, coro_fn):
        self._cbs[block_id] = coro_fn

    async def read_loop(self):
        loop = asyncio.get_running_loop()
        stdin_buf = sys.stdin.buffer
        while True:
            try:
                raw = await loop.run_in_executor(None, stdin_buf.readline)
            except Exception:
                break
            if not raw:
                break
            line = raw.decode('utf-8', errors='replace').strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            self._dispatch(msg)
        print('[mcp] stdin closed', file=sys.stderr)

    def _dispatch(self, msg):
        rid = msg.get('id')
        if rid is not None and 'result' in msg:
            fut = self._pending.pop(rid, None)
            if fut and not fut.done():
                fut.set_result(msg['result'])
            return
        if rid is not None and 'error' in msg:
            fut = self._pending.pop(rid, None)
            if fut and not fut.done():
                fut.set_exception(Exception(str(msg['error'])))
            return
        if msg.get('method') == 'notifications/message':
            data = msg.get('params', {}).get('data', {})
            if data.get('type') == 'user_response':
                block_id = data.get('blockId', '')
                value    = data.get('value', '')
                cb = self._cbs.pop(block_id, None)
                if cb:
                    asyncio.create_task(cb(value))


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

SCAN_ROOT    = os.path.expanduser('~')
REFRESH_SECS = 300   # 5 minutes
MAX_REPOS    = 100

SKIP_DIRS = {
    'node_modules', 'Library', '.Trash', 'Pods', 'DerivedData', '.build',
    'build', 'dist', 'vendor', 'venv', '.venv', '.cache', '.npm', '.yarn',
    '.pnpm', '__pycache__', 'target', 'env', '.env', 'Volumes',
    '.Spotlight-V100', '.fseventsd', '.DocumentRevisions-V100',
}

# Ollama
OLLAMA_BASE_URL = 'http://localhost:11434'
DIFF_MAX_CHARS  = 4000   # truncate diffs sent to Ollama

# Block IDs
BLOCK_TILE         = 'git-tile'
BLOCK_LIST         = 'git-list'
BLOCK_STATUS       = 'git-status'
BLOCK_CONFIRM      = 'git-confirm'
BLOCK_COMMIT_MSG   = 'git-commit-msg'   # proposed commit message detail
BLOCK_COMMIT_EDIT  = 'git-commit-edit'  # manual commit message prompt


# ---------------------------------------------------------------------------
# Ollama helpers (blocking — run via executor)
# ---------------------------------------------------------------------------

def _ollama_models() -> list:
    """Return list of installed model names, or [] if Ollama is not reachable."""
    try:
        req  = urllib.request.Request(
            f'{OLLAMA_BASE_URL}/api/tags',
            headers={'User-Agent': 'ask-git-repos/1.0'}
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read())
        return [m['name'] for m in data.get('models', [])]
    except Exception:
        return []


def _ollama_generate_commit_msg(diff: str, status: str, model: str) -> str:
    """Ask Ollama to produce a commit subject plus a short summary."""
    truncated_diff = diff[:DIFF_MAX_CHARS] + ('\n[diff truncated]' if len(diff) > DIFF_MAX_CHARS else '')
    prompt = (
        'Generate a git commit proposal for the following changes.\n'
        'Rules:\n'
        '- First line: a specific imperative commit subject under 72 characters\n'
        '- Then a blank line\n'
        '- Then 2 to 4 short bullet points summarizing the most important changes\n'
        '- Mention behavior changes and noteworthy implementation details, not generic filler\n'
        '- Do not use markdown headings, code fences, or surrounding quotes\n'
        '- Return only the proposal text\n\n'
        f'Changed files:\n{status}\n\n'
        f'Diff:\n{truncated_diff}'
    )
    body = json.dumps({
        'model':   model,
        'messages': [{'role': 'user', 'content': prompt}],
        'stream':  False,
    }).encode()
    req = urllib.request.Request(
        f'{OLLAMA_BASE_URL}/api/chat',
        data=body,
        headers={'Content-Type': 'application/json', 'User-Agent': 'ask-git-repos/1.0'}
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read())
    return data.get('message', {}).get('content', '').strip()


def _split_commit_proposal(proposal: str) -> tuple[str, str]:
    """Return (subject, details) from an Ollama proposal."""
    lines = [line.rstrip() for line in proposal.splitlines()]
    subject = ''
    details_lines: list[str] = []
    for line in lines:
        if line.strip():
            subject = line.strip()
            break
    if not subject:
        return '', ''
    subject = re.sub(r'^[\-\*\d\.\)\s]+', '', subject).strip()
    seen_subject = False
    for line in lines:
        stripped = line.strip()
        if not seen_subject:
            if stripped == subject:
                seen_subject = True
            continue
        details_lines.append(line)
    details = '\n'.join(details_lines).strip()
    return subject, details


# ---------------------------------------------------------------------------
# Git helpers
# ---------------------------------------------------------------------------

def _git(path, *args, timeout=5):
    """Run a git command in the given repo path. Returns (returncode, stdout, stderr)."""
    try:
        r = subprocess.run(
            ['git', '-C', path, *args],
            capture_output=True, text=True,
            timeout=timeout, stdin=subprocess.DEVNULL
        )
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except subprocess.TimeoutExpired:
        return 1, '', 'timeout'
    except Exception as e:
        return 1, '', str(e)


def _get_diff(path: str) -> tuple:
    """Return (diff_text, status_text) for the repo at path."""
    _, diff, _   = _git(path, 'diff', 'HEAD', timeout=10)
    _, status, _ = _git(path, 'status', '--short')
    if not diff:
        _, diff, _ = _git(path, 'diff', timeout=10)
    return diff, status


def _repo_status(path):
    """Return a dict describing the current state of the repo at path."""
    rc, branch, _ = _git(path, 'rev-parse', '--abbrev-ref', 'HEAD')
    if rc != 0 or not branch or branch == 'HEAD':
        return None

    rc, tracking, _ = _git(path, 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
    tracking = tracking if rc == 0 and tracking else None

    ahead, behind = 0, 0
    if tracking:
        rc, counts, _ = _git(path, 'rev-list', '--left-right', '--count', f'HEAD...{tracking}')
        if rc == 0 and counts:
            parts = counts.split()
            if len(parts) == 2:
                try:
                    ahead, behind = int(parts[0]), int(parts[1])
                except ValueError:
                    pass

    rc, remote_out, _ = _git(path, 'remote')
    has_remote = rc == 0 and bool(remote_out.strip())

    rc, status_out, _ = _git(path, 'status', '--porcelain')
    dirty_lines = [l for l in (status_out or '').splitlines() if l.strip()]

    return {
        'path':        path,
        'name':        os.path.basename(path),
        'branch':      branch,
        'tracking':    tracking,
        'has_remote':  has_remote,
        'ahead':       ahead,
        'behind':      behind,
        'dirty':       len(dirty_lines) > 0,
        'dirty_count': len(dirty_lines),
    }


def _find_repos():
    """Walk SCAN_ROOT and return a list of repo root paths."""
    repos = []
    try:
        for dirpath, dirnames, _ in os.walk(SCAN_ROOT, followlinks=False):
            dirnames[:] = [
                d for d in dirnames
                if d not in SKIP_DIRS and (not d.startswith('.') or d == '.git')
            ]
            if '.git' in dirnames:
                repos.append(dirpath)
                dirnames[:] = []
                if len(repos) >= MAX_REPOS:
                    return repos
    except Exception as e:
        print(f'[git-repos] walk error: {e}', file=sys.stderr)
    return repos


def _scan_all():
    """Discover all repos and collect their statuses. Runs in executor thread."""
    paths = _find_repos()
    print(f'[git-repos] found {len(paths)} repos', file=sys.stderr)

    repos = []
    for path in paths:
        try:
            info = _repo_status(path)
            if info:
                repos.append(info)
        except Exception as e:
            print(f'[git-repos] status error {path}: {e}', file=sys.stderr)

    def priority(r):
        if r['ahead'] > 0:  return 0
        if r['dirty']:       return 1
        if r['behind'] > 0: return 2
        return 3

    repos.sort(key=lambda r: (priority(r), r['name'].lower()))
    return repos


def _repo_key(path):
    return hashlib.md5(path.encode()).hexdigest()[:8]


def _state_label(repo):
    parts = []
    if repo['ahead'] > 0:
        parts.append(f'↑{repo["ahead"]} to push')
    if repo['behind'] > 0:
        parts.append(f'↓{repo["behind"]} to pull')
    if repo['dirty']:
        parts.append(f'{repo["dirty_count"]} changed')
    if not parts:
        if not repo['has_remote'] and not repo['tracking']:
            parts.append('local only')
        else:
            parts.append('up to date')
    return ' · '.join(parts)


# ---------------------------------------------------------------------------
# Script
# ---------------------------------------------------------------------------

class GitReposScript:
    def __init__(self, mcp: MCPClient):
        self.mcp = mcp
        self.repos: list = []
        self._open_detail_id: str | None = None

    async def run(self, test_mode: bool):
        await self._refresh()
        asyncio.create_task(self._refresh_loop())
        if test_mode:
            print('[git-repos] test mode — sleeping 30s', file=sys.stderr)
            await asyncio.sleep(30)
            return
        await asyncio.Event().wait()

    async def _refresh_loop(self):
        while True:
            await asyncio.sleep(REFRESH_SECS)
            await self._refresh()

    async def _refresh(self):
        loop = asyncio.get_running_loop()
        self.repos = await loop.run_in_executor(None, _scan_all)
        await self._emit_tile()
        await self._emit_list()

    async def _emit_tile(self):
        needs_attn = [r for r in self.repos if r['ahead'] > 0 or r['dirty']]
        total = len(self.repos)
        attn  = len(needs_attn)
        if total == 0:
            label, color = 'No repos found', 'orange'
        elif attn > 0:
            noun = 'repo' if attn == 1 else 'repos'
            label = f'{attn} {noun} need attention'
            color = 'orange'
        else:
            label = f'All {total} repos up to date'
            color = 'green'
        await self.mcp.emit_block(BLOCK_TILE, 'tile', {
            'label': label,
            'status_color': color,
        }, ttl=600)

    async def _emit_list(self):
        items = [
            {
                'id':       _repo_key(r['path']),
                'label':    r['name'],
                'subtitle': f'{r["branch"]} · {_state_label(r)}',
            }
            for r in self.repos
        ]
        self.mcp.set_callback(BLOCK_LIST, self._on_list_response)
        await self.mcp.emit_block(BLOCK_LIST, 'list', {
            'title':   f'{len(self.repos)} Local Repositories',
            'items':   items,
            'actions': ['Refresh'],
        }, ttl=3600)

    async def _on_list_response(self, value: str):
        if value == 'Refresh':
            await self._refresh()
            return
        repo = next((r for r in self.repos if _repo_key(r['path']) == value), None)
        if not repo:
            self.mcp.set_callback(BLOCK_LIST, self._on_list_response)
            return
        self.mcp.set_callback(BLOCK_LIST, self._on_list_response)
        await self._show_detail(repo)

    async def _show_detail(self, repo: dict):
        block_id = f'git-detail-{_repo_key(repo["path"])}'
        if self._open_detail_id and self._open_detail_id != block_id:
            await self.mcp.clear_block(self._open_detail_id)
        self._open_detail_id = block_id

        lines = [f'**Branch:** {repo["branch"]}']
        if repo['tracking']:
            lines.append(f'**Tracking:** {repo["tracking"]}')
        elif repo['has_remote']:
            lines.append('**Remote:** configured (no tracking branch)')
        else:
            lines.append('**Remote:** none configured')
        if repo['ahead'] > 0:
            n = repo['ahead']
            lines.append(f'**Ahead:** {n} unpushed commit{"s" if n != 1 else ""}')
        if repo['behind'] > 0:
            n = repo['behind']
            lines.append(f'**Behind:** {n} commit{"s" if n != 1 else ""} not yet pulled')
        if repo['dirty']:
            n = repo['dirty_count']
            lines.append(f'**Uncommitted:** {n} file{"s" if n != 1 else ""} changed')
        if repo['ahead'] == 0 and repo['behind'] == 0 and not repo['dirty']:
            lines.append('**Status:** up to date')
        lines.append(f'\n`{repo["path"]}`')

        actions = []
        if repo['dirty']:
            actions.append('Commit')
        if repo['ahead'] > 0 and repo['tracking']:
            actions.append('Push')
        if repo['behind'] > 0 and repo['tracking']:
            actions.append('Pull')
        if repo['has_remote'] or repo['tracking']:
            actions.append('Fetch')
        if repo['dirty']:
            actions.append('Discard Changes')

        async def on_detail_response(value: str):
            if value == 'dismissed':
                self._open_detail_id = None
                await self.mcp.clear_block(block_id)
                return
            await self._handle_action(repo, block_id, value)

        self.mcp.set_callback(block_id, on_detail_response)
        await self.mcp.emit_block(block_id, 'detail', {
            'title':   repo['name'],
            'body':    '\n'.join(lines),
            'actions': actions,
        }, ttl=3600)

    async def _handle_action(self, repo: dict, detail_block_id: str, action: str):
        path = repo['path']
        if action == 'Commit':
            await self._start_commit_flow(repo, detail_block_id)
        elif action == 'Push':
            await self._run_git_op(repo, detail_block_id, 'Pushing…', ['git', '-C', path, 'push'])
        elif action == 'Pull':
            await self._run_git_op(repo, detail_block_id, 'Pulling…', ['git', '-C', path, 'pull'])
        elif action == 'Fetch':
            await self._run_git_op(repo, detail_block_id, 'Fetching…', ['git', '-C', path, 'fetch'])
        elif action == 'Discard Changes':
            await self._confirm_discard(repo, detail_block_id)

    async def _run_git_op(self, repo: dict, detail_block_id: str | None,
                          label: str, cmd: list, then: list | None = None):
        await self.mcp.emit_block(BLOCK_STATUS, 'status', {
            'label': label, 'icon': 'arrow.clockwise', 'color': 'blue',
        }, ttl=60)
        loop = asyncio.get_running_loop()
        rc, out, err = await loop.run_in_executor(None, lambda: _run_cmd(cmd))
        if rc == 0 and then:
            rc, out, err = await loop.run_in_executor(None, lambda: _run_cmd(then))
        await self.mcp.clear_block(BLOCK_STATUS)
        if rc == 0:
            await self.mcp.emit_block(BLOCK_STATUS, 'status', {
                'label': 'Done', 'icon': 'checkmark.circle', 'color': 'green',
            }, ttl=5)
            await asyncio.sleep(2)
            await self.mcp.clear_block(BLOCK_STATUS)
        else:
            msg = (err or out or 'Unknown error')[:200]
            await self.mcp.emit_block(BLOCK_STATUS, 'status', {
                'label': f'Failed: {msg}', 'icon': 'exclamationmark.triangle', 'color': 'red',
            }, ttl=15)
            await asyncio.sleep(5)
            await self.mcp.clear_block(BLOCK_STATUS)
        updated = await loop.run_in_executor(None, lambda: _repo_status(repo['path']))
        if updated:
            for i, r in enumerate(self.repos):
                if r['path'] == repo['path']:
                    self.repos[i] = updated
                    break
            self.repos.sort(key=lambda r: (
                0 if r['ahead'] > 0 else 1 if r['dirty'] else 2 if r['behind'] > 0 else 3,
                r['name'].lower()
            ))
        await self._emit_tile()
        await self._emit_list()
        if updated:
            await self._show_detail(updated)

    async def _start_commit_flow(self, repo: dict, detail_block_id: str):
        path = repo['path']
        await self.mcp.emit_block(BLOCK_STATUS, 'status', {
            'label': 'Getting diff…', 'icon': 'arrow.clockwise', 'color': 'blue',
        }, ttl=30)
        loop = asyncio.get_running_loop()
        diff, status_out = await loop.run_in_executor(None, lambda: _get_diff(path))
        models = await loop.run_in_executor(None, _ollama_models)
        if models:
            model = models[0]
            await self.mcp.emit_block(BLOCK_STATUS, 'status', {
                'label': 'Generating commit message…', 'icon': 'cpu', 'color': 'blue',
            }, ttl=90)
            try:
                message = await loop.run_in_executor(
                    None, lambda: _ollama_generate_commit_msg(diff, status_out, model)
                )
            except Exception as e:
                print(f'[git-repos] ollama error: {e}', file=sys.stderr)
                message = None
        else:
            message = None
        await self.mcp.clear_block(BLOCK_STATUS)
        if message:
            await self._show_commit_proposal(repo, detail_block_id, message)
        else:
            await self._show_commit_edit(repo, detail_block_id)

    async def _show_commit_proposal(self, repo: dict, detail_block_id: str, proposal: str):
        await self.mcp.clear_block(detail_block_id)
        subject, details = _split_commit_proposal(proposal)
        if not subject:
            await self._show_commit_edit(repo, detail_block_id)
            return
        async def on_proposal(value: str):
            await self.mcp.clear_block(BLOCK_COMMIT_MSG)
            if value == 'Commit':
                await self._do_commit(repo, subject, details)
            elif value == 'Edit':
                await self._show_commit_edit(repo, detail_block_id, prefill_hint=proposal)
            elif value == 'dismissed':
                loop = asyncio.get_running_loop()
                updated = await loop.run_in_executor(None, lambda: _repo_status(repo['path']))
                await self._show_detail(updated or repo)
        self.mcp.set_callback(BLOCK_COMMIT_MSG, on_proposal)
        body = f'**Proposed subject:**\n\n{subject}'
        if details:
            body += f'\n\n**Summary:**\n\n{details}'
        await self.mcp.emit_block(BLOCK_COMMIT_MSG, 'detail', {
            'title':   f'Commit {repo["name"]}',
            'body':    body,
            'actions': ['Commit', 'Edit'],
        }, ttl=3600)

    async def _show_commit_edit(self, repo: dict, detail_block_id: str, prefill_hint: str = None):
        await self.mcp.clear_block(detail_block_id)
        await self.mcp.clear_block(BLOCK_COMMIT_MSG)
        placeholder = prefill_hint or 'Describe what changed…'
        async def on_message(value: str):
            value = value.strip()
            if not value:
                await self._show_commit_edit(repo, detail_block_id, prefill_hint)
                return
            await self.mcp.clear_block(BLOCK_COMMIT_EDIT)
            subject, details = _split_commit_proposal(value)
            if not subject:
                await self._show_commit_edit(repo, detail_block_id, prefill_hint)
                return
            await self._do_commit(repo, subject, details)
        self.mcp.set_callback(BLOCK_COMMIT_EDIT, on_message)
        await self.mcp.emit_block(BLOCK_COMMIT_EDIT, 'prompt', {
            'title':       f'Commit message — {repo["name"]}',
            'placeholder': placeholder,
            'multiline':   True,
        }, ttl=3600, inbox=True)

    async def _do_commit(self, repo: dict, subject: str, details: str = ''):
        path = repo['path']
        commit_cmd = ['git', '-C', path, 'commit', '-m', subject]
        if details:
            commit_cmd += ['-m', details]
        await self._run_git_op(
            repo, None, 'Committing…',
            ['git', '-C', path, 'add', '-A'],
            then=commit_cmd
        )

    async def _confirm_discard(self, repo: dict, detail_block_id: str):
        n = repo['dirty_count']
        noun = 'files' if n != 1 else 'file'
        async def on_confirm(value: str):
            await self.mcp.clear_block(BLOCK_CONFIRM)
            if value == 'Discard':
                await self._run_git_op(
                    repo, detail_block_id, 'Discarding changes…',
                    ['git', '-C', repo['path'], 'restore', '.']
                )
            else:
                await self._show_detail(repo)
        await self.mcp.clear_block(detail_block_id)
        self._open_detail_id = None
        self.mcp.set_callback(BLOCK_CONFIRM, on_confirm)
        await self.mcp.emit_block(BLOCK_CONFIRM, 'confirmation', {
            'title': f'Discard all changes in {repo["name"]}?',
            'body':  (
                f'This will permanently discard {n} changed {noun}. '
                f'This cannot be undone.'
            ),
            'options': ['Discard', 'Cancel'],
        }, ttl=120, inbox=True)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _run_cmd(cmd: list):
    try:
        r = subprocess.run(
            cmd, capture_output=True, text=True,
            timeout=30, stdin=subprocess.DEVNULL
        )
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except subprocess.TimeoutExpired:
        return 1, '', 'Operation timed out'
    except Exception as e:
        return 1, '', str(e)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

async def main():
    test_mode = '--test' in sys.argv or 'test' in sys.argv
    if test_mode:
        print('[git-repos] running in test mode', file=sys.stderr)
    mcp = MCPClient()
    asyncio.create_task(mcp.read_loop())
    await mcp.initialize(client_name='git-repos')
    script = GitReposScript(mcp)
    await script.run(test_mode=test_mode)


if __name__ == '__main__':
    asyncio.run(main())
