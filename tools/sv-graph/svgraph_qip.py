"""Resolve the project's Quartus source manifests into a flat source list.

The core's file list lives in ``files.qip`` and ``Arcade-SegaSystem32.qsf``,
which reference further ``.qip`` files (sys, T80, jt12, PLL, V25). Two spellings
of a path appear in the tree:

    set_global_assignment -name SYSTEMVERILOG_FILE rtl/s32_core.sv
    set_global_assignment -name VERILOG_FILE [file join $::quartus(qip_path) sys_top.v ]

Both are handled. VHDL sources are collected separately: slang cannot read them,
so they are reported for visibility but never passed to the compiler.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field

# Matches either a bracketed Tcl expression or a plain relative path following
# the assignment name.
_ASSIGN = re.compile(r'-name\s+(\w+)\s+(?:\[([^\]]*)\]|(\S+))')

# `[file join <dir-var> seg seg ...]`. The directory variable is always the QIP's
# own directory in this tree — either `$::quartus(qip_path)` directly, or a local
# alias such as `set V25_QIP_DIR $::quartus(qip_path)` in rtl/cpu/v25/v25.qip.
_FILE_JOIN = re.compile(r'^\s*file\s+join\s+(\S+)((?:\s+"?[^"\s]+"?)*)\s*$')
_QIP_DIR_VAR = re.compile(r'^\$(::quartus\(qip_path\)|\w+)$')

_HDL_KINDS = {'SYSTEMVERILOG_FILE', 'VERILOG_FILE'}


@dataclass
class Sources:
    """Everything the manifests point at, relative to the project root."""

    hdl: list[str] = field(default_factory=list)
    vhdl: list[str] = field(default_factory=list)
    incdirs: list[str] = field(default_factory=list)
    manifests: list[str] = field(default_factory=list)
    defines: list[str] = field(default_factory=list)
    unresolved: list[str] = field(default_factory=list)


def _rel(root: str, path: str) -> str:
    return os.path.relpath(path, root).replace(os.sep, '/')


class _Resolver:
    def __init__(self, root: str):
        self.root = os.path.abspath(root)
        self.out = Sources()
        self._seen_qip: set[str] = set()
        self._seen_hdl: set[str] = set()
        self._incdirs: set[str] = set()

    def _add_hdl(self, abs_path: str, vhdl: bool) -> None:
        key = os.path.normcase(abs_path)
        if key in self._seen_hdl:
            return
        self._seen_hdl.add(key)
        rel = _rel(self.root, abs_path)
        if vhdl:
            self.out.vhdl.append(rel)
        else:
            self.out.hdl.append(rel)
            self._incdirs.add(os.path.dirname(abs_path))

    def qip(self, path: str) -> None:
        abs_path = os.path.abspath(path)
        key = os.path.normcase(abs_path)
        if key in self._seen_qip:
            return
        if not os.path.isfile(abs_path):
            self.out.unresolved.append(_rel(self.root, abs_path))
            return
        self._seen_qip.add(key)
        self.out.manifests.append(_rel(self.root, abs_path))
        base = os.path.dirname(abs_path)
        with open(abs_path, errors='ignore') as handle:
            for line in handle:
                self._assignment(line, base)

    @staticmethod
    def _tcl_path(expr: str) -> str | None:
        """Reduce a `[file join <qip-dir-var> seg ...]` expression to a relative path.

        Returns None for anything else — nested brackets, `regexp`, string
        concatenation — which cannot be resolved without a Tcl interpreter.
        """
        match = _FILE_JOIN.match(expr)
        if not match or not _QIP_DIR_VAR.match(match.group(1)):
            return None
        segments = [s.strip('"') for s in match.group(2).split() if s.strip('"')]
        if not segments or any('$' in s or '[' in s for s in segments):
            return None
        return '/'.join(segments)

    def _assignment(self, line: str, base: str) -> None:
        line = line.strip()
        if line.startswith('#'):
            return
        match = _ASSIGN.search(line)
        if not match:
            return
        kind = match.group(1)
        if kind == 'VERILOG_MACRO':
            # Quartus applies these globally; the design's `ifdef structure
            # depends on them, so slang must see the same set.
            macro = (match.group(3) or '').strip('"')
            if macro and macro not in self.out.defines:
                self.out.defines.append(macro)
            return
        if match.group(2) is not None:
            raw = self._tcl_path(match.group(2))
            if raw is None:
                # A computed filename, e.g. the Quartus-version-dependent PLL QIP
                # in sys.qip. Not resolvable without running Tcl; noted, not chased.
                note = f'{kind} (Tcl-computed path in {_rel(self.root, base)})'
                if note not in self.out.unresolved:
                    self.out.unresolved.append(note)
                return
        else:
            raw = match.group(3)
        target = os.path.normpath(
            os.path.join(base, raw.strip('"').replace('$(QIP_PATH)', '').replace('\\', '/'))
        )
        if kind == 'QIP_FILE':
            self.qip(target)
        elif kind in _HDL_KINDS:
            if os.path.isfile(target):
                self._add_hdl(target, vhdl=False)
            else:
                self.out.unresolved.append(_rel(self.root, target))
        elif kind == 'VHDL_FILE':
            if os.path.isfile(target):
                self._add_hdl(target, vhdl=True)
        elif kind == 'SEARCH_PATH':
            if os.path.isdir(target):
                self._incdirs.add(target)

    def qsf(self, path: str) -> None:
        abs_path = os.path.abspath(path)
        if not os.path.isfile(abs_path):
            return
        self.out.manifests.append(_rel(self.root, abs_path))
        base = self.root
        with open(abs_path, errors='ignore') as handle:
            for line in handle:
                self._assignment(line, base)

    def finish(self) -> Sources:
        self.out.incdirs = sorted(_rel(self.root, d) for d in self._incdirs)
        return self.out


def resolve(root: str, manifests: list[str]) -> Sources:
    """Expand ``manifests`` (paths relative to ``root``) into a source list."""
    resolver = _Resolver(root)
    for entry in manifests:
        path = os.path.join(resolver.root, entry)
        if entry.lower().endswith('.qsf'):
            resolver.qsf(path)
        else:
            resolver.qip(path)
    return resolver.finish()


def filter_excluded(paths: list[str], excludes: list[str]) -> list[str]:
    """Drop paths matching any of the ``excludes`` prefixes or regexes."""
    if not excludes:
        return list(paths)
    patterns = [re.compile(e) for e in excludes]
    return [p for p in paths if not any(pat.search(p) for pat in patterns)]
