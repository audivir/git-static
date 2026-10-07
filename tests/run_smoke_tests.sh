#!/usr/bin/env bash
# Usage: ./tests/run_smoke_tests.sh [--static] [--dist DIR] [--offline]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT_DIR/dist"
OFFLINE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --static)
      DIST="$ROOT_DIR/dist-static"
      shift
      ;;
    --dist)
      DIST="$(cd "$2" && pwd)"
      shift 2
      ;;
    --offline)
      OFFLINE=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

GIT="$DIST/bin/git"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"

pass() { echo "ok: $*"; }
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

"$GIT" --version | grep -q '^git version ' || fail "git --version"
pass "$("$GIT" --version)"

cp -R "$DIST" "$TMP/moved"
exec_path="$("$TMP/moved/bin/git" --exec-path)"
[ "$exec_path" = "$(cd "$TMP/moved" && pwd -P)/libexec/git-core" ] \
  || [ "$exec_path" = "$TMP/moved/libexec/git-core" ] \
  || fail "exec path $exec_path is not inside the moved tree"
pass "relocatable exec path"

repo="$TMP/repo"
"$GIT" init -q -b main "$repo"
for i in 1 2 3; do
  echo "line $i" >>"$repo/file.txt"
  "$GIT" -C "$repo" add file.txt
  "$GIT" -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "commit $i"
done
[ "$("$GIT" -C "$repo" rev-list --count HEAD)" = 3 ] || fail "rev-list count"
"$GIT" -C "$repo" log --oneline | grep 'commit 2' >/dev/null || fail "log"
"$GIT" -C "$repo" grep -q 'line 3' || fail "grep"
"$GIT" clone -q --no-local "$repo" "$TMP/clone"
[ "$(cat "$TMP/clone/file.txt")" = "$(cat "$repo/file.txt")" ] || fail "clone content"
"$GIT" -C "$TMP/clone" fsck --no-progress >/dev/null 2>&1 || fail "fsck"
pass "init, commit, log, grep, clone, fsck"

[ -f "$DIST/share/man/man1/git-commit.1" ] || fail "man page git-commit.1 missing"
bash -c '. "$1" && declare -F __git_main >/dev/null' _ "$DIST/share/bash-completion/completions/git" \
  || fail "bash completion does not load"
pass "man pages and bash completion"

if [ "$(uname -s)" = Linux ] && ! LC_ALL=C grep -a -q 'ld-musl' "$GIT"; then
  max="$(LC_ALL=C grep -aoh 'GLIBC_2\.[0-9]*' "$GIT" "$DIST/libexec/git-core/git-remote-http" | sort -uV | tail -n 1)" || true
  if [ -n "$max" ]; then
    [ "$(printf '%s\n' "$max" GLIBC_2.17 | sort -V | tail -n 1)" = GLIBC_2.17 ] \
      || fail "needs $max, newer than GLIBC_2.17"
    pass "glibc floor ($max)"
  fi
fi

if [ "$OFFLINE" = 0 ]; then
  # RHEL/CentOS 7-8
  if [ ! -e /etc/ssl/cert.pem ] && [ -e /etc/pki/tls/cert.pem ]; then
    export SSL_CERT_FILE=/etc/pki/tls/cert.pem
  fi
  if [ -e /etc/ssl/certs ] || [ -e /etc/ssl/cert.pem ]; then
    "$GIT" ls-remote https://github.com/git/git HEAD >/dev/null || fail "https"
    pass "https"
  fi
  certs="$DIST/share/git-core/certs"
  GIT_SSL_CAPATH="$certs" GIT_SSL_CAINFO="$certs/cacert.pem" "$GIT" ls-remote https://github.com/git/git HEAD >/dev/null \
    || fail "https with the bundled certificates"
  pass "https with the bundled certificates"
fi

echo "all smoke tests passed"
