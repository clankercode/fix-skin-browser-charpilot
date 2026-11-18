#!/usr/bin/env bash
# Build the skin-browser CharacterPilot fix.
#
#   ./build.sh            check + stage + load into the running game (RemoteBuild)
#   ./build.sh --stage    check + stage only
#   ./build.sh release    check + build a versioned .op in the repo
#
# Env: PLUGINS_DIR (default $OPENPLANET_DIR/Plugins, OPENPLANET_DIR default ~/OpenplanetNext),
#      TM_PLUGIN_SKIP_LSP=1 to skip the check, TM_PLUGIN_REMOTE_HOST to force the RemoteBuild host.
set -euo pipefail
cd "$(dirname "$0")"
slug="fix-skin-browser-charpilot"
usage() { printf 'usage: ./build.sh [--stage|release]\n' >&2; exit 2; }
(( $# <= 1 )) || usage
mode="${1-}"
case "$mode" in
  ''|--stage|release) ;;
  *) usage ;;
esac
op_dir="${OPENPLANET_DIR:-$HOME/OpenplanetNext}"
plugins_dir="${PLUGINS_DIR:-$op_dir/Plugins}"
dest="$plugins_dir/$slug"
myplugins="$(cd .. && pwd)"   # sibling plugin checkouts (tm-control-mcp, mlhook, ...)

lsp() {
  if [[ "${TM_PLUGIN_SKIP_LSP:-0}" == "1" ]]; then return 0; fi
  openplanet-lsp check --plugins-dir "$plugins_dir" --plugins-dir "$myplugins" "$1"
}

lsp .
if [[ "$mode" == release ]]; then
  version=$(sed -nE 's/^version[[:space:]]*=[[:space:]]*"([0-9A-Za-z.+-]+)".*/\1/p' info.toml)
  if [[ -z "$version" ]]; then
    printf 'error: no version in info.toml\n' >&2
    exit 1
  fi
  archive="$slug-$version.op"
  tmp=$(mktemp -d)
  trap 'rm -rf -- "$tmp"' EXIT
  zip -q -X -j "$tmp/$archive" info.toml src/*.as
  mv -fT -- "$tmp/$archive" "$archive"
  printf 'built %s\n' "$archive"
  exit 0
fi

mkdir -p "$dest"
rsync -a --delete src/ "$dest/"
cp info.toml "$dest/info.toml"
lsp "$dest"
echo "staged $slug -> $dest"
[[ "$mode" != --stage ]] || exit 0

log="$op_dir/Openplanet.log"
before=$(stat -c %s "$log")
host="${TM_PLUGIN_REMOTE_HOST:-$(ss -ltnH 2>/dev/null | awk '!f && $4 ~ /:30000$/ { sub(/:[0-9]+$/, "", $4); print $4; f=1 }')}"
host_args=()
if [[ -n "$host" && "$host" != "0.0.0.0" && "$host" != "*" ]]; then host_args=(--host "$host"); fi
tm-remote-build load folder "$slug" -op OpenplanetNext "${host_args[@]}" -d "$op_dir" -l 3 -i 0.5 || true
# Do not trust the transport: require a fresh load line and no fresh compile error.
fresh="$(tail -c +"$((before + 1))" "$log")"
if grep -q "Loaded plugin '$slug'" <<<"$fresh" && ! grep -E "\[$slug\].*(ERR|compilation failed)|Script compilation failed" <<<"$fresh" | grep -q .; then
  echo "loaded $slug (fresh log evidence)"
else
  echo "$fresh" | grep -E "$slug|ERR|compil" | tail -20 >&2
  echo "error: no fresh 'Loaded plugin' evidence for $slug" >&2
  exit 1
fi
