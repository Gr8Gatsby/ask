#!/usr/bin/env python3
"""
github — Ask daemon script
Browse GitHub repositories and manage issues from your iPhone.
"""
import os
import sys
import json
import asyncio
import subprocess
from typing import Optional

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

    async def emit_block(self, block_id, block_type, payload, ttl=None):
        args = {'blockId': block_id, 'blockType': block_type, 'payload': payload}
        if ttl is not None:
            args['ttl'] = ttl
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
# Block IDs
# ---------------------------------------------------------------------------

BLOCK_ICON        = 'github-icon'
BLOCK_STATUS      = 'github-status'
BLOCK_SETUP       = 'github-setup'
BLOCK_REPO_PICK   = 'github-repo-picker'
BLOCK_ISSUES_LIST = 'github-issues-list'
BLOCK_NEW_TITLE   = 'github-new-title'
BLOCK_NEW_BODY    = 'github-new-body'
BLOCK_NEW_CONF    = 'github-new-confirm'
BLOCK_TILE        = 'github-tile'


# ---------------------------------------------------------------------------
# GitHub CLI helpers
# ---------------------------------------------------------------------------

def _find_gh() -> str:
    for candidate in ('/opt/homebrew/bin/gh', '/usr/local/bin/gh', '/usr/bin/gh'):
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    import shutil
    return shutil.which('gh') or 'gh'

_GH = _find_gh()


def gh_json(*args):
    result = subprocess.run(
        [_GH, *args],
        capture_output=True, text=True, stdin=subprocess.DEVNULL
    )
    if result.returncode != 0:
        print(f'[github] gh error: {result.stderr.strip()}', file=sys.stderr)
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


def gh_run(*args):
    result = subprocess.run(
        [_GH, *args],
        capture_output=True, text=True, stdin=subprocess.DEVNULL
    )
    return result.returncode, result.stdout.strip(), result.stderr.strip()


# ---------------------------------------------------------------------------
# GitHub script
# ---------------------------------------------------------------------------

class GitHubScript:
    def __init__(self, mcp: MCPClient):
        self.mcp = mcp
        self.selected_repo: Optional[str] = None
        self.new_issue_title: Optional[str] = None
        self._cached_issues: list = []
        self._current_detail_block_id: Optional[str] = None

    async def run(self, test_mode: bool):
        asyncio.create_task(self._tile_heartbeat())

        await self.mcp.emit_block(BLOCK_ICON, 'icon_card', {
            'title': 'GitHub',
            'subtitle': 'Select a repository to get started',
        }, ttl=86400)
        await self._update_tile()
        await self.show_repo_picker()

        if test_mode:
            print('[github] test mode complete', file=sys.stderr)
            await asyncio.sleep(60)
            return

        await asyncio.Event().wait()

    # -- Tile --

    async def _tile_heartbeat(self):
        while True:
            await asyncio.sleep(300)
            await self._update_tile()

    async def _update_tile(self):
        if not self.selected_repo:
            await self.mcp.emit_block(BLOCK_TILE, 'tile', {
                'label': 'GitHub',
                'body': 'No repo selected',
            }, ttl=600)
        else:
            name = self.selected_repo.split('/')[-1]
            count = len(self._cached_issues)
            noun = 'issue' if count == 1 else 'issues'
            await self.mcp.emit_block(BLOCK_TILE, 'tile', {
                'label': name,
                'body': f'{count} open {noun}',
                'status_color': 'orange' if count > 0 else 'green',
            }, ttl=600)

    # -- Setup check --

    def _gh_check(self):
        if not os.path.isfile(_GH) or not os.access(_GH, os.X_OK):
            return ('not_found', None)
        rc, stdout, stderr = gh_run('auth', 'status')
        if rc == 0:
            return ('ok', None)
        combined = (stdout + ' ' + stderr).lower()
        if any(k in combined for k in ('not logged', '401', 'not authenticated', 'no accounts')):
            return ('not_authed', None)
        return ('error', stderr or stdout or 'Unknown error')

    async def _check_setup(self) -> bool:
        loop = asyncio.get_running_loop()
        status, msg = await loop.run_in_executor(None, self._gh_check)

        if status == 'ok':
            await self.mcp.clear_block(BLOCK_SETUP)
            return True

        if status == 'not_found':
            title = 'gh CLI not installed'
            body  = 'Install it in Terminal:\n  brew install gh\n\nThen authenticate:\n  gh auth login\n\nTap Retry when done.'
        elif status == 'not_authed':
            title = 'GitHub not authenticated'
            body  = 'Run in Terminal:\n  gh auth login\n\nTap Retry when done.'
        else:
            title = 'GitHub CLI error'
            body  = msg

        async def on_retry(_value):
            await self.mcp.clear_block(BLOCK_SETUP)
            await self.show_repo_picker()

        self.mcp.set_callback(BLOCK_SETUP, on_retry)
        await self.mcp.emit_block(BLOCK_SETUP, 'confirmation', {
            'title': title,
            'body':  body,
            'options': ['Retry'],
        }, ttl=86400)
        return False

    # -- Repo picker --

    async def show_repo_picker(self):
        await self.mcp.emit_block(BLOCK_STATUS, 'status', {
            'label': 'Checking gh CLI...',
            'icon': 'arrow.clockwise',
            'color': 'blue',
        }, ttl=30)

        if not await self._check_setup():
            await self.mcp.clear_block(BLOCK_STATUS)
            return

        await self.mcp.emit_block(BLOCK_STATUS, 'status', {
            'label': 'Loading repositories...',
            'icon': 'arrow.clockwise',
            'color': 'blue',
        }, ttl=60)

        loop = asyncio.get_running_loop()
        repos = await loop.run_in_executor(None, self._fetch_repos)
        await self.mcp.clear_block(BLOCK_STATUS)

        if not repos:
            await self.mcp.emit_block(BLOCK_STATUS, 'status', {
                'label': 'Could not load repositories',
                'detail': 'Check that gh CLI is working correctly.',
                'icon': 'exclamationmark.triangle',
                'color': 'red',
            }, ttl=300)
            return

        options = [r['nameWithOwner'] for r in repos]
        selected = self.selected_repo if self.selected_repo in options else options[0]

        self.mcp.set_callback(BLOCK_REPO_PICK, self._on_repo_selected)
        await self.mcp.emit_block(BLOCK_REPO_PICK, 'picker', {
            'title': 'Select Repository',
            'options': options,
            'selected': selected,
        }, ttl=3600)

    def _fetch_repos(self):
        data = gh_json('repo', 'list', '--limit', '50',
                       '--json', 'nameWithOwner,isPrivate,description')
        return data or []

    async def _on_repo_selected(self, value: str):
        self.selected_repo = value
        print(f'[github] repo selected: {value}', file=sys.stderr)
        await self.mcp.clear_block(BLOCK_REPO_PICK)
        await self.mcp.clear_block(BLOCK_ICON)
        await self.show_repo_home()

    # -- Repo home --

    async def show_repo_home(self):
        await self._clear_issue_blocks()

        await self.mcp.emit_block(BLOCK_STATUS, 'status', {
            'label': f'Loading {self.selected_repo}...',
            'icon': 'arrow.clockwise',
            'color': 'blue',
        }, ttl=60)

        loop = asyncio.get_running_loop()
        self._cached_issues = await loop.run_in_executor(None, self._fetch_issues)
        await self.mcp.clear_block(BLOCK_STATUS)

        await self._update_tile()
        await self.show_issues()

    def _fetch_issues(self):
        data = gh_json(
            'issue', 'list',
            '--repo', self.selected_repo,
            '--limit', '20',
            '--state', 'open',
            '--json', 'number,title,body,state,createdAt,author,labels',
        )
        return data or []

    async def _clear_issue_blocks(self):
        ids = [BLOCK_ISSUES_LIST, BLOCK_NEW_TITLE, BLOCK_NEW_BODY, BLOCK_NEW_CONF]
        if self._current_detail_block_id:
            ids.append(self._current_detail_block_id)
            self._current_detail_block_id = None
        for block_id in ids:
            await self.mcp.clear_block(block_id)

    # -- Issues list --

    async def show_issues(self):
        count = len(self._cached_issues)
        noun = 'issue' if count == 1 else 'issues'
        title = (f'{self.selected_repo} — No open issues'
                 if count == 0
                 else f'{self.selected_repo} — {count} open {noun}')

        items = [
            {
                'id': f'#{i["number"]}',
                'label': f'#{i["number"]} {i["title"]}',
                'subtitle': f'@{i["author"]["login"]}' if i.get('author') else None,
            }
            for i in self._cached_issues
        ]

        self.mcp.set_callback(BLOCK_ISSUES_LIST, self._on_issues_list_response)
        await self.mcp.emit_block(BLOCK_ISSUES_LIST, 'list', {
            'title': title,
            'items': items,
            'actions': ['New Issue', 'Refresh', 'Change Repo'],
        }, ttl=3600)

    async def _on_issues_list_response(self, value: str):
        if value == 'New Issue':
            await self.show_new_issue_title()
        elif value == 'Refresh':
            await self.show_repo_home()
        elif value == 'Change Repo':
            await self._clear_issue_blocks()
            await self.show_repo_picker()
        else:
            # Issue tapped — re-register so the list stays tappable
            self.mcp.set_callback(BLOCK_ISSUES_LIST, self._on_issues_list_response)
            try:
                number = int(value.lstrip('#'))
            except ValueError:
                return
            issue = next((i for i in self._cached_issues if i['number'] == number), None)
            if issue:
                await self.show_issue_detail(issue)

    # -- Issue detail --

    async def show_issue_detail(self, issue: dict):
        number  = issue['number']
        title   = issue['title']
        body    = (issue.get('body') or '').strip()
        author  = issue.get('author', {}).get('login', 'unknown')
        labels  = ', '.join(l['name'] for l in issue.get('labels', [])) or None
        created = issue.get('createdAt', '')[:10]

        # Clear any previously open detail block
        if self._current_detail_block_id:
            await self.mcp.clear_block(self._current_detail_block_id)

        block_id = f'github-issue-{number}'
        self._current_detail_block_id = block_id

        # Markdown body: metadata header + issue body
        meta = f'**#{number}** · @{author} · {created}'
        if labels:
            meta += f' · {labels}'
        detail_body = meta + (f'\n\n{body}' if body else '')

        async def on_dismissed(_value: str):
            self._current_detail_block_id = None
            await self.mcp.clear_block(block_id)
            # Re-register list callback so the user can tap another issue
            self.mcp.set_callback(BLOCK_ISSUES_LIST, self._on_issues_list_response)

        self.mcp.set_callback(block_id, on_dismissed)
        await self.mcp.emit_block(block_id, 'detail', {
            'title': title,
            'body': detail_body,
        }, ttl=3600)

    # -- New issue --

    async def show_new_issue_title(self):
        await self.mcp.clear_block(BLOCK_ISSUES_LIST)
        if self._current_detail_block_id:
            await self.mcp.clear_block(self._current_detail_block_id)
            self._current_detail_block_id = None
        await self.mcp.clear_block(BLOCK_NEW_BODY)
        await self.mcp.clear_block(BLOCK_NEW_CONF)
        self.mcp.set_callback(BLOCK_NEW_TITLE, self._on_new_issue_title)
        await self.mcp.emit_block(BLOCK_NEW_TITLE, 'prompt', {
            'title': f'New Issue — {self.selected_repo}',
            'placeholder': 'Short description of the issue',
        }, ttl=3600)

    async def _on_new_issue_title(self, value: str):
        if not value.strip():
            self.mcp.set_callback(BLOCK_NEW_TITLE, self._on_new_issue_title)
            return
        self.new_issue_title = value.strip()
        await self.mcp.clear_block(BLOCK_NEW_TITLE)
        self.mcp.set_callback(BLOCK_NEW_BODY, self._on_new_issue_body)
        await self.mcp.emit_block(BLOCK_NEW_BODY, 'chat_prompt', {
            'title': 'Issue Body (optional)',
            'context': f'Title: {self.new_issue_title}',
            'placeholder': 'Describe the issue in detail...',
        }, ttl=3600)

    async def _on_new_issue_body(self, value: str):
        body = value.strip()
        await self.mcp.clear_block(BLOCK_NEW_BODY)

        preview = f'**Title:** {self.new_issue_title}'
        if body:
            snippet = body[:300] + ('...' if len(body) > 300 else '')
            preview += f'\n\n{snippet}'

        async def on_confirm(v):
            await self._on_new_issue_confirm(v, body)

        self.mcp.set_callback(BLOCK_NEW_CONF, on_confirm)
        await self.mcp.emit_block(BLOCK_NEW_CONF, 'confirmation', {
            'title': f'Create issue in {self.selected_repo}?',
            'body': preview,
            'options': ['Submit', 'Cancel'],
        }, ttl=3600)

    async def _on_new_issue_confirm(self, value: str, body: str):
        await self.mcp.clear_block(BLOCK_NEW_CONF)

        if value == 'Cancel':
            await self.show_repo_home()
            return

        await self.mcp.emit_block(BLOCK_STATUS, 'status', {
            'label': 'Creating issue...',
            'icon': 'arrow.clockwise',
            'color': 'blue',
        }, ttl=60)

        loop = asyncio.get_running_loop()
        title = self.new_issue_title
        url = await loop.run_in_executor(None, lambda: self._create_issue(title, body))
        await self.mcp.clear_block(BLOCK_STATUS)

        if url:
            issue_num = url.rstrip('/').split('/')[-1]
            await self.mcp.emit_block(BLOCK_STATUS, 'status', {
                'label': f'Issue #{issue_num} created',
                'detail': title,
                'icon': 'checkmark.circle',
                'color': 'green',
            }, ttl=10)
            self.new_issue_title = None
            await asyncio.sleep(2)
            await self.mcp.clear_block(BLOCK_STATUS)
        else:
            await self.mcp.emit_block(BLOCK_STATUS, 'status', {
                'label': 'Failed to create issue',
                'icon': 'exclamationmark.triangle',
                'color': 'red',
            }, ttl=30)
            await asyncio.sleep(3)
            await self.mcp.clear_block(BLOCK_STATUS)

        await self.show_repo_home()

    def _create_issue(self, title: str, body: str) -> Optional[str]:
        rc, stdout, stderr = gh_run(
            'issue', 'create',
            '--repo', self.selected_repo,
            '--title', title,
            '--body', body or '',
        )
        if rc != 0:
            print(f'[github] create issue error: {stderr}', file=sys.stderr)
            return None
        return stdout or None


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

async def main():
    test_mode = len(sys.argv) > 1 and sys.argv[1] in ('test', '--test')
    if test_mode:
        print('[github] running in test mode', file=sys.stderr)

    mcp = MCPClient()
    asyncio.create_task(mcp.read_loop())
    await mcp.initialize(client_name='github')

    script = GitHubScript(mcp)
    await script.run(test_mode=test_mode)


if __name__ == '__main__':
    asyncio.run(main())
