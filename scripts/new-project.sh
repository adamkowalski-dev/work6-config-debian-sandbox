#!/usr/bin/env bash
# ============================================================================
# work6 — new-project.sh — nowy projekt w <work6>/projects
#
#   new-project.sh <nazwa> [--git] [--branch]
#
#   --git      zainicjalizuj repozytorium (git init -b main) z konfiguracją
#              user.name/user.email WYŁĄCZNIE lokalną (per repo)
#   --branch   dodatkowo utwórz i przełącz na branch agent/<data>-<nazwa>
#
# Zasad nie łamiemy: żadnej globalnej konfiguracji gita, żadnych tokenów,
# żadnego automatycznego commita ani push. Merge/push zawsze po Twoim
# review (git diff + testy).
# ============================================================================
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$ROOT_DIR/lib/common.sh"
common_init

require_agent_user
require_owned_dir "$WORK6"

NAME=""
DO_GIT=0
DO_BRANCH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --git) DO_GIT=1 ;;
    --branch) DO_BRANCH=1; DO_GIT=1 ;;
    -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "nieznana flaga: $1" ;;
    *) [ -z "$NAME" ] && NAME="$1" || die "podaj jedną nazwę projektu" ;;
  esac
  shift
done

[ -n "$NAME" ] || die "użycie: new-project.sh <nazwa> [--git] [--branch]"
[[ "$NAME" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
  || die "nazwa: małe litery/cyfry/kropka/myślnik/podkreślenie, start od [a-z0-9]"

DIR="$WORK6/projects/$NAME"
[ ! -e "$DIR" ] || die "projekt już istnieje: $DIR"

ensure_dir "$DIR" 0700
ok "utworzono: $DIR"

if [ "$DO_GIT" -eq 1 ]; then
  need_cmd git "apt install git"
  git -C "$DIR" init -b main >/dev/null
  # tożsamość TYLKO per repo — celowo bez --global
  local_name="AI Agent (work6)"
  local_mail="${AGENT_USER}@localhost"
  read -r -p "git user.name  [${local_name}]: " ans </dev/tty || true
  [ -n "${ans:-}" ] && local_name="$ans"
  read -r -p "git user.email [${local_mail}]: " ans </dev/tty || true
  [ -n "${ans:-}" ] && local_mail="$ans"
  git -C "$DIR" config user.name "$local_name"
  git -C "$DIR" config user.email "$local_mail"
  cat >"$DIR/.gitignore" <<'EOF'
.env
.env.*
node_modules/
__pycache__/
dist/
build/
EOF
  ok "git init (main) + lokalna tożsamość: ${local_name} <${local_mail}>"
  if [ "$DO_BRANCH" -eq 1 ]; then
    BR="agent/$(date +%Y-%m-%d)-${NAME}"
    git -C "$DIR" checkout -q -b "$BR"
    ok "branch roboczy: $BR"
  fi
fi

echo
info "dalej:"
echo "    $WORK6/bin/agent-shell --workspace $NAME"
echo "    $WORK6/bin/run-claude  --workspace $NAME"
info "przed merge/push zawsze: git diff, testy i Twoja ręczna akceptacja."
