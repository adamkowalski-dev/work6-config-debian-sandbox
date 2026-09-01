#!/usr/bin/env bash
# ============================================================================
# work6 — prepare-system.sh — JEDYNY skrypt uruchamiany jako administrator
#
#   sudo ./prepare-system.sh            # etap 1: pakiety, użytkownik, testy
#   sudo ./prepare-system.sh --stage2   # etap 2: zależności zgłoszone przez
#                                       #         setup-work6.sh (Playwright,
#                                       #         Flutter desktop itd.)
#
# Zasady:
#   * każdy krok zmieniający system pyta o potwierdzenie,
#   * instaluje wyłącznie pakiety APT z jawnej listy,
#   * NIE dodaje użytkownika agenta do żadnych grup uprzywilejowanych,
#   * NIE instaluje Node/npm/CLI/Fluttera/VS Code globalnie,
#   * NIE zmienia globalnej konfiguracji gita,
#   * niczego nie wykonuje z plików zapisywalnych przez konto agenta —
#     z etapu 2 czyta wyłącznie NAZWY pakietów przez ścisły whitelist.
#
# Skrypt jest celowo samowystarczalny (nie source'uje lib/ współdzielonego
# z kontem agenta).
# ============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
trap 'echo "[błąd] ${BASH_SOURCE[0]}:${LINENO}: \"${BASH_COMMAND}\" (kod $?)" >&2' ERR

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
    read -r -p "$q $hint " ans </dev/tty || die "brak terminala"
    ans="$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')"
    case "$ans" in
      "") [ "$def" = "tak" ] && return 0 || return 1 ;;
      t|tak|y|yes) return 0 ;;
      n|nie|no) return 1 ;;
      *) echo "Odpowiedz: t / n" ;;
    esac
  done
}

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

# --- argumenty ---------------------------------------------------------------
STAGE="1"
AGENT_USER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --stage2) STAGE="2" ;;
    --user) AGENT_USER="${2:?--user wymaga nazwy}"; shift ;;
    -h|--help) usage ;;
    *) die "nieznany argument: $1 (użyj --help)" ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || die "uruchom jako root:  sudo $0 $*"

# AGENT_USER: flaga > config/install.env (tylko parsowanie, bez source!) > domyślna
if [ -z "$AGENT_USER" ] && [ -f "$SCRIPT_DIR/config/install.env" ]; then
  AGENT_USER="$(grep -E '^AGENT_USER="[a-z_][a-z0-9_-]*"$' \
    "$SCRIPT_DIR/config/install.env" | tail -n1 | cut -d'"' -f2 || true)"
fi
AGENT_USER="${AGENT_USER:-ai-agent}"
[[ "$AGENT_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "niepoprawna nazwa użytkownika: $AGENT_USER"

# Grupy, do których konto agenta NIE może należeć.
PRIV_GROUPS=(root sudo adm admin wheel staff docker disk libvirt libvirt-qemu
  lxd kvm plugdev shadow sambashare netdev dialout)

# ============================================================================
# ETAP 1
# ============================================================================
stage1() {
  echo
  info "work6 prepare-system — etap 1 (użytkownik agenta: ${AGENT_USER})"
  echo

  # --- 1. rozpoznanie systemu ---
  local os_id="?" os_ver="?" arch
  if [ -r /etc/os-release ]; then
    os_id="$(. /etc/os-release && echo "${ID:-?}")"
    os_ver="$(. /etc/os-release && echo "${VERSION_ID:-?}")"
  fi
  arch="$(uname -m)"
  info "system: ${os_id} ${os_ver}, architektura: ${arch}"
  if [ "$os_id" != "debian" ]; then
    warn "to nie Debian — skrypt projektowano pod Debian stable (13/trixie)."
    confirm "Kontynuować mimo to?" nie || exit 1
  elif [ "${os_ver%%.*}" -lt 12 ] 2>/dev/null; then
    warn "Debian ${os_ver} jest starszy niż zakładany (12+); merged-usr wymagane."
    confirm "Kontynuować mimo to?" nie || exit 1
  fi
  case "$arch" in
    x86_64|aarch64) : ;;
    *) warn "architektura ${arch} nietestowana (Flutter wymaga x86_64)" ;;
  esac

  # --- 2. pakiety bazowe ---
  local base_pkgs=(bubblewrap ca-certificates curl wget git tar xz-utils
    gnupg jq unzip zip rsync file procps)
  local py_pkgs=(python3 python3-venv python3-pip)
  local missing=() p
  for p in "${base_pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    info "brakujące pakiety bazowe: ${missing[*]}"
    if confirm "Zainstalować je przez apt-get?" tak; then
      apt-get update
      apt-get install -y --no-install-recommends "${missing[@]}"
      ok "pakiety bazowe zainstalowane"
    else
      warn "pomijam — setup-work6.sh zgłosi braki"
    fi
  else
    ok "pakiety bazowe już są"
  fi

  missing=()
  for p in "${py_pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    if confirm "Zainstalować Pythona (${missing[*]})? Potrzebny, jeśli w kreatorze wybierzesz Python+venv." tak; then
      apt-get install -y --no-install-recommends "${missing[@]}"
      ok "Python zainstalowany"
    fi
  else
    ok "Python (python3/venv/pip) już jest"
  fi

  if ! dpkg -s chromium >/dev/null 2>&1; then
    if confirm "Zainstalować systemowy Chromium (do ręcznych logowań OAuth w profilu agenta)?" tak; then
      apt-get install -y --no-install-recommends chromium
      ok "Chromium zainstalowany"
    else
      info "pominięto — open-agent-browser użyje Chromium Playwrighta, jeśli będzie"
    fi
  else
    ok "Chromium już jest"
  fi

  # Narzędzia CLI, po które agenty AI sięgają przy pracy z kodem. Opcjonalne:
  # bez nich wszystko działa (grep/find), z nimi agent pracuje szybciej.
  # W sandboxie /usr jest RO, więc zainstalować je może wyłącznie admin tutaj.
  local agent_tools=(ripgrep fd-find)
  missing=()
  for p in "${agent_tools[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    if confirm "Zainstalować narzędzia CLI dla agenta (${missing[*]})? (rg / fdfind — szybkie szukanie w kodzie)" tak; then
      apt-get install -y --no-install-recommends "${missing[@]}"
      ok "narzędzia CLI agenta zainstalowane (uwaga: binarka fd-find to 'fdfind')"
    else
      info "pominięto — agent poradzi sobie przez grep/find"
    fi
  else
    ok "narzędzia CLI agenta (ripgrep, fd-find) już są"
  fi

  # --- 3. użytkownik agenta ---
  echo
  if getent passwd "$AGENT_USER" >/dev/null; then
    local uid home groups
    uid="$(id -u "$AGENT_USER")"
    home="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
    groups="$(id -nG "$AGENT_USER")"
    info "użytkownik '${AGENT_USER}' istnieje: UID=${uid}, HOME=${home}"
    info "grupy: ${groups}"
    local g bad=()
    for g in $groups; do
      for p in "${PRIV_GROUPS[@]}"; do [ "$g" = "$p" ] && bad+=("$g"); done
    done
    if [ "${#bad[@]}" -gt 0 ]; then
      warn "KRYTYCZNE: '${AGENT_USER}' należy do grup uprzywilejowanych: ${bad[*]}"
      warn "usuń ręcznie po weryfikacji, np.:"
      for g in "${bad[@]}"; do echo "    gpasswd -d '$AGENT_USER' '$g'"; done
    else
      ok "brak członkostwa w grupach uprzywilejowanych"
    fi
  else
    warn "użytkownik '${AGENT_USER}' nie istnieje."
    if confirm "Utworzyć go teraz (adduser, bez hasła, bez dodatkowych grup)?" nie; then
      adduser --disabled-password --gecos "AI agent (work6)" "$AGENT_USER"
      ok "utworzono '${AGENT_USER}' (UID=$(id -u "$AGENT_USER"))"
      info "hasło (potrzebne tylko do logowania w sesję graficzną) ustaw sam:"
      echo "    passwd '$AGENT_USER'"
    else
      die "bez użytkownika agenta nie ma jak kontynuować — przerwano na Twoje żądanie"
    fi
  fi
  local agent_home
  agent_home="$(getent passwd "$AGENT_USER" | cut -d: -f6)"

  # --- 4. uprawnienia katalogów domowych ---
  echo
  local d perms
  perms="$(stat -c %a "$agent_home")"
  if [ "$perms" != "700" ]; then
    if confirm "HOME agenta ma tryb ${perms}; ustawić 0700?" tak; then
      chmod 0700 "$agent_home"; ok "chmod 0700 $agent_home"
    fi
  else
    ok "HOME agenta: 0700"
  fi
  for d in /home/*; do
    [ -d "$d" ] || continue
    [ "$d" = "$agent_home" ] && continue
    perms="$(stat -c %a "$d")"
    if [[ "$perms" =~ [1-7]$ ]]; then
      warn "katalog $d ma tryb ${perms} — '${AGENT_USER}' może do niego zaglądać"
      if confirm "Odebrać dostęp 'other' (chmod o-rwx $d)?" tak; then
        chmod o-rwx "$d"; ok "chmod o-rwx $d"
      fi
    else
      ok "$d: bez dostępu dla innych (${perms})"
    fi
  done

  # --- 5. test bubblewrap + user namespaces (Debian 13/AppArmor) ---
  echo
  if command -v bwrap >/dev/null 2>&1; then
    local bwrap_test=(bwrap --unshare-user --unshare-pid --die-with-parent
      --proc /proc --dev /dev --tmpfs /tmp
      --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib)
    [ -e /lib64 ] && bwrap_test+=( --symlink usr/lib64 /lib64 )
    if runuser -u "$AGENT_USER" -- "${bwrap_test[@]}" /usr/bin/true 2>/dev/null; then
      ok "bubblewrap: testowy sandbox działa jako '${AGENT_USER}'"
    else
      warn "testowy sandbox NIE działa jako '${AGENT_USER}'."
      local rest
      rest="$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo '?')"
      warn "kernel.apparmor_restrict_unprivileged_userns=${rest}"
      warn "Debian 13 ogranicza userns przez AppArmor; pakiet bubblewrap z apt"
      warn "zawiera właściwy profil. Spróbuj:  apt-get install --reinstall bubblewrap"
      warn "NIE wyłączaj restrykcji globalnie (sysctl) — to osłabia cały system."
    fi
  else
    warn "bwrap niezainstalowany — sandbox nie będzie działał"
  fi

  # --- 6. miejsce na dysku ---
  echo
  local avail_kb
  avail_kb="$(df -Pk "$agent_home" | awk 'NR==2{print $4}')"
  info "wolne miejsce na systemie plików z ${agent_home}: $((avail_kb / 1024 / 1024)) GiB"
  [ "$avail_kb" -lt $((8 * 1024 * 1024)) ] \
    && warn "pełny zestaw (z Flutterem) potrzebuje ~6-8 GB — może być ciasno"

  # --- 7. udostępnienie plików instalacyjnych agentowi ---
  echo
  local dest="${agent_home}/work6-config"
  if [ "$SCRIPT_DIR" = "$dest" ]; then
    ok "pliki instalacyjne już są w ${dest}"
  elif confirm "Skopiować katalog instalacyjny do ${dest} (właściciel: ${AGENT_USER})?" tak; then
    rsync -a --delete --chown="${AGENT_USER}:${AGENT_USER}" \
      "$SCRIPT_DIR/" "$dest/"
    chmod 0700 "$dest"
    ok "skopiowano do ${dest}"
  else
    info "pamiętaj: konto '${AGENT_USER}' musi mieć dostęp do tych plików"
  fi

  echo
  ok "etap 1 zakończony. Dalej jako użytkownik agenta:"
  echo "    sudo -iu ${AGENT_USER}"
  echo "    cd ~/work6-config && ./setup-work6.sh"
  echo
  info "jeśli setup zgłosi zależności systemowe (Playwright/Flutter):"
  echo "    sudo ${dest}/prepare-system.sh --stage2"
}

# ============================================================================
# ETAP 2 — pakiety zgłoszone przez setup-work6.sh
# ============================================================================
stage2() {
  local agent_home todo
  getent passwd "$AGENT_USER" >/dev/null || die "brak użytkownika ${AGENT_USER}"
  agent_home="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
  todo="${agent_home}/work6/state/admin-todo.pkgs"
  [ -f "$todo" ] || die "brak pliku ${todo} — najpierw uruchom setup-work6.sh jako ${AGENT_USER}"

  echo
  info "plik zgłoszeń od setup-work6.sh (zawartość surowa):"
  echo "----------------------------------------------------------------"
  cat "$todo"
  echo "----------------------------------------------------------------"

  # BEZPIECZEŃSTWO: plik jest zapisywalny przez konto agenta, więc jest
  # danymi NIEZAUFANYMI. Bierzemy z niego wyłącznie tokeny wyglądające
  # jak nazwy pakietów Debiana; wszystko inne głośno odrzucamy.
  local -a pkgs=()
  local line tok
  while IFS= read -r line; do
    line="${line%%#*}"
    for tok in $line; do
      if [[ "$tok" =~ ^[a-z0-9][a-z0-9+.-]*$ ]]; then
        pkgs+=("$tok")
      else
        warn "odrzucono token niepasujący do nazwy pakietu: '$tok'"
      fi
    done
  done <"$todo"

  # deduplikacja + odfiltrowanie już zainstalowanych
  local -a uniq=() need=()
  local p seen
  for p in "${pkgs[@]}"; do
    seen=0
    for tok in "${uniq[@]:-}"; do [ "$tok" = "$p" ] && seen=1; done
    [ "$seen" -eq 0 ] && uniq+=("$p")
  done
  for p in "${uniq[@]:-}"; do
    [ -n "$p" ] || continue
    dpkg -s "$p" >/dev/null 2>&1 || need+=("$p")
  done

  if [ "${#need[@]}" -eq 0 ]; then
    ok "wszystkie zgłoszone pakiety są już zainstalowane"
    return 0
  fi
  echo
  info "do instalacji (${#need[@]}): ${need[*]}"
  confirm "Zainstalować powyższe pakiety przez apt-get?" nie \
    || die "przerwano na Twoje żądanie"
  apt-get update
  apt-get install -y --no-install-recommends "${need[@]}"
  ok "zainstalowano. Wróć na konto agenta i uruchom: scripts/doctor.sh"
}

case "$STAGE" in
  1) stage1 ;;
  2) stage2 ;;
esac
