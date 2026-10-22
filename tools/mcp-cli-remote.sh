#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: tools/mcp-cli-remote.sh [sync|fmt|check|test|build|package|all]

Sync this checkout to an isolated build directory on x-p35 (or another SSH
build machine). All Cargo execution is remote. package only stages and packs
an existing binary; it never invokes Cargo or publishes anything.

Environment:
  MCP_CLI_REMOTE_HOST   SSH build machine (default: x-p35)
  MCP_CLI_REMOTE_DIR    absolute directory under remote ~/.cache/tm-control-mcp/builds/
                       (default: unique checkout there)
  MCP_CLI_PLATFORM      linux-x64 (default) or win32-x64
  MCP_CLI_TARGET        optional Rust target triple (must be installed remotely)
  MCP_CLI_VERSION       npm version (default: root package version)
  MCP_CLI_BINARY_PATH   existing binary relative to remote checkout
                       (default: mcp-cli/target/[TARGET/]release/tm-control-mcp[.exe])

Remote TMPDIR is under ~/tmp/tcm-mcp-cli/. Cargo uses at most two jobs.
Use the printed MCP_CLI_REMOTE_DIR to reuse a build for separate commands.
EOF
}

die() { echo "mcp-cli-remote: $*" >&2; exit 1; }
quote_sh() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

action=${1:-all}
case "$action" in
    sync|fmt|check|test|build|package|all) ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || die "expected one action"
for tool in ssh rsync git; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

# Resolve relative to this script, even if invoked from another checkout.
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
remote_host=${MCP_CLI_REMOTE_HOST:-x-p35}
[[ "$remote_host" != -* && "$remote_host" != *[[:space:]]* ]] || die "invalid SSH build host"
platform=${MCP_CLI_PLATFORM:-linux-x64}
target=${MCP_CLI_TARGET:-}
[[ -z "$target" || "$target" =~ ^[a-zA-Z0-9_-]+$ ]] || die "invalid Rust target triple"
case "$platform" in
    linux-x64) executable=tm-control-mcp ;;
    win32-x64) executable=tm-control-mcp.exe ;;
    *) die "unsupported MCP_CLI_PLATFORM '$platform'" ;;
esac
binary_path=${MCP_CLI_BINARY_PATH:-mcp-cli/target/${target:+$target/}release/$executable}
version=${MCP_CLI_VERSION:-}
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10)
remote_home=$(ssh "${ssh_opts[@]}" "$remote_host" 'printf "%s" "$HOME"') \
    || die "build machine '$remote_host' is unavailable; no local Cargo fallback"
[[ "$remote_home" == /* && "$remote_home" != / ]] || die "invalid remote HOME"
build_root=$remote_home/.cache/tm-control-mcp/builds
remote_dir=${MCP_CLI_REMOTE_DIR:-$build_root/checkout-$(date -u +%Y%m%dT%H%M%SZ)-$$}
[[ "$remote_dir" == "$build_root/"* && "$remote_dir" != "$build_root/" ]] \
    || die "MCP_CLI_REMOTE_DIR must be an isolated directory under $build_root/"
[[ "$remote_dir" != *'/../'* && "$remote_dir" != */.. && "$remote_dir" != *'/./'* && "$remote_dir" != */. ]] \
    || die "remote directory must not contain dot segments"
remote_tmp=$remote_home/tmp/tcm-mcp-cli/${remote_dir##*/}

remote() {
    ssh "${ssh_opts[@]}" "$remote_host" \
        "cd $(quote_sh "$remote_dir") && export TMPDIR=$(quote_sh "$remote_tmp") CARGO_BUILD_JOBS=2 CARGO_TARGET_DIR=$(quote_sh "$remote_dir/mcp-cli/target") && $1"
}

ensure_remote_checkout() {
    # Refuse to rsync --delete over an existing, unowned directory.
    ssh "${ssh_opts[@]}" "$remote_host" \
        "set -eu; d=$(quote_sh "$remote_dir"); test ! -L \"\$d\"; if test -d \"\$d\" && ! test -f \"\$d/.tcm-build-checkout\"; then test -z \"\$(ls -A \"\$d\")\" || { echo 'remote directory is not an isolated MCP CLI checkout' >&2; exit 1; }; fi; mkdir -p \"\$d\" $(quote_sh "$remote_tmp"); touch \"\$d/.tcm-build-checkout\"" \
        || die "cannot prepare isolated checkout on '$remote_host'"
    rsync -azs --delete -e 'ssh -o BatchMode=yes -o ConnectTimeout=10' \
        --exclude .git --exclude .worktrees --exclude target --exclude dist \
        --exclude node_modules --exclude __pycache__ --exclude .pytest_cache \
        --exclude .test-deps --exclude .tcm-build-checkout \
        "$repo_root/" "$remote_host:$remote_dir/" \
        || die "failed to sync checkout to $remote_host:$remote_dir"
    echo "mcp-cli-remote: checkout=$remote_host:$remote_dir TMPDIR=$remote_tmp jobs=2"
}

require_rust() {
    remote "test -f mcp-cli/Cargo.toml || { echo 'mcp-cli/Cargo.toml is missing on the build machine' >&2; exit 1; }; command -v cargo >/dev/null || { echo 'Cargo is unavailable on the build machine; no local fallback' >&2; exit 127; }"
}

target_arg=${target:+--target $target}
run_fmt() {
    require_rust
    remote 'cd mcp-cli && cargo fmt --all -- --check'
}
run_check() {
    run_fmt
    remote "cd mcp-cli && cargo check --all-targets --locked --jobs 2 $target_arg"
}
run_test() {
    require_rust
    remote "cd mcp-cli && cargo test --all-targets --locked --jobs 2 $target_arg"
}
run_build() {
    require_rust
    remote "cd mcp-cli && cargo build --bin tm-control-mcp --release --locked --jobs 2 $target_arg"
}
run_package() {
    remote "command -v python3 >/dev/null && command -v npm >/dev/null || { echo 'Python 3 and npm are required on the build machine' >&2; exit 127; }"
    if [[ -z "$version" ]]; then
        version=$(remote "python3 -c 'import json; print(json.load(open(\"mcp-cli/npm/tm-control-mcp/package.json\"))[\"version\"])'")
    fi
    # The stager cleans only its own output packages and validates its input.
    remote "python3 packaging/mcp-cli-package.py --output dist/mcp-cli --platform $(quote_sh "$platform") --binary $(quote_sh "$binary_path") --version $(quote_sh "$version") --pack-output dist/packages"
    remote "python3 packaging/verify-mcp-cli-artifacts.py --artifact-root dist/packages --platform $(quote_sh "$platform") --version $(quote_sh "$version")"
    echo "mcp-cli-remote: verified npm tarballs at $remote_host:$remote_dir/dist/packages"
}

ensure_remote_checkout
case "$action" in
    sync) ;;
    fmt) run_fmt ;;
    check) run_check ;;
    test) run_test ;;
    build) run_build ;;
    package) run_package ;;
    all) run_check; run_test; run_build; run_package ;;
esac
echo "mcp-cli-remote: $action completed on $remote_host:$remote_dir"
