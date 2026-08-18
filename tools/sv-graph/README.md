# sv-graph

An MCP server that gives an agent an elaborated view of the SystemVerilog design.

CodeGraph, which indexes the rest of this repository, has no SystemVerilog
parser — it sees the Lua and Python verification tooling and nothing else. That
leaves the RTL with no symbol index at all. sv-graph closes that gap using
[slang](https://github.com/MikePopoloski/slang), which does not merely parse the
sources but fully elaborates them: parameters are resolved to values, generate
blocks are expanded, and every instance has a real hierarchical path that
matches simulation and Quartus.

That distinction is the point. Questions like "what parameters is this module
actually built with", "what is the full path to this instance", or "does the
design still elaborate after my port change" cannot be answered by grep or by a
syntax-only tool. They can be answered from an elaborated design in one call.

## What it indexes

The source list is not hand-maintained. `svgraph_qip.py` walks `files.qip` and
`Arcade-SegaSystem32.qsf`, follows nested `.qip` files, and resolves both path
spellings used in this tree — plain relative paths and the Tcl
`[file join $::quartus(qip_path) ...]` form, including local aliases such as
`set V25_QIP_DIR $::quartus(qip_path)` in `rtl/cpu/v25/v25.qip`.

`VERILOG_MACRO` assignments from the QSF are collected and passed to slang as
`-D`, so the indexed design is configured exactly as Quartus configures it
(`S32_UNIVERSAL`, `S32_V25_HW`, `S80X86_PSEUDO_286_INT=0`, and the rest). Change
a macro in the QSF and the index follows it.

Current coverage: 136 SystemVerilog/Verilog sources, 130 module definitions, 228
elaborated instances, top `emu`. Elaboration takes about 3 seconds and is clean —
0 errors, 0 warnings.

Two deliberate omissions:

- **VHDL is skipped.** slang cannot read it, so T80 and the `sys/` VHDL blocks
  are reported in `sv_status` and left as black boxes. The count is shown so the
  gap is never silent.
- **`sys/` is excluded** via the `exclude` list in `svgraph.config.json`. The
  MiSTer framework declares signals inside `generate` blocks and references them
  outside, which Quartus tolerates and slang rejects. Excluding it costs nothing:
  `--ignore-unknown-modules` treats `hps_io` and friends as black boxes, and the
  core hierarchy below `emu` is what matters. Drop the exclusion if you ever need
  framework-side checking, and expect errors from `hps_io.sv`.

## Tools

| Tool | Answers |
| --- | --- |
| `sv_status` | Does the design elaborate? How many sources, definitions, instances? Is the index stale? Which macros are active? |
| `sv_module` | One module's file:line, ports with directions and elaborated types, resolved parameter values, and every path it is instantiated at. `source=true` adds the verbatim source. |
| `sv_hierarchy` | The instance tree below a path, generate blocks already expanded. |
| `sv_instances` | Every elaborated instance of a module with the parameters bound at each site — check this before changing a module's ports or parameters. |
| `sv_search` | Regex over module names and instance paths. |
| `sv_check` | Re-elaborate and return diagnostics. Catches cross-module port, width and parameter errors that per-file lint cannot see. `warnings=true` for the full set. |
| `sv_source` | A line range of any project file, with line numbers. |
| `sv_reindex` | Force a rebuild. |

The index rebuilds automatically when any tracked source or manifest changes
mtime, so `sv_reindex` is rarely needed.

## Layout

    tools/sv-graph/
      svgraph.config.json   manifests, top, exclusions, slang flags
      svgraph_qip.py        Quartus manifest resolution
      svgraph_index.py      slang invocation and index distillation
      svgraph_server.py     the MCP server
      smoke_test.py         drives the server over stdio end to end

The cache lives in `.svgraph/index.json` (about 150 KB) and is gitignored. The
70 MB slang AST dump it is distilled from is deleted immediately after each
build.

## Running it

Registered for this project in `.mcp.json`; Claude Code starts it automatically.

Rebuild the index by hand:

    python tools/sv-graph/svgraph_index.py .

Verify the server end to end:

    python tools/sv-graph/smoke_test.py

No third-party Python packages are required — the JSON-RPC transport is
implemented directly. slang must be on `PATH`, or set an absolute path in the
`slang` field of `svgraph.config.json`.

## Scope

sv-graph is a navigation and elaboration-checking tool. It is not a substitute
for Verilator simulation, MAME differential testing, or a Quartus fit: it says
nothing about timing, resource use, or runtime behaviour. A clean `sv_check` is
evidence the design elaborates, nothing more.
