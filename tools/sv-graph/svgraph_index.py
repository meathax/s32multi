"""Build a compact design index by elaborating the core with slang.

slang's ``--ast-json`` dump is ~70 MB for this design, which is far too large to
hand to a model and slow to re-walk per query. This module runs slang once,
distils the dump into a few hundred kilobytes of structure — module definitions,
ports, parameters and the elaborated instance tree — and caches that as
``.svgraph/index.json``. Queries then run against the cache.

Bodies of repeated instances are emitted by slang as an address reference rather
than a repeated subtree, so the walker keeps an address table and follows it.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time

import svgraph_qip

CACHE_DIR = '.svgraph'
INDEX_NAME = 'index.json'


def load_config(root: str) -> dict:
    path = os.path.join(root, 'tools', 'sv-graph', 'svgraph.config.json')
    with open(path) as handle:
        return json.load(handle)


def _slang_exe(config: dict) -> str:
    return config.get('slang') or 'slang'


def _sources(root: str, config: dict) -> svgraph_qip.Sources:
    found = svgraph_qip.resolve(root, config['manifests'])
    found.hdl = svgraph_qip.filter_excluded(found.hdl, config.get('exclude', []))
    found.incdirs = svgraph_qip.filter_excluded(found.incdirs, config.get('exclude', []))
    return found


def _command_file(root: str, found: svgraph_qip.Sources) -> str:
    lines = ['"%s"' % os.path.join(root, p.replace('/', os.sep)) for p in found.hdl]
    lines += ['-I"%s"' % os.path.join(root, p.replace('/', os.sep)) for p in found.incdirs]
    lines += ['-D%s' % d for d in found.defines]
    handle = tempfile.NamedTemporaryFile('w', suffix='.f', delete=False, encoding='utf-8')
    handle.write('\n'.join(lines))
    handle.close()
    return handle.name


def run_slang(root: str, config: dict, extra: list[str] | None = None,
              ast_json: str | None = None, diag_json: str | None = None) -> dict:
    """Invoke slang over the resolved source list. Returns run metadata."""
    found = _sources(root, config)
    cmd_file = _command_file(root, found)
    argv = [_slang_exe(config), '-f', cmd_file]
    for top in config.get('tops', []):
        argv += ['--top', top]
    argv += config.get('slang_flags', [])
    if ast_json:
        argv += ['--ast-json', ast_json, '--ast-json-source-info']
    if diag_json:
        argv += ['--diag-json', diag_json]
    argv += extra or []
    started = time.time()
    try:
        proc = subprocess.run(argv, cwd=root, capture_output=True, text=True, timeout=900)
    finally:
        try:
            os.unlink(cmd_file)
        except OSError:
            pass
    return {
        'returncode': proc.returncode,
        'stdout': proc.stdout,
        'stderr': proc.stderr,
        'seconds': round(time.time() - started, 2),
        'sources': found,
    }


def _members(node: dict) -> list:
    members = node.get('members')
    return members if isinstance(members, list) else []


def _value(node: dict):
    """Best-effort scalar for a parameter's elaborated value."""
    value = node.get('value')
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    if isinstance(value, dict):
        return value.get('value', value.get('constant'))
    return str(value)


class _Walker:
    """Flattens slang's elaborated design into definitions plus an instance tree."""

    def __init__(self):
        self.bodies: dict = {}
        self.instances: list[dict] = []
        self.definitions: dict[str, dict] = {}

    def _body(self, node: dict) -> tuple[dict | None, str | None]:
        """Return ``(body, module_name)`` for an instance.

        slang emits a full body dict the first time a module body is elaborated
        and, for every later instance of the same body, the string
        ``"<addr> <module_name>"`` instead. The address table resolves those
        back to the original subtree; the trailing name is kept as a fallback
        for the few bodies that are referenced before they are emitted.
        """
        body = node.get('body')
        if isinstance(body, dict):
            addr = body.get('addr')
            if addr is not None:
                self.bodies[addr] = body
            return body, body.get('name')
        if isinstance(body, str):
            addr_text, _, name = body.partition(' ')
            try:
                resolved = self.bodies.get(int(addr_text))
            except ValueError:
                resolved = None
            return resolved, (name or None)
        if isinstance(body, int):
            resolved = self.bodies.get(body)
            return resolved, (resolved or {}).get('name')
        return None, None

    def _describe(self, body: dict) -> dict:
        ports, params = [], []
        for member in _members(body):
            kind = member.get('kind')
            if kind == 'Port':
                ports.append({
                    'name': member.get('name'),
                    'direction': member.get('direction'),
                    'type': member.get('type'),
                })
            elif kind == 'Parameter':
                params.append({'name': member.get('name'), 'value': _value(member)})
        return {'ports': ports, 'params': params}

    def visit(self, node, path: str = '') -> None:
        if isinstance(node, list):
            for child in node:
                self.visit(child, path)
            return
        if not isinstance(node, dict):
            return

        if node.get('kind') == 'Instance':
            body, module_hint = self._body(node)
            name = node.get('name') or ''
            here = f'{path}.{name}' if path else name
            module = (body or {}).get('name') or module_hint or '?'
            described = self._describe(body) if body else {'ports': [], 'params': []}
            record = {
                'path': here,
                'module': module,
                'file': (node.get('source_file') or '').replace('\\', '/'),
                'line': node.get('source_line'),
                'params': {p['name']: p['value'] for p in described['params']},
            }
            self.instances.append(record)
            if module not in self.definitions and body:
                self.definitions[module] = {
                    'name': module,
                    'file': (body.get('source_file') or '').replace('\\', '/'),
                    'line': body.get('source_line'),
                    'ports': described['ports'],
                    'params': [p['name'] for p in described['params']],
                }
            if body:
                self.visit(_members(body), here)
            return

        for value in node.values():
            if isinstance(value, (dict, list)):
                self.visit(value, path)


def build(root: str, config: dict) -> dict:
    """Elaborate, distil and cache. Returns the index dict."""
    cache = os.path.join(root, CACHE_DIR)
    os.makedirs(cache, exist_ok=True)
    ast_path = os.path.join(cache, 'ast.json')
    diag_path = os.path.join(cache, 'diagnostics.json')

    run = run_slang(root, config, ast_json=ast_path, diag_json=diag_path)
    found = run['sources']

    index = {
        'generated': time.time(),
        'tops': config.get('tops', []),
        'elaborated': run['returncode'] == 0,
        'slang_seconds': run['seconds'],
        'slang_stdout': run['stdout'][-4000:],
        'slang_stderr': run['stderr'][-4000:],
        'source_count': len(found.hdl),
        'vhdl_count': len(found.vhdl),
        'sources': found.hdl,
        'vhdl': found.vhdl,
        'incdirs': found.incdirs,
        'defines': found.defines,
        'manifests': found.manifests,
        'unresolved': found.unresolved,
        'mtimes': _mtimes(root, found.hdl + found.manifests),
        'definitions': {},
        'instances': [],
    }

    if os.path.isfile(ast_path):
        with open(ast_path) as handle:
            ast = json.load(handle)
        walker = _Walker()
        walker.visit(ast.get('design', {}))
        index['definitions'] = walker.definitions
        index['instances'] = walker.instances
        # Definitions that exist but are never instantiated still matter for
        # navigation, so fold in slang's flat definition list.
        for entry in ast.get('definitions', []):
            name = entry.get('name')
            if name and name not in index['definitions']:
                index['definitions'][name] = {
                    'name': name,
                    'file': (entry.get('source_file') or '').replace('\\', '/'),
                    'line': entry.get('source_line'),
                    'ports': [],
                    'params': [],
                    'uninstantiated': True,
                }
        os.unlink(ast_path)

    if os.path.isfile(diag_path):
        with open(diag_path) as handle:
            try:
                index['diagnostics'] = json.load(handle)
            except json.JSONDecodeError:
                index['diagnostics'] = []

    with open(os.path.join(cache, INDEX_NAME), 'w') as handle:
        json.dump(index, handle)
    return index


def _mtimes(root: str, paths: list[str]) -> dict:
    stamps = {}
    for rel in paths:
        try:
            stamps[rel] = os.path.getmtime(os.path.join(root, rel.replace('/', os.sep)))
        except OSError:
            stamps[rel] = 0
    return stamps


def stale(root: str, index: dict) -> list[str]:
    """Return the tracked files whose mtime moved since the index was built."""
    changed = []
    for rel, was in (index.get('mtimes') or {}).items():
        try:
            now = os.path.getmtime(os.path.join(root, rel.replace('/', os.sep)))
        except OSError:
            changed.append(rel)
            continue
        if now > was:
            changed.append(rel)
    return changed


def load(root: str, config: dict, rebuild_if_stale: bool = True) -> dict:
    path = os.path.join(root, CACHE_DIR, INDEX_NAME)
    if not os.path.isfile(path):
        return build(root, config)
    with open(path) as handle:
        index = json.load(handle)
    if rebuild_if_stale and stale(root, index):
        return build(root, config)
    return index


if __name__ == '__main__':
    project = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else '.')
    cfg = load_config(project)
    result = build(project, cfg)
    print(json.dumps({
        'elaborated': result['elaborated'],
        'seconds': result['slang_seconds'],
        'sources': result['source_count'],
        'vhdl_skipped': result['vhdl_count'],
        'definitions': len(result['definitions']),
        'instances': len(result['instances']),
        'stdout': result['slang_stdout'][-500:],
    }, indent=2))
