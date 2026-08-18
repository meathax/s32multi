"""Drive the sv-graph server over stdio the way an MCP client would.

Run from the project root:  python tools/sv-graph/smoke_test.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
SERVER = os.path.join(ROOT, 'tools', 'sv-graph', 'svgraph_server.py')

REQUESTS = [
    {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
     'params': {'protocolVersion': '2024-11-05', 'capabilities': {},
                'clientInfo': {'name': 'smoke', 'version': '0'}}},
    {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
    {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
    {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call',
     'params': {'name': 'sv_status', 'arguments': {}}},
    {'jsonrpc': '2.0', 'id': 4, 'method': 'tools/call',
     'params': {'name': 'sv_module', 'arguments': {'name': 's32_jpark_gun_gain'}}},
    {'jsonrpc': '2.0', 'id': 5, 'method': 'tools/call',
     'params': {'name': 'sv_hierarchy', 'arguments': {'path': 'emu.core.v25', 'depth': 1}}},
    {'jsonrpc': '2.0', 'id': 6, 'method': 'tools/call',
     'params': {'name': 'sv_instances', 'arguments': {'module': 's32_linebuf'}}},
    {'jsonrpc': '2.0', 'id': 7, 'method': 'tools/call',
     'params': {'name': 'sv_search', 'arguments': {'pattern': 'lightgun'}}},
    {'jsonrpc': '2.0', 'id': 8, 'method': 'tools/call',
     'params': {'name': 'sv_module', 'arguments': {'name': 'no_such_module'}}},
    {'jsonrpc': '2.0', 'id': 9, 'method': 'tools/call',
     'params': {'name': 'sv_check', 'arguments': {'max_lines': 12}}},
]


def main() -> int:
    payload = '\n'.join(json.dumps(r) for r in REQUESTS) + '\n'
    proc = subprocess.run(
        [sys.executable, SERVER], input=payload, capture_output=True, text=True,
        cwd=ROOT, timeout=600,
    )
    if proc.stderr.strip():
        print('--- server stderr ---')
        print(proc.stderr.strip()[:2000])

    failures = 0
    for line in proc.stdout.splitlines():
        message = json.loads(line)
        request_id = message.get('id')
        if 'error' in message:
            print(f'[{request_id}] RPC ERROR {message["error"]}')
            failures += 1
            continue
        result = message['result']
        if request_id == 2:
            print(f'[2] tools/list -> {[t["name"] for t in result["tools"]]}')
            continue
        if 'content' not in result:
            print(f'[{request_id}] initialize -> {result.get("serverInfo")}')
            continue
        text = result['content'][0]['text']
        flag = ' (isError)' if result.get('isError') else ''
        if result.get('isError'):
            failures += 1
        print(f'\n===== [{request_id}]{flag} =====')
        print(text[:1200])

    print('\nfailures:', failures)
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
