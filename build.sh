#!/usr/bin/env bash
set -euo pipefail

mode="${1:-dev}"
case "$mode" in
  dev|release|release-check) ;;
  *)
    echo "usage: ./build.sh [dev|release|release-check]" >&2
    echo "  dev            stage folder plugin WITH defines=DEV + (Dev) name, reload" >&2
    echo "  release-check  stage folder plugin WITHOUT DEV (release-like), reload — required before tag" >&2
    echo "  release        build tm-control-mcp-<version>.op (no DEV injection)" >&2
    exit 2
    ;;
esac

plugins_dir="${PLUGINS_DIR:-${OPENPLANET_DIR:-$HOME/OpenplanetNext}/Plugins}"

plugin_slug() {
  local root="$1"
  local manifest="${root%/}/info.toml"
  local pretty
  pretty="$(awk -F= '/^name/ { print $2; exit }' "$manifest" | tr -d '"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  pretty="${pretty:-$(basename "$root")}"
  echo "$pretty" | tr -d "+(),:;'\"" | tr '[:upper:] ' '[:lower:]-'
}

local_dependency_root() {
  case "$1" in
    AiApi) echo "../tm-aiapi" ;;
    *) return 1 ;;
  esac
}

local_dependencies() {
  awk '
    /^\[script\]/ { in_script = 1; next }
    /^\[/ { in_script = 0 }
    in_script && /^[[:space:]]*dependencies[[:space:]]*=/ {
      line = $0
      gsub(/.*=\s*\[/, "", line)
      gsub(/\].*/, "", line)
      gsub(/"/, "", line)
      gsub(/,/, " ", line)
      print line
    }
  ' info.toml
}

run_lsp_check() {
  if [[ "${TM_PLUGIN_SKIP_LSP:-0}" == "1" ]] || ! command -v openplanet-lsp >/dev/null 2>&1; then
    return 0
  fi

  openplanet-lsp check \
    --plugins-dir "$plugins_dir" \
    --plugins-dir "$(cd .. && pwd)" \
    .
}

# stage_folder_plugin ROOT SLUG DEV_MODE
# DEV_MODE: 1 = inject defines=["DEV"] + optional (Dev) name suffix
#           0 = leave #__DEFINES__ alone (release-like / release-check)
stage_folder_plugin() {
  local root="$1"
  local slug="$2"
  local dev_mode="${3:-0}"
  local dest="$plugins_dir/$slug"
  mkdir -p "$dest"
  rsync -a --delete "$root/src/" "$dest/"
  cp "$root/info.toml" "$dest/info.toml"
  if [[ "$dev_mode" == "1" ]]; then
    sed -i 's/^#__DEFINES__/defines = ["DEV"]/' "$dest/info.toml"
    sed -i 's/^\(name[ \t="]*\)\(.*\)"/\1\2 (Dev)"/' "$dest/info.toml"
  else
    # Ensure no leftover DEV define if someone hand-edited staged tree before
    sed -i '/^defines[[:space:]]*=/d' "$dest/info.toml"
  fi
  echo "Copied $(basename "$root") to $dest (dev_mode=$dev_mode)"
  if [[ "$dev_mode" == "0" ]]; then
    echo "Staged info.toml defines:"; grep -n 'define\|timeout\|^name' "$dest/info.toml" || true
  fi
}

remote_load_folder() {
  local slug="$1"
  if ! command -v tm-remote-build >/dev/null 2>&1 || [[ "${TM_PLUGIN_SKIP_RELOAD:-0}" == "1" ]]; then
    return 0
  fi

  local op_dir host
  local host_args=()
  op_dir="$(dirname "$plugins_dir")"
  host="${TM_PLUGIN_REMOTE_HOST:-$(ss -ltnH 2>/dev/null | awk '$4 ~ /:30000$/ { sub(/:[0-9]+$/, "", $4); print $4; exit }')}"
  if [[ -n "$host" && "$host" != "0.0.0.0" && "$host" != "*" ]]; then
    host_args=(--host "$host")
  fi

  tm-remote-build load folder "$slug" -op OpenplanetNext "${host_args[@]}" -d "$op_dir" \
    -l "${TM_PLUGIN_REMOTE_LOG_DONE_LIMIT:-3}" \
    -i "${TM_PLUGIN_REMOTE_LOG_CHECK_INTERVAL:-0.5}"
}

stage_local_dependencies() {
  local dep root dep_slug
  for dep in $(local_dependencies); do
    if root="$(local_dependency_root "$dep")" && [[ -d "$root" ]]; then
      dep_slug="$(plugin_slug "$root")"
      stage_folder_plugin "$root" "$dep_slug" 0
      remote_load_folder "$dep_slug"
    fi
  done
}

plugin_name="$(plugin_slug ".")"

# LSP is advisory for release packaging; in-game compile is ground truth.
# openplanet-lsp often false-positives on nested types / MLHook without game plugins.
if [[ "$mode" == "dev" ]]; then
  run_lsp_check
fi

if [[ "$mode" == "dev" ]]; then
  if [[ "${TM_PLUGIN_STAGE_LOCAL_DEPS:-1}" != "0" ]]; then
    stage_local_dependencies
  fi
  stage_folder_plugin . "$plugin_name" 1
  remote_load_folder "$plugin_name"
elif [[ "$mode" == "release-check" ]]; then
  # Release-like folder stage: NO DEV define, NO (Dev) suffix, then reload.
  if [[ "${TM_PLUGIN_STAGE_LOCAL_DEPS:-1}" != "0" ]]; then
    stage_local_dependencies
  fi
  stage_folder_plugin . "$plugin_name" 0
  remote_load_folder "$plugin_name"
  echo "release-check: staged without DEV. Confirm Openplanet compile Loaded + run tools/call.py status"
else
  version="$(awk -F= '/^version/ { gsub(/[ \"]/, "", $2); print $2; exit }' info.toml)"
  out="$plugin_name-$version.op"
  rm -f "$out"
  # Pack without injecting DEV; include license pointers for redistributors
  7z a "$out" ./src/* ./info.toml ./README.md ./LICENSE ./UNLICENSE ./CC0-1.0 ./SECURITY.md
  echo "Built $out"
  echo "Packed info.toml:"
  7z x -so "$out" info.toml 2>/dev/null | cat || true
fi
