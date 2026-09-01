#!/usr/bin/env bash
# ============================================================================
# work6 - scripts/ssh/deactivate.sh - cofnięcie zmian z scripts/ssh/activate.sh
#
#   sudo scripts/ssh/deactivate.sh
#
# Czyta stan zapisany przez activate.sh (/var/backups/work6-ssh-hardening/
# state.env) i przywraca DOKŁADNIE to, co było wcześniej:
#   * fail2ban - jail.local przywrócony albo usunięty (zależnie, czy
#     istniał przed aktywacją), usługa zatrzymana/przywrócona/odinstalowana
#     zależnie od stanu SPRZED aktywacji,
#   * sshd_config - przywrócony z backupu, jeśli się różni,
#   * openssh-server/usługa ssh - NIE jest automatycznie zatrzymywana ani
#     odinstalowywana bez pytania: zrobienie tego zdalnie przez SSH ZERWIE
#     bieżące połączenie. Pyta osobno i głośno ostrzega.
#
# Po zakończeniu usuwa state.env (backup w /var/backups/work6-ssh-hardening/
# zostaje - nie jest kasowany automatycznie).
# ============================================================================
set -Eeuo pipefail

if [ -t 2 ]; then C_I=$'\033[1;34m'; C_W=$'\033[1;33m'; C_E=$'\033[1;31m'; C_G=$'\033[1;32m'; C_0=$'\033[0m'
else C_I=""; C_W=""; C_E=""; C_G=""; C_0=""; fi
info() { printf '%s[info]%s %s\n' "$C_I" "$C_0" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[uwaga]%s %s\n' "$C_W" "$C_0" "$*"; }
die()  { printf '%s[błąd]%s %s\n' "$C_E" "$C_0" "$*" >&2; exit 1; }

confirm() { # confirm "pytanie" [tak|nie]
  local q="$1" def="${2:-nie}" hint ans
  [ "$def" = "tak" ] && hint="[T/n]" || hint="[t/N]"
  while true; do
    read -r -p "$q $hint " ans </dev/tty || die "brak terminala do potwierdzenia"
    ans="$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')"
    case "$ans" in
      "") [ "$def" = "tak" ] && return 0 || return 1 ;;
      t|tak|y|yes) return 0 ;;
      n|nie|no) return 1 ;;
      *) echo "Odpowiedz: t / n" ;;
    esac
  done
}

[ "$(id -u)" -eq 0 ] || die "uruchom jako root: sudo $0"

STATE_ROOT="/var/backups/work6-ssh-hardening"
STATE_FILE="$STATE_ROOT/state.env"
[ -f "$STATE_FILE" ] \
  || die "brak $STATE_FILE - nie widzę aktywacji do cofnięcia (activate.sh jej nie robił albo już cofnięta)"

# shellcheck source=/dev/null
. "$STATE_FILE"
: "${BACKUP_DIR:?state.env uszkodzony: brak BACKUP_DIR}"
[ -d "$BACKUP_DIR" ] || die "brak katalogu backupu: $BACKUP_DIR"

echo
info "aktywacja z: ${ACTIVATED_AT:-?}"
info "backup:      $BACKUP_DIR"
echo
confirm "Cofnąć zmiany z activate.sh i przywrócić poprzednią konfigurację?" nie \
  || die "przerwano"

# --- fail2ban --------------------------------------------------------------------
echo
if [ "${FAIL2BAN_ENABLED:-no}" = "yes" ]; then
  if [ "${JAIL_LOCAL_PRE_EXISTING:-no}" = "yes" ]; then
    if [ -f "$BACKUP_DIR/jail.local" ]; then
      cp -a "$BACKUP_DIR/jail.local" /etc/fail2ban/jail.local
      ok "przywrócono poprzedni /etc/fail2ban/jail.local"
    else
      warn "brak backupu jail.local mimo że miał istnieć - zostawiam bieżący plik bez zmian"
    fi
  else
    rm -f /etc/fail2ban/jail.local
    ok "usunięto /etc/fail2ban/jail.local (nie istniał przed aktywacją)"
  fi

  if [ "${FAIL2BAN_PRE_INSTALLED:-no}" = "no" ]; then
    if confirm "fail2ban nie był zainstalowany przed aktywacją. Zatrzymać usługę i odinstalować pakiet?" tak; then
      systemctl disable --now fail2ban 2>/dev/null || true
      apt-get remove -y fail2ban
      ok "fail2ban zatrzymany i odinstalowany"
    else
      info "fail2ban zostaje zainstalowany, konfiguracja jail.local już przywrócona/usunięta"
    fi
  else
    if [ "${FAIL2BAN_WAS_ACTIVE:-no}" = "yes" ]; then
      systemctl restart fail2ban
      ok "fail2ban zrestartowany z przywróconą konfiguracją"
    else
      systemctl stop fail2ban 2>/dev/null || true
      ok "fail2ban zatrzymany (nie działał przed aktywacją)"
    fi
    if [ "${FAIL2BAN_WAS_ENABLED:-no}" != "yes" ]; then
      systemctl disable fail2ban 2>/dev/null || true
      ok "autostart fail2ban wyłączony (nie był włączony przed aktywacją)"
    fi
  fi
else
  info "fail2ban nie był aktywowany tym skryptem - pomijam"
fi

# --- sshd_config -------------------------------------------------------------------
echo
if [ "${SSHD_PRE_EXISTING:-no}" = "yes" ] && [ -f "$BACKUP_DIR/sshd_config" ]; then
  if cmp -s "$BACKUP_DIR/sshd_config" /etc/ssh/sshd_config; then
    info "sshd_config: bez zmian względem backupu"
  else
    cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.before-deactivate-$(date +%Y%m%d-%H%M%S)"
    cp -a "$BACKUP_DIR/sshd_config" /etc/ssh/sshd_config
    ok "przywrócono /etc/ssh/sshd_config z backupu (poprzednia wersja zachowana obok)"
  fi
fi

# --- openssh-server / usługa ssh ----------------------------------------------------
echo
if [ "${OPENSSH_PRE_INSTALLED:-no}" = "no" ]; then
  warn "openssh-server NIE był zainstalowany przed aktywacją."
  warn "UWAGA: jeśli jesteś połączony przez SSH, zatrzymanie/odinstalowanie"
  warn "openssh-server ZERWIE tę sesję i może odciąć zdalny dostęp do maszyny."
  if confirm "Mimo to zatrzymać ssh i odinstalować openssh-server?" nie; then
    systemctl disable --now ssh 2>/dev/null || true
    apt-get remove -y openssh-server
    ok "ssh zatrzymany, openssh-server odinstalowany"
  else
    info "zostawiam openssh-server i usługę ssh włączone - cofnij to ręcznie, jeśli trzeba"
  fi
else
  if [ "${SSH_WAS_ACTIVE:-yes}" = "no" ]; then
    warn "usługa ssh nie działała przed aktywacją."
    warn "UWAGA: jeśli jesteś połączony przez SSH, zatrzymanie jej teraz ZERWIE tę sesję."
    if confirm "Zatrzymać usługę ssh teraz?" nie; then
      systemctl stop ssh 2>/dev/null || true
      ok "usługa ssh zatrzymana"
    fi
  else
    info "usługa ssh działała już przed aktywacją - zostawiam bez zmian"
  fi
  if [ "${SSH_WAS_ENABLED:-yes}" = "no" ]; then
    if confirm "ssh nie był włączony na starcie przed aktywacją. Wyłączyć autostart?" nie; then
      systemctl disable ssh 2>/dev/null || true
      ok "autostart ssh wyłączony"
    fi
  fi
fi

rm -f -- "$STATE_FILE"
echo
ok "deaktywacja zakończona. Backup pozostaje w: $BACKUP_DIR (nieusuwany automatycznie)."
