#!/usr/bin/env bash
# ============================================================================
# work6 — enable-agent-path.sh — <work6>/bin na PATH konta agenta (opt-in)
#
#   ~/work6/scripts/enable-agent-path.sh            # dopisz blok do ~/.bashrc
#   ~/work6/scripts/enable-agent-path.sh --remove   # usuń blok
#
# Jedyny skrypt work6, który dotyka pliku startowego powłoki — wyłącznie
# na wyraźne wywołanie i za potwierdzeniem. Dodaje TYLKO <work6>/bin
# (launchery są samowystarczalne); pełne środowisko do ręcznej pracy to
# nadal `source scripts/activate.sh`.
#
# Debian: login shell (`sudo -iu ai-agent`, konsola) czyta ~/.profile,
# który w domyślnym skel source'uje ~/.bashrc — blok działa w obu drogach.
# ============================================================================
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$ROOT_DIR/lib/common.sh"
common_init

require_agent_user
require_owned_dir "$WORK6/bin"

RC="$HOME/.bashrc"
MARK_BEGIN="# >>> work6-path >>> (zarządzane przez enable-agent-path.sh)"
MARK_END="# <<< work6-path <<<"

remove_block() {
  [ -f "$RC" ] || return 0
  grep -qF "$MARK_BEGIN" "$RC" || return 0
  local tmp
  tmp="$(mktemp "${RC}.XXXXXX")"
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip   { print }
  ' "$RC" >"$tmp"
  chmod --reference="$RC" -- "$tmp" 2>/dev/null || chmod 0600 -- "$tmp"
  mv -- "$tmp" "$RC"
}

case "${1:-}" in
  --remove)
    if grep -qsF "$MARK_BEGIN" "$RC"; then
      remove_block
      ok "usunięto blok work6-path z $RC (zadziała w nowych powłokach)"
    else
      info "w $RC nie ma bloku work6-path — nic do zrobienia"
    fi
    exit 0
    ;;
  "") : ;;
  *) die "nieznany argument: $1 (dozwolone: --remove)" ;;
esac

if grep -qsF "$MARK_BEGIN" "$RC"; then
  info "blok work6-path już jest w $RC — odświeżam (idempotentnie)"
else
  info "dopiszę do $RC blok dodający $WORK6/bin do PATH"
  info "po tym w nowej powłoce wystarczy: run-claude, agent-shell, ..."
  confirm "Dopisać?" tak || die "przerwano — nic nie zmieniono"
fi

remove_block
touch -- "$RC"
cat >>"$RC" <<EOF
$MARK_BEGIN
if [ -d "\$HOME/work6/bin" ]; then
  case ":\$PATH:" in
    *":\$HOME/work6/bin:"*) : ;;
    *) PATH="\$HOME/work6/bin:\$PATH" ;;
  esac
fi
$MARK_END
EOF
ok "gotowe: $RC — otwórz nową powłokę (albo: source ~/.bashrc)"
info "cofnięcie: $WORK6/scripts/enable-agent-path.sh --remove"
