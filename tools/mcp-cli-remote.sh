#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: tools/mcp-cli-remote.sh [sync|check|test|build|package|all]

Run the MCP CLI Rust checks and packaging on the x-p35 build box. Cargo is
always executed through SSH on x-p35; this script never invokes local Cargo.

Environment:
  MCP_CLI_REMOTE_HOST   SSH host (default: x-p35)
  MCP_CLI_REMOTE_DIR    isolated remote directory (default: generated /tmp path)
  MCP_CLI_PLATFORM      package target (default: linux-x64)
  MCP_CLI_VERSION       npm version (default: root package version)
  MCP_CLI_BINARY_PATH   built binary (default: target/release/tm-control-mcp)
EOF
}

die() {
    echo "mcp-cli-remote: $*" >&2
    exit 1
}

quote_sh() {
    local value=$1
    printf "'%s'" "${value//\'/\'\\\'\'}"
}

command -v ssh >/dev/null 2>&1 || die "ssh is required"
command -v rsync >/dev/null 2>&1 || die "rsync is required"
command -v git >/dev/null 2>&1 || die "git is required"

action=${1:-all}
case "$action" in
    sync|check|test|build|package|all) ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

repo_root=$(git rev-parse --show-toplevel) || die "run from a git checkout"
remote_host=${MCP_CLI_REMOTE_HOST:-x-p35}
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
remote_dir=${MCP_CLI_REMOTE_DIR:-/tmp/tm-control-mcp-mcp-cli-${USER:-unknown}-${timestamp}-$$}
platform=${MCP_CLI_PLATFORM:-linux-x64}
version=${MCP_CLI_VERSION:-}
binary_path=${MCP_CLI_BINARY_PATH:-}

case "$platform" in
    linux-x64)
        default_binary_path=target/release/tm-control-mcp
        ;;
    win32-x64)
        default_binary_path=target/release/tm-control-mcp.exe
        ;;
    *)
        die "unsupported MCP_CLI_PLATFORM '$platform' (use linux-x64 or win32-x64)"
        ;;
esac
binary_path=${binary_path:-$default_binary_path}

ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10)

remote() {
    local command=$1
    ssh "${ssh_opts[@]}" "$remote_host" "cd $(quote_sh "$remote_dir") && $command"
}

ensure_remote_checkout() {
    ssh "${ssh_opts[@]}" "$remote_host" "mkdir -p $(quote_sh "$remote_dir")" \
        || die "cannot reach build box '$remote_host' or create '$remote_dir'"
    rsync -az --delete \
        --exclude .git \
        --exclude target \
        --exclude dist \
        --exclude '.worktrees' \
        "$repo_root/" "$remote_host:$remote_dir/" \
        || die "failed to sync checkout to $remote_host:$remote_dir"
    remote "test -f mcp-cli/Cargo.toml || { echo 'mcp-cli/Cargo.toml is missing on the build box' >&2; exit 1; }"
}

require_remote_tools() {
    remote "command -v cargo >/dev/null || { echo 'cargo is unavailable on x-p35' >&2; exit 127; }; command -v python3 >/dev/null || { echo 'python3 is unavailable on x-p35' >&2; exit 127; }"
}

run_check() {
    require_remote_tools
    remote "cargo fmt --manifest-path mcp-cli/Cargo.toml --all -- --check"
    remote "cargo check --manifest-path mcp-cli/Cargo.toml --all-targets --locked"
}

run_test() {
    require_remote_tools
    remote "cargo test --manifest-path mcp-cli/Cargo.toml --all-targets --locked"
}

run_build() {
    require_remote_tools
    remote "cargo build --manifest-path mcp-cli/Cargo.toml --release --locked"
}

run_package() {
    require_remote_tools
    remote "command -v npm >/dev/null || { echo 'npm is unavailable on x-p35' >&2; exit 127; }"
    remote "cargo package --manifest-path mcp-cli/Cargo.toml --locked --allow-dirty"
    if [[ -z "$version" ]]; then
        version=$(remote "python3 -c 'import json; print(json.load(open(\"mcp-cli/npm/tm-control-mcp/package.json\"))[\"version\"])'")
    fi
    local binary_argument
    binary_argument=$(quote_sh "$binary_path")
    local version_argument
    version_argument=$(quote_sh "$version")
    local platform_argument
    platform_argument=$(quote_sh "$platform")
    remote "test -f $binary_argument || { echo 'built binary is missing: $binary_path' >&2; exit 1; }"
    remote "rm -rf dist/mcp-cli dist/packages && mkdir -p dist/packages"
    remote "python3 packaging/mcp-cli-package.py --source-root mcp-cli/npm --output dist/mcp-cli --platform $platform_argument --binary $binary_argument --version $version_argument"
    remote "python3 packaging/verify-mcp-cli-artifacts.py --source-root mcp-cli/npm --artifact-root dist/mcp-cli --version $version_argument"
    remote "npm pack --ignore-scripts --pack-destination dist/packages dist/mcp-cli/tm-control-mcp"
    remote "npm pack --ignore-scripts --pack-destination dist/packages dist/mcp-cli/$(case $platform in linux-x64) echo tm-control-mcp-linux-x64;; win32-x64) echo tm-control-mcp-win32-x64;; esac)"
    echo "mcp-cli-remote: packages are in $remote_host:$remote_dir/dist/packages"
}

case "$action" in
    sync)
        ensure_remote_checkout
        ;;
    check)
        ensure_remote_checkout
        run_check
        ;;
    test)
        ensure_remote_checkout
        run_test
        ;;
    build)
        ensure_remote_checkout
        run_build
        ;;
    package)
        ensure_remote_checkout
        run_package
        ;;
    all)
        ensure_remote_checkout
        run_check
        run_test
        run_build
        run_package
        ;;
esac

echo "mcp-cli-remote: $action completed on $remote_host:$remote_dir"
