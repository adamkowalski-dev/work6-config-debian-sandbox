#!/usr/bin/env bash
# ============================================================================
# work6 - scripts/ssh/activate.sh - włącza SSH (openssh-server) na hoście
# i opcjonalnie ochronę fail2ban przed brute-force logowaniem.
#
#   sudo scripts/ssh/activate.sh [--force]
#
# Uruchamiany BEZPOŚREDNIO na docelowej maszynie (np. Dellu), jako root -
# zanim SSH działa, nie da się tego zrobić zdalnie. Przed jakąkolwiek
# zmianą robi backup bieżącej konfiguracji (/etc/ssh/sshd_config,
# /etc/fail2ban/jail.local jeśli istnieje) do
# /var/backups/work6-ssh-hardening/backup-<znacznik-czasu>/ i zapisuje
# stan wyjściowy do state.env - potrzebne przez deactivate.sh, żeby cofnąć
# TYLKO to, co ten skrypt faktycznie zmienił (nie więcej, nie mniej).
#
# --force: aktywuj mimo istniejącego state.env z niedokończonej/wcześniejszej
#          aktywacji (normalnie każ najpierw uruchomić deactivate.sh).
#
# Skrypt jest celowo samowystarczalny (nie source'uje lib/ agenta -
# działa jako root, poza kontem ai-agent, na wzór prepare-system.sh).
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

[ "$(id -u)" -eq 0 ] || die "uruchom jako root: sudo $0 ${1:-}"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

STATE_ROOT="/var/backups/work6-ssh-hardening"
STATE_FILE="$STATE_ROOT/state.env"
mkdir -p -- "$STATE_ROOT"
chmod 0700 "$STATE_ROOT"

RESUMED=0
if [ -f "$STATE_FILE" ]; then
  if grep -q '^FAIL2BAN_ENABLED=' "$STATE_FILE"; then
    # stan PEŁNY - poprzednia aktywacja dobiegła końca.
    if [ "$FORCE" -ne 1 ]; then
      warn "wygląda na to, że ten skrypt aktywował już SSH wcześniej:"
      sed 's/^/    /' "$STATE_FILE"
      die "uruchom najpierw scripts/ssh/deactivate.sh (albo --force, jeśli wiesz, co robisz)"
    fi
  else
    # stan CZĘŚCIOWY - poprzednie uruchomienie przerwane w trakcie.
    # Traktujemy go jako wiarygodne źródło stanu "przed aktywacją"
    # (system mógł już zostać częściowo zmieniony) i wznawiamy.
    info "wykryto częściowy stan po przerwanej wcześniejszej aktywacji ($STATE_FILE) - wznawiam"
    RESUMED=1
  fi
fi

# --- stan SPRZED zmian + backup (żeby deactivate.sh wiedział, co cofnąć) ------
# Przy wznowieniu po przerwaniu stan "przed" i katalog backupu pochodzą
# z częściowego state.env - system mógł już zostać zmieniony przez
# przerwane uruchomienie, więc odczyt z żywego systemu byłby kłamstwem,
# a nowy backup sshd_config nadpisałby kopię prawdziwego oryginału.
if [ "$RESUMED" -eq 1 ]; then
  # shellcheck source=/dev/null
  . "$STATE_FILE"
  backup_dir="${BACKUP_DIR:?częściowy state.env uszkodzony: brak BACKUP_DIR}"
  [ -d "$backup_dir" ] || die "katalog backupu z przerwanej aktywacji nie istnieje: $backup_dir"
  sshd_pre_existing="${SSHD_PRE_EXISTING:?częściowy state.env uszkodzony: brak SSHD_PRE_EXISTING}"
  openssh_pre_installed="${OPENSSH_PRE_INSTALLED:?częściowy state.env uszkodzony: brak OPENSSH_PRE_INSTALLED}"
  ssh_was_active="${SSH_WAS_ACTIVE:?częściowy state.env uszkodzony: brak SSH_WAS_ACTIVE}"
  ssh_was_enabled="${SSH_WAS_ENABLED:?częściowy state.env uszkodzony: brak SSH_WAS_ENABLED}"
  echo
  info "work6 ssh/activate - wznowienie; backup sprzed pierwszej próby: $backup_dir"
  echo
else
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_dir="$STATE_ROOT/backup-$ts"
  mkdir -p -- "$backup_dir"
  chmod 0700 "$backup_dir"

  echo
  info "work6 ssh/activate - backup bieżącej konfiguracji -> $backup_dir"
  echo

  sshd_pre_existing=no
  if [ -f /etc/ssh/sshd_config ]; then
    sshd_pre_existing=yes
    cp -a /etc/ssh/sshd_config "$backup_dir/sshd_config"
    ok "zabezpieczono: /etc/ssh/sshd_config"
  fi
  openssh_pre_installed=no
  dpkg -s openssh-server >/dev/null 2>&1 && openssh_pre_installed=yes
  ssh_was_active=no
  systemctl is-active --quiet ssh 2>/dev/null && ssh_was_active=yes
  ssh_was_enabled=no
  systemctl is-enabled --quiet ssh 2>/dev/null && ssh_was_enabled=yes
fi

# --- zapis CZĘŚCIOWEGO stanu (odporność na przerwanie w trakcie aktywacji) ----
# Od tej linii mogą zacząć się realne zmiany w systemie (instalacja
# openssh-server itd.) - stan "przed" musi być na dysku, zanim to nastąpi,
# atomowo (plik .partial + mv), żeby drugie uruchomienie po przerwaniu nie
# odczytało już zmienionego systemu jako stan "przed".
cat >"$STATE_FILE.partial" <<EOF
BACKUP_DIR="$backup_dir"
SSHD_PRE_EXISTING="$sshd_pre_existing"
OPENSSH_PRE_INSTALLED="$openssh_pre_installed"
SSH_WAS_ACTIVE="$ssh_was_active"
SSH_WAS_ENABLED="$ssh_was_enabled"
EOF
chmod 0600 "$STATE_FILE.partial"
mv -f -- "$STATE_FILE.partial" "$STATE_FILE"

# --- instalacja openssh-server -------------------------------------------------
if [ "$openssh_pre_installed" = "no" ]; then
  confirm "openssh-server nie jest zainstalowany. Zainstalować?" tak \
    || die "przerwano - bez openssh-server nie ma czego aktywować"
  apt-get update
  apt-get install -y openssh-server
  ok "openssh-server zainstalowany"
else
  ok "openssh-server już zainstalowany"
fi

systemctl enable --now ssh
ok "usługa ssh: aktywna i włączona na starcie"
if ss -tlnp 2>/dev/null | grep -q ':22 '; then
  ok "port 22 nasłuchuje"
else
  warn "nie widzę nasłuchu na :22 - sprawdź: systemctl status ssh"
fi

# --- fail2ban (opcjonalnie) -----------------------------------------------------
fail2ban_enabled=no
fail2ban_pre_installed=no
fail2ban_was_active=no
fail2ban_was_enabled=no
jail_local_pre_existing=no

echo
if confirm "Aktywować blokadę logowań po nieudanych próbach SSH (fail2ban)?" tak; then
  fail2ban_enabled=yes
  # Przy wznowieniu pre-stan fail2ban bierzemy z state.env, jeśli przerwane
  # uruchomienie zdążyło go tam dopisać - żywy system mógł już być zmieniony.
  if [ "$RESUMED" -eq 1 ] && [ -n "${FAIL2BAN_PRE_INSTALLED:-}" ]; then
    # zmienne z source'a state.env na początku skryptu (zapis częściowego
    # pre-stanu SSH wyżej nadpisał plik, ale wartości zostały w pamięci)
    fail2ban_pre_installed="$FAIL2BAN_PRE_INSTALLED"
    fail2ban_was_active="$FAIL2BAN_WAS_ACTIVE"
    fail2ban_was_enabled="$FAIL2BAN_WAS_ENABLED"
    jail_local_pre_existing="$JAIL_LOCAL_PRE_EXISTING"
  else
    dpkg -s fail2ban >/dev/null 2>&1 && fail2ban_pre_installed=yes
    systemctl is-active --quiet fail2ban 2>/dev/null && fail2ban_was_active=yes
    systemctl is-enabled --quiet fail2ban 2>/dev/null && fail2ban_was_enabled=yes
    [ -f /etc/fail2ban/jail.local ] && jail_local_pre_existing=yes
  fi
  # pre-stan fail2ban na dysk ZANIM cokolwiek przy nim zmienimy
  cat >>"$STATE_FILE" <<EOF
FAIL2BAN_PRE_INSTALLED="$fail2ban_pre_installed"
FAIL2BAN_WAS_ACTIVE="$fail2ban_was_active"
FAIL2BAN_WAS_ENABLED="$fail2ban_was_enabled"
JAIL_LOCAL_PRE_EXISTING="$jail_local_pre_existing"
EOF

  if [ "$jail_local_pre_existing" = "yes" ] && [ ! -f "$backup_dir/jail.local" ]; then
    cp -a /etc/fail2ban/jail.local "$backup_dir/jail.local"
    ok "zabezpieczono: /etc/fail2ban/jail.local"
  fi

  if [ "$fail2ban_pre_installed" = "no" ]; then
    apt-get update
    apt-get install -y fail2ban
    ok "fail2ban zainstalowany"
  else
    ok "fail2ban już zainstalowany"
  fi

  info "próg: 5 błędnych haseł / 10 min -> blokada 30 min"
  info "eskalacja: kolejne blokady x2 aż do 24h; whitelist: sieć 192.168.1.0/24"
  if confirm "Zapisać tę konfigurację do /etc/fail2ban/jail.local (nadpisze istniejący plik)?" tak; then
    cat >/etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 192.168.1.0/24

[sshd]
enabled = true
port = ssh
maxretry = 5
findtime = 10m
bantime = 30m
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 24h
EOF
    chmod 0644 /etc/fail2ban/jail.local
    systemctl enable --now fail2ban
    systemctl restart fail2ban
    ok "fail2ban: aktywny, jail [sshd] włączony"
    fail2ban-client status sshd 2>/dev/null | sed 's/^/    /' || true
  else
    warn "pominięto zapis jail.local - fail2ban zainstalowany, ale BEZ ochrony sshd"
    fail2ban_enabled=no
  fi
else
  info "pominięto fail2ban - SSH aktywny bez ochrony przed brute-force"
fi

# --- zapis stanu ----------------------------------------------------------------
cat >"$STATE_FILE" <<EOF
ACTIVATED_AT="$(date -Iseconds)"
BACKUP_DIR="$backup_dir"
SSHD_PRE_EXISTING="$sshd_pre_existing"
OPENSSH_PRE_INSTALLED="$openssh_pre_installed"
SSH_WAS_ACTIVE="$ssh_was_active"
SSH_WAS_ENABLED="$ssh_was_enabled"
FAIL2BAN_ENABLED="$fail2ban_enabled"
FAIL2BAN_PRE_INSTALLED="$fail2ban_pre_installed"
FAIL2BAN_WAS_ACTIVE="$fail2ban_was_active"
FAIL2BAN_WAS_ENABLED="$fail2ban_was_enabled"
JAIL_LOCAL_PRE_EXISTING="$jail_local_pre_existing"
EOF
chmod 0600 "$STATE_FILE"

echo
ok "aktywacja zakończona. Stan zapisany: $STATE_FILE"
info "cofnięcie (powrót do poprzedniej konfiguracji): sudo scripts/ssh/deactivate.sh"
