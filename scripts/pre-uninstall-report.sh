#!/usr/bin/env bash
# ============================================================================
# work6 — pre-uninstall-report.sh — raport PRZED ręcznym usunięciem środowiska
#
#   sudo ./pre-uninstall-report.sh [--user NAZWA]
#
# Skrypt NICZEGO nie zmienia i niczego nie usuwa. Pokazuje administratorowi:
#   * czy procesy agenta jeszcze działają (i jakie),
#   * co i ile zajmuje na dysku (work6, work6-config),
#   * jakie komponenty/wersje są zainstalowane (versions.env, manifest.tsv),
#   * które pakiety systemowe stawiano dla work6 (kandydaci do apt purge),
#   * czy agent ma crontab / linger (rzeczy poza katalogiem work6),
#   * komendy usunięcia do wykonania RĘCZNIE (sekcja 15 README).
#
# Celowo samowystarczalny (nie source'uje lib/ współdzielonego z agentem)
# i celowo bez trybu "--execute": kasowanie to trzy komendy z sudo, które
# admin ma wykonać świadomie, patrząc na nie.
# ============================================================================
set -Euo pipefail

if [ -t 1 ]; then C_I=$'\033[1;34m'; C_W=$'\033[1;33m'; C_G=$'\033[1;32m'; C_0=$'\033[0m'
else C_I=""; C_W=""; C_G=""; C_0=""; fi
info() { printf '%s[info]%s %s\n' "$C_I" "$C_0" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[uwaga]%s %s\n' "$C_W" "$C_0" "$*"; }
die()  { printf '[błąd] %s\n' "$*" >&2; exit 1; }
hdr()  { printf '\n%s== %s ==%s\n' "$C_I" "$*" "$C_0"; }

AGENT_USER="ai-agent"
while [ $# -gt 0 ]; do
  case "$1" in
    --user) AGENT_USER="${2:?--user wymaga nazwy}"; shift ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "nieznany argument: $1 (użyj --help)" ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || die "uruchom jako root:  sudo $0"
[[ "$AGENT_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "niepoprawna nazwa użytkownika: $AGENT_USER"
getent passwd "$AGENT_USER" >/dev/null || die "brak użytkownika '${AGENT_USER}' — nie ma czego usuwać?"
AGENT_HOME="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
W6="$AGENT_HOME/work6"
W6C="$AGENT_HOME/work6-config"

info "raport przed usunięciem środowiska work6 (użytkownik: ${AGENT_USER}, HOME: ${AGENT_HOME})"
info "ten skrypt tylko CZYTA — żadna komenda poniżej nie zostanie wykonana automatycznie"

# --- 1. procesy agenta -------------------------------------------------------
hdr "1. Procesy użytkownika ${AGENT_USER}"
# zombie (stan Z) pomijamy — to martwe wpisy, nie działające procesy
live="$(ps -u "$AGENT_USER" -o pid=,stat=,etime=,args= 2>/dev/null | awk '$2 !~ /^Z/')"
if [ -n "$live" ]; then
  warn "działają procesy agenta — pozamykaj je PRZED usuwaniem:"
  printf '%s\n' "$live" | sed 's/^/    /'
else
  ok "brak działających procesów"
fi

# --- 2. dysk -----------------------------------------------------------------
hdr "2. Co zostanie usunięte i ile zajmuje"
for d in "$W6" "$W6C"; do
  if [ -d "$d" ]; then
    printf '    %s\t%s\n' "$(du -sh "$d" 2>/dev/null | cut -f1)" "$d"
  else
    info "brak katalogu: $d"
  fi
done
[ -d "$W6/backups" ] && [ -n "$(ls -A "$W6/backups" 2>/dev/null)" ] \
  && warn "w ${W6}/backups są archiwa konfiguracji — przepadną razem z resztą; skopiuj, jeśli chcesz je zachować"

# --- 3. zainstalowane komponenty ----------------------------------------------
hdr "3. Zainstalowane komponenty (wg zapisów setup-work6.sh)"
if [ -f "$W6/config/versions.env" ]; then
  grep -E '^[A-Z0-9_]+_VERSION=' "$W6/config/versions.env" | sed 's/^/    /' || true
else
  info "brak ${W6}/config/versions.env"
fi
if [ -f "$W6/state/manifest.tsv" ]; then
  info "pełny spis plików komponentów: ${W6}/state/manifest.tsv ($(wc -l <"$W6/state/manifest.tsv") wpisów)"
fi

# --- 4. pakiety systemowe stawiane dla work6 -----------------------------------
hdr "4. Pakiety systemowe instalowane dla work6 (kandydaci do apt purge)"
echo "    Usuń tylko te, których nie używasz gdzie indziej:"
echo "    bazowe (prepare-system.sh etap 1): bubblewrap chromium ripgrep fd-find"
if [ -f "$W6/state/admin-todo.pkgs" ]; then
  echo "    zgłoszone przez setup (etap 2) — plik ${W6}/state/admin-todo.pkgs:"
  sed 's/^/        /' "$W6/state/admin-todo.pkgs"
else
  info "brak zgłoszeń etapu 2 (state/admin-todo.pkgs)"
fi

# --- 5. ślady poza work6 --------------------------------------------------------
hdr "5. Ślady poza katalogami work6"
if crontab -l -u "$AGENT_USER" >/dev/null 2>&1; then
  warn "agent ma crontab — przejrzyj: crontab -l -u ${AGENT_USER}"
else
  ok "brak crontaba agenta"
fi
if command -v loginctl >/dev/null 2>&1 \
   && [ "$(loginctl show-user "$AGENT_USER" -p Linger --value 2>/dev/null)" = "yes" ]; then
  warn "agent ma włączony linger (usługi systemd użytkownika) — sprawdź: systemctl --user -M ${AGENT_USER}@ list-timers"
else
  ok "brak lingera systemd"
fi
for f in "$AGENT_HOME/.bashrc" "$AGENT_HOME/.profile"; do
  [ -f "$f" ] && grep -q "work6" "$f" 2>/dev/null \
    && warn "wpis work6 w $f (np. enable-agent-path.sh) — zniknie razem z HOME, istotny tylko gdy zostawiasz konto"
done

# --- 6. instrukcja ---------------------------------------------------------------
hdr "6. Usunięcie — komendy do wykonania RĘCZNIE (README sekcja 15)"
cat <<EOT
    sudo rm -rf ${W6} ${W6C}
    sudo deluser --remove-home ${AGENT_USER}      # opcjonalnie, razem z HOME
    sudo apt purge <pakiety z sekcji 4>           # opcjonalnie, tylko nieużywane
EOT
warn "tokeny/sesje CLI żyły wyłącznie w work6 — po rm -rf nie ma ich na dysku,"
warn "ale konta w usługach (Anthropic/Google itd.) unieważnij w ich panelach."
