#!/usr/bin/env bash
# Sync the PureScript packages into their standalone registry repos.
#
# The PureScript registry does not support `subdir` (purescript/registry
# issue #16): a package must sit at the root of its own GitHub repo. So
# this mono-repo stays the source of truth and each package is *copied*
# (not history-split) into a dedicated repo:
#
#   tramaj/          -> lucasdicioccio/purescript-tramaj-purs
#   tramaj-halogen/  -> lucasdicioccio/purescript-tramaj-halogen
#
# Each sync stages src/, LICENSE, a short README and a standalone
# spago.yaml (no `test:` block, no `subdir`, a `workspace:` section, and
# `tramaj-purs` as a real version range for halogen), builds it once to
# produce spago.lock, then makes one commit in the copy repo that names
# the source commit. Tag `v<version>` is created from publish.version.
#
# DRY-RUN IS THE DEFAULT: stages and builds in a temp dir and prints the
# diff against the copy repo's current state; nothing is created, committed,
# pushed or tagged. --publish does that and needs RELEASE_CONFIRM=yes.
# This script does NOT submit to the registry; it prints the command.
#
# Usage:
#   scripts/sync-purs-registry-repos.sh [--only tramaj-purs|tramaj-halogen] [--publish]
#
# Env:
#   SPAGO   spago >= 1.0 command (default: npx -y spago@1.0.4; needs Node >= 22.5)
#   OWNER   GitHub owner (default: lucasdicioccio)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="${OWNER:-lucasdicioccio}"
SPAGO="${SPAGO:-npx -y spago@1.0.4}"
# source dir : package name : copy-repo name
PKGS=("tramaj:tramaj-purs:purescript-tramaj-purs" "tramaj-halogen:tramaj-halogen:purescript-tramaj-halogen")
ONLY=""
PUBLISH=0

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { echo "error: $*" >&2; exit 1; }
say() { echo "==> $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="${2:?--only needs a package name}"; shift 2 ;;
    --publish) PUBLISH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done
[ "$PUBLISH" = 0 ] || [ "${RELEASE_CONFIRM:-}" = yes ] || die "--publish needs RELEASE_CONFIRM=yes"
[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ] || die "mono-repo has uncommitted changes to tracked files"

SRC_SHA="$(git -C "$ROOT" rev-parse --short HEAD)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

yaml_publish_version() { awk '/^  publish:/{p=1} p&&/^    version:/{print $2; exit}' "$1"; }

sync_one() { # srcdir pkg repo
  local dir="$1" pkg="$2" repo="$3" stage="$WORK/$3" clone="$WORK/clone-$3"
  local ver; ver="$(yaml_publish_version "$ROOT/$dir/spago.yaml")"
  [ -n "$ver" ] || die "no publish.version in $dir/spago.yaml"
  say "$pkg $ver -> $OWNER/$repo (source $SRC_SHA)"

  mkdir -p "$stage"
  cp -r "$ROOT/$dir/src" "$stage/src"
  cp "$ROOT/LICENSE" "$stage/LICENSE"
  cat >"$stage/README.md" <<EOF
# $pkg

PureScript package \`$pkg\`, published to the
[PureScript registry](https://github.com/purescript/registry).

**This repository is a generated copy.** The source of truth is
[$OWNER/tramaj](https://github.com/$OWNER/tramaj) (\`$dir/\`); issues and
pull requests belong there. Do not edit this repo by hand — the next sync
overwrites it.

See the [tramaj README](https://github.com/$OWNER/tramaj#readme) for what
Tramaj is and how to use this package.

Synced from \`$OWNER/tramaj\` at \`$SRC_SHA\`.
EOF
  local purs_ver; purs_ver="$(yaml_publish_version "$ROOT/tramaj/spago.yaml")"
  local major_minor="${purs_ver%.*}"  # 0.3.2 -> 0.3 ; range is >=0.3.2 <0.4.0
  {
    awk -v repo="$repo" -v pv="$purs_ver" -v mm="$major_minor" '
      BEGIN { split(mm, a, "."); nxt = a[1] "." (a[2]+1) ".0" }
      /^  test:/ { skip=1; next }
      skip && /^  [a-z]/ { skip=0 }
      skip { next }
      /^      subdir:/ { next }
      /^      githubRepo:/ { print "      githubRepo: " repo; next }
      /^    - tramaj-purs: / { print "    - tramaj-purs: \">=" pv " <" nxt "\""; next }
      { print }
    ' "$ROOT/$dir/spago.yaml"
    cat <<EOF
workspace:
  packageSet:
    registry: $(awk '/registry:/{print $2; exit}' "$ROOT/spago.yaml")
EOF
  } >"$stage/spago.yaml"

  say "building $repo (also writes spago.lock)"
  (cd "$stage" && $SPAGO build >"$WORK/$repo.build.log" 2>&1) \
    || { tail -30 "$WORK/$repo.build.log"; die "$repo does not build standalone (tramaj-halogen needs tramaj-purs on the registry first)"; }

  if gh repo view "$OWNER/$repo" >/dev/null 2>&1; then
    git clone -q "git@github.com:$OWNER/$repo.git" "$clone"
  else
    say "$OWNER/$repo does not exist yet"
    mkdir -p "$clone" && git -C "$clone" init -q -b main
    git -C "$clone" remote add origin "git@github.com:$OWNER/$repo.git"
  fi
  # Replace the working tree with the staged copy (keep .git).
  find "$clone" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  cp -r "$stage"/. "$clone"/
  rm -rf "$clone/output" "$clone/.spago"
  printf 'output/\n.spago/\nnode_modules/\n' >"$clone/.gitignore"
  git -C "$clone" add -A

  if git -C "$clone" diff --cached --quiet; then
    say "$repo already up to date"
  else
    git -C "$clone" diff --cached --stat | tail -15
  fi

  if [ "$PUBLISH" = 0 ]; then
    echo "[dry-run] would: create repo if missing, commit, tag v$ver, push"
    return
  fi
  gh repo view "$OWNER/$repo" >/dev/null 2>&1 \
    || gh repo create "$OWNER/$repo" --public --description "$pkg (generated copy of $OWNER/tramaj/$dir)"
  if ! git -C "$clone" diff --cached --quiet; then
    git -C "$clone" commit -q -m "Sync $pkg $ver from $OWNER/tramaj@$SRC_SHA"
  fi
  git -C "$clone" push -q origin HEAD:main
  if git -C "$clone" ls-remote --exit-code --tags origin "v$ver" >/dev/null 2>&1; then
    say "tag v$ver already on $repo, leaving it alone (bump publish.version for a new release)"
  else
    git -C "$clone" tag "v$ver" && git -C "$clone" push -q origin "v$ver"
  fi
  say "synced. Submit to the registry with (Node >= 22.5):"
  echo "    git clone git@github.com:$OWNER/$repo.git && cd $repo && $SPAGO publish"
}

for entry in "${PKGS[@]}"; do
  IFS=: read -r dir pkg repo <<<"$entry"
  [ -z "$ONLY" ] || [ "$ONLY" = "$pkg" ] || continue
  sync_one "$dir" "$pkg" "$repo"
done
