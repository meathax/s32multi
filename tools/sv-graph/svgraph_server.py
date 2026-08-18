"""sv-graph: an MCP stdio server exposing slang's elaborated view of the core.

CodeGraph does not parse SystemVerilog, so the RTL half of this repository has
no symbol index. This server fills that gap using slang, which fully elaborates
the design: parameter values are resolved, generate blocks are expanded, and
every instance has a real hierarchical path. That is information no grep and no
syntax-only tool can produce.

Transport is newline-delimited JSON-RPC 2.0 over stdin/stdout, implemented
directly so the server has no third-party dependencies.
"""

from __future__ import annotations

import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import svgraph_index as index_mod

PROTOCOL_VERSION = '2024-11-05'
SERVER_INFO = {'name': 'sv-graph', 'version': '1.0.0'}

ROOT = os.environ.get('SVGRAPH_ROOT') or os.getcwd()
ROOT = os.path.abspath(ROOT)

_config = None
_index = None


def config() -> dict:
    global _config
    if _config is None:
        _config = index_mod.load_config(ROOT)
    return _config


def index(refresh: bool = False) -> dict:
    global _index
    if refresh or _index is None:
        _index = index_mod.load(ROOT, config())
    elif index_mod.stale(ROOT, _index):
        _index = index_mod.build(ROOT, config())
    return _index


# --------------------------------------------------------------------------
# Tool implementations
# --------------------------------------------------------------------------

def _read_lines(rel: str, start: int, end: int) -> str:
    path = os.path.join(ROOT, rel.replace('/', os.sep))
    if not os.path.isfile(path):
        return f'(source not found: {rel})'
    with open(path, errors='replace') as handle:
        lines = handle.readlines()
    start = max(1, start)
    end = min(len(lines), end)
    width = len(str(end))
    return ''.join(f'{n:>{width}}\t{lines[n - 1]}' for n in range(start, end + 1))


def _module_extent(rel: str, start_line: int) -> int:
    """Find the ``endmodule`` that closes the definition starting at start_line."""
    path = os.path.join(ROOT, rel.replace('/', os.sep))
    if not os.path.isfile(path):
        return start_line
    with open(path, errors='replace') as handle:
        lines = handle.readlines()
    for number in range(start_line, len(lines) + 1):
        if re.match(r'\s*end(module|package|interface)\b', lines[number - 1]):
            return number
    return len(lines)


def tool_status(_args: dict) -> str:
    data = index()
    changed = index_mod.stale(ROOT, data)
    lines = [
        f'root: {ROOT}',
        f'tops: {", ".join(data["tops"])}',
        f'elaboration: {"OK" if data["elaborated"] else "FAILED"} ({data["slang_seconds"]}s)',
        f'sources: {data["source_count"]} SV/V, {data["vhdl_count"]} VHDL skipped (slang cannot read VHDL)',
        f'definitions: {len(data["definitions"])}   instances: {len(data["instances"])}',
        f'stale files: {len(changed)}',
        'macros (from the QSF, same set Quartus applies): '
        + (', '.join(data.get('defines') or []) or 'none'),
    ]
    if data.get('unresolved'):
        lines.append('unresolved manifest entries: ' + ', '.join(data['unresolved'][:8]))
    if not data['elaborated']:
        lines.append('--- slang output ---')
        lines.append(data['slang_stdout'] or data['slang_stderr'])
    return '\n'.join(lines)


def tool_module(args: dict) -> str:
    name = args['name']
    data = index()
    definition = data['definitions'].get(name)
    if not definition:
        near = [k for k in data['definitions'] if name.lower() in k.lower()][:10]
        return f'No definition named {name!r}.' + (f' Similar: {", ".join(near)}' if near else '')

    paths = [i['path'] for i in data['instances'] if i['module'] == name]
    out = [f'{name}  —  {definition["file"]}:{definition["line"]}']
    if definition.get('uninstantiated'):
        out.append('(defined but not reached from the elaborated top)')
    out.append(f'instantiated {len(paths)} time(s)')
    for path in paths[:20]:
        out.append(f'  {path}')
    if len(paths) > 20:
        out.append(f'  ... {len(paths) - 20} more')

    if definition['ports']:
        out.append('')
        out.append('ports:')
        for port in definition['ports']:
            out.append(f'  {port["direction"]:<6} {port["type"]:<24} {port["name"]}')

    matched = next((i for i in data['instances'] if i['module'] == name), None)
    if matched and matched['params']:
        out.append('')
        out.append(f'elaborated parameters at {matched["path"]}:')
        for key, value in matched['params'].items():
            out.append(f'  {key} = {value}')

    if args.get('source'):
        end = _module_extent(definition['file'], definition['line'])
        out.append('')
        out.append(f'--- {definition["file"]}:{definition["line"]}-{end} ---')
        out.append(_read_lines(definition['file'], definition['line'], end))
    return '\n'.join(out)


def tool_hierarchy(args: dict) -> str:
    root_path = args.get('path') or ''
    depth = int(args.get('depth', 2))
    data = index()
    if root_path:
        subtree = [i for i in data['instances']
                   if i['path'] == root_path or i['path'].startswith(root_path + '.')]
        if not subtree:
            return f'No instance path {root_path!r}. Try sv_search.'
        base = root_path.count('.')
    else:
        subtree = data['instances']
        base = 0
    out = []
    for entry in subtree:
        level = entry['path'].count('.') - base
        if level > depth:
            continue
        leaf = entry['path'].rsplit('.', 1)[-1]
        out.append(f'{"  " * level}{leaf} : {entry["module"]}   ({entry["file"]}:{entry["line"]})')
    hidden = len(subtree) - len(out)
    if hidden > 0:
        out.append(f'... {hidden} deeper instance(s) hidden; raise depth or pass a deeper path')
    return '\n'.join(out)


def tool_instances(args: dict) -> str:
    module = args['module']
    data = index()
    matched = [i for i in data['instances'] if i['module'] == module]
    if not matched:
        return f'{module!r} is not instantiated under the elaborated top.'
    out = [f'{module}: {len(matched)} instance(s)']
    for entry in matched:
        out.append(f'  {entry["path"]}   ({entry["file"]}:{entry["line"]})')
        for key, value in list(entry['params'].items())[:12]:
            out.append(f'      {key} = {value}')
    return '\n'.join(out)


def tool_search(args: dict) -> str:
    pattern = re.compile(args['pattern'], re.IGNORECASE)
    data = index()
    modules = [d for d in sorted(data['definitions']) if pattern.search(d)]
    paths = [i['path'] for i in data['instances'] if pattern.search(i['path'])]
    out = []
    if modules:
        out.append('modules:')
        for name in modules[:40]:
            definition = data['definitions'][name]
            out.append(f'  {name}   {definition["file"]}:{definition["line"]}')
    if paths:
        out.append('instance paths:')
        for path in paths[:40]:
            out.append(f'  {path}')
    return '\n'.join(out) if out else 'no match'


def tool_check(args: dict) -> str:
    """Re-elaborate from scratch and report slang diagnostics."""
    cfg = dict(config())
    if args.get('warnings'):
        cfg['slang_flags'] = cfg.get('lint_flags', cfg['slang_flags'])
    run = index_mod.run_slang(ROOT, cfg)
    body = (run['stdout'] + run['stderr']).strip()
    limit = int(args.get('max_lines', 200))
    lines = body.splitlines()
    head = '\n'.join(lines[:limit])
    if len(lines) > limit:
        head += f'\n... {len(lines) - limit} more diagnostic line(s) suppressed'
    return f'slang exit {run["returncode"]} in {run["seconds"]}s\n{head}'


def tool_source(args: dict) -> str:
    return _read_lines(args['file'], int(args.get('start', 1)), int(args.get('end', 200)))


def tool_reindex(_args: dict) -> str:
    data = index(refresh=True)
    return (f'rebuilt: {len(data["definitions"])} definitions, '
            f'{len(data["instances"])} instances, elaboration '
            f'{"OK" if data["elaborated"] else "FAILED"}')


TOOLS = [
    {
        'name': 'sv_status',
        'description': ('Elaboration health of the SystemVerilog design: whether slang elaborates '
                        'the top cleanly, source counts, index freshness. Call this first if any '
                        'other sv_* tool returns something surprising.'),
        'inputSchema': {'type': 'object', 'properties': {}},
        'handler': tool_status,
    },
    {
        'name': 'sv_module',
        'description': ('Everything about one module: file:line, port list with directions and '
                        'elaborated types, resolved parameter values, and every hierarchical path '
                        'it is instantiated at. Set source=true to also get its verbatim source.'),
        'inputSchema': {
            'type': 'object',
            'properties': {
                'name': {'type': 'string', 'description': 'Module name, e.g. s32_lightgun'},
                'source': {'type': 'boolean', 'description': 'Include the module source text'},
            },
            'required': ['name'],
        },
        'handler': tool_module,
    },
    {
        'name': 'sv_hierarchy',
        'description': ('Elaborated instance tree. Omit path for the top. Use this to answer '
                        '"what is under X" or "what is the full path to Y" — generate blocks are '
                        'already expanded, so the paths match simulation and Quartus.'),
        'inputSchema': {
            'type': 'object',
            'properties': {
                'path': {'type': 'string', 'description': 'Hierarchical root, e.g. emu.core.video'},
                'depth': {'type': 'integer', 'description': 'Levels below path (default 2)'},
            },
        },
        'handler': tool_hierarchy,
    },
    {
        'name': 'sv_instances',
        'description': ('Every elaborated instance of a module, with the parameter values actually '
                        'bound at each site. Use before changing a module\'s ports or parameters.'),
        'inputSchema': {
            'type': 'object',
            'properties': {'module': {'type': 'string'}},
            'required': ['module'],
        },
        'handler': tool_instances,
    },
    {
        'name': 'sv_search',
        'description': 'Regex search over module names and elaborated instance paths.',
        'inputSchema': {
            'type': 'object',
            'properties': {'pattern': {'type': 'string'}},
            'required': ['pattern'],
        },
        'handler': tool_search,
    },
    {
        'name': 'sv_check',
        'description': ('Re-elaborate the design with slang and return diagnostics. Catches port '
                        'mismatches, width and parameter errors across module boundaries that a '
                        'per-file lint cannot see. Set warnings=true for the full warning set.'),
        'inputSchema': {
            'type': 'object',
            'properties': {
                'warnings': {'type': 'boolean'},
                'max_lines': {'type': 'integer'},
            },
        },
        'handler': tool_check,
    },
    {
        'name': 'sv_source',
        'description': 'Read a line range of a project file with line numbers.',
        'inputSchema': {
            'type': 'object',
            'properties': {
                'file': {'type': 'string', 'description': 'Path relative to the project root'},
                'start': {'type': 'integer'},
                'end': {'type': 'integer'},
            },
            'required': ['file'],
        },
        'handler': tool_source,
    },
    {
        'name': 'sv_reindex',
        'description': 'Force a full re-elaboration and rebuild of the index cache.',
        'inputSchema': {'type': 'object', 'properties': {}},
        'handler': tool_reindex,
    },
]

HANDLERS = {tool['name']: tool['handler'] for tool in TOOLS}
TOOL_SPECS = [{k: v for k, v in tool.items() if k != 'handler'} for tool in TOOLS]


# --------------------------------------------------------------------------
# JSON-RPC plumbing
# --------------------------------------------------------------------------

def _result(request_id, payload):
    return {'jsonrpc': '2.0', 'id': request_id, 'result': payload}


def _error(request_id, code, message):
    return {'jsonrpc': '2.0', 'id': request_id, 'error': {'code': code, 'message': message}}


def handle(message: dict):
    method = message.get('method')
    request_id = message.get('id')

    if method == 'initialize':
        return _result(request_id, {
            'protocolVersion': PROTOCOL_VERSION,
            'capabilities': {'tools': {}},
            'serverInfo': SERVER_INFO,
        })
    if method in ('notifications/initialized', 'notifications/cancelled'):
        return None
    if method == 'ping':
        return _result(request_id, {})
    if method == 'tools/list':
        return _result(request_id, {'tools': TOOL_SPECS})
    if method == 'tools/call':
        params = message.get('params') or {}
        name = params.get('name')
        handler = HANDLERS.get(name)
        if not handler:
            return _error(request_id, -32601, f'unknown tool {name!r}')
        try:
            text = handler(params.get('arguments') or {})
        except Exception as exc:  # surfaced to the caller rather than killing the server
            return _result(request_id, {
                'content': [{'type': 'text', 'text': f'{type(exc).__name__}: {exc}'}],
                'isError': True,
            })
        return _result(request_id, {'content': [{'type': 'text', 'text': text}]})
    if request_id is None:
        return None
    return _error(request_id, -32601, f'unknown method {method!r}')


def main() -> None:
    out = sys.stdout
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        response = handle(message)
        if response is not None:
            out.write(json.dumps(response) + '\n')
            out.flush()


if __name__ == '__main__':
    main()
