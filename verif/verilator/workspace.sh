#!/usr/bin/env bash
# Shared machine-wide-safe Verilator workspace allocator.

s32_verilator_workspace() {
  local safe_launcher="$1"
  local host_path
  host_path="$("$safe_launcher" workspace)" || return
  host_path="${host_path%$'\r'}"
  case "$host_path" in
    [Rr]:\\Verilator\\*) ;;
    *) echo "invalid Verilator workspace from launcher: $host_path" >&2; return 125 ;;
  esac

  export VERILATOR_WORKSPACE="$host_path"
  export VERILATOR_PROJECT="${VERILATOR_PROJECT:-s32}"
  if command -v cygpath >/dev/null 2>&1; then
    S32_VERILATOR_WORKSPACE="$(cygpath -u "$host_path")"
  else
    S32_VERILATOR_WORKSPACE="/mnt/r/${host_path#?:\\}"
    S32_VERILATOR_WORKSPACE="${S32_VERILATOR_WORKSPACE//\\//}"
  fi
  export S32_VERILATOR_WORKSPACE
  mkdir -p "$S32_VERILATOR_WORKSPACE"
}

s32_verilator_mdir() {
  local name="${1:-obj_dir}"
  local path="$S32_VERILATOR_WORKSPACE/$name"
  mkdir -p "$path"
  printf '%s\n' "$path"
}
