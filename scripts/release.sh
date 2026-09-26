#!/usr/bin/env bash
# Release script for the four registry packages, in dependency order:
#
#   1. tramaj-rs       (crates.io)
#   2. tramaj-cli-rs   (crates.io, depends on tramaj-rs)
#   3. tramaj-js       (npm)
#   4. tramaj-react    (npm, depends on tramaj-js)
#
# It bumps versions, runs each package's tests, publishes, and tags.
#
# DRY-RUN IS THE DEFAULT. Without --publish the script never modifies any
# file, never publishes, never tags: it runs the tests for real and prints
# what each remaining step would do (plus non-publishing checks such as
# `npm pack --dry-run` and `cargo package --list`). Publishing needs the
# explicit --publish flag AND RELEASE_CONFIRM=yes in the environment.
# See RELEASING.md for the one-time account/name setup that must be done first.
#
# Usage:
#   scripts/release.sh --set tramaj-js=0.2.0 --set tramaj-react=0.2.0 [options]
#
# Options:
#   --set PKG=VERSION   New version for PKG (repeatable). Packages without
#                       --set are left alone and skipped. Versions are chosen
#                       per package, so lockstep and independent releases are
#                       both expressible.
#   --skip-tests        Do not run the per-package test suites.
#   --publish           Actually bump, publish and tag (needs RELEASE_CONFIRM=yes).
#   -h, --help          Show this help.
#
# Tags are per package, `<pkg>-v<version>` (e.g. tramaj-js-v0.2.0), so they
# do not collide with the repo-wide vX.Y.Z tags.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORDER=(tramaj-rs tramaj-cli-rs tramaj-js tramaj-react)

declare -A NEWVER
PUBLISH=0
SKIP_TESTS=0

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { echo "error: $*" >&2; exit 1; }
say() { echo "==> $*"; }
# run CMD...: execute for real only in publish mode, otherwise print it.
act() {
  if [ "$PUBLISH" = 1 ]; then echo "+ $*"; "$@"; else echo "[dry-run] would run: $*"; fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --set)
      [ $# -ge 2 ] || die "--set needs PKG=VERSION"
      pkg="${2%%=*}"; ver="${2#*=}"
      [[ "$2" == *=* ]] || die "--set needs PKG=VERSION, got '$2'"
      [[ " ${ORDER[*]} " == *" $pkg "* ]] || die "unknown package '$pkg' (one of: ${ORDER[*]})"
      [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || die "'$ver' is not a SemVer version"
      NEWVER[$pkg]="$ver"; shift 2 ;;
    --skip-tests) SKIP_TESTS=1; shift ;;
    --publish) PUBLISH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument '$1' (try --help)" ;;
  esac
done

[ ${#NEWVER[@]} -gt 0 ] || die "nothing to release: pass at least one --set PKG=VERSION"

if [ "$PUBLISH" = 1 ]; then
  [ "${RELEASE_CONFIRM:-}" = yes ] || die "--publish requires RELEASE_CONFIRM=yes"
  [ -z "$(git -C "$ROOT" status --porcelain)" ] || die "working tree is not clean"
  say "PUBLISH MODE"
else
  say "DRY RUN (nothing will be modified, published or tagged)"
fi

is_cargo() { [[ "$1" == *-rs ]]; }
current_version() {
  if is_cargo "$1"; then
    sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/$1/Cargo.toml" | head -1
  else
    node -p "require('$ROOT/$1/package.json').version"
  fi
}

# Dependency sanity: a dependent may only be released with its dependency
# when the dependency is being released now or is expected to be on the registry.
if [ -n "${NEWVER[tramaj-cli-rs]:-}" ] && [ -z "${NEWVER[tramaj-rs]:-}" ]; then
  say "note: tramaj-cli-rs released without tramaj-rs; the tramaj-rs version it pins must already be on crates.io"
fi
if [ -n "${NEWVER[tramaj-react]:-}" ] && [ -z "${NEWVER[tramaj-js]:-}" ]; then
  say "note: tramaj-react released without tramaj-js; the tramaj-js range it depends on must already be on npm"
fi

test_pkg() {
  local p="$1"
  [ "$SKIP_TESTS" = 1 ] && { say "$p: tests skipped"; return; }
  say "$p: tests"
  if is_cargo "$p"; then
    (cd "$ROOT/$p" && cargo test)
  else
    (cd "$ROOT/$p" && { [ -d node_modules ] || npm ci; } && npm run typecheck && npm test && npm run build)
  fi
}

bump_pkg() {
  local p="$1" v="$2" cur
  cur="$(current_version "$p")"
  say "$p: bump $cur -> $v"
  if [ "$PUBLISH" != 1 ]; then
    echo "[dry-run] would set version = $v in $p/$( is_cargo "$p" && echo Cargo.toml || echo package.json )"
    case "$p" in
      tramaj-cli-rs) [ -n "${NEWVER[tramaj-rs]:-}" ] && echo "[dry-run] would pin tramaj-rs dependency to ${NEWVER[tramaj-rs]} in tramaj-cli-rs/Cargo.toml" ;;
      tramaj-react) [ -n "${NEWVER[tramaj-js]:-}" ] && echo "[dry-run] would set tramaj-js dependency to ^${NEWVER[tramaj-js]} in tramaj-react/package.json" ;;
    esac
    return 0
  fi
  if is_cargo "$p"; then
    sed -i "0,/^version = \".*\"/s//version = \"$v\"/" "$ROOT/$p/Cargo.toml"
    if [ "$p" = tramaj-cli-rs ] && [ -n "${NEWVER[tramaj-rs]:-}" ]; then
      sed -i "s|\(tramaj-rs = {[^}]*version = \)\"[^\"]*\"|\1\"${NEWVER[tramaj-rs]}\"|" "$ROOT/$p/Cargo.toml"
    fi
    (cd "$ROOT/$p" && cargo update -w --offline >/dev/null 2>&1 || true)
  else
    (cd "$ROOT/$p" && npm version "$v" --no-git-tag-version --allow-same-version >/dev/null)
    if [ "$p" = tramaj-react ] && [ -n "${NEWVER[tramaj-js]:-}" ]; then
      (cd "$ROOT/$p" && node -e "
        const fs=require('fs');const j=JSON.parse(fs.readFileSync('package.json'));
        j.dependencies['tramaj-js']='^${NEWVER[tramaj-js]}';
        fs.writeFileSync('package.json',JSON.stringify(j,null,2)+'\n');")
    fi
  fi
}

publish_pkg() {
  local p="$1"
  say "$p: publish"
  if [ "$PUBLISH" = 1 ]; then
    if is_cargo "$p"; then act bash -c "cd '$ROOT/$p' && cargo publish"
    else act bash -c "cd '$ROOT/$p' && npm publish"; fi
    return
  fi
  # Dry-run: non-publishing checks only.
  if is_cargo "$p"; then
    echo "[dry-run] would run: (cd $p && cargo publish)"
    (cd "$ROOT/$p" && cargo package --list --allow-dirty >/dev/null && echo "cargo package --list: ok")
  else
    echo "[dry-run] would run: (cd $p && npm publish)"
    (cd "$ROOT/$p" && npm pack --dry-run >/dev/null 2>&1 && echo "npm pack --dry-run: ok" || echo "npm pack --dry-run: failed (is dist built?)")
  fi
}

tag_pkg() {
  local p="$1" v="$2"
  say "$p: tag $p-v$v"
  act git -C "$ROOT" tag -a "$p-v$v" -m "$p $v"
}

for p in "${ORDER[@]}"; do
  v="${NEWVER[$p]:-}"
  [ -n "$v" ] || { say "$p: not selected, skipping"; continue; }
  test_pkg "$p"
  bump_pkg "$p" "$v"
  publish_pkg "$p"
  if [ "$PUBLISH" = 1 ]; then
    git -C "$ROOT" commit -qam "Release $p $v" || true
  fi
  tag_pkg "$p" "$v"
done

if [ "$PUBLISH" = 1 ]; then
  say "done; push with: git push && git push --tags"
else
  say "dry run complete: nothing was published, modified or tagged"
fi
