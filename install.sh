#!/usr/bin/env bash
# ============================================================================
# work6 — install.sh — jednokomendowy instalator zdalny
#
# Użycie (jako root lub z sudo):
#
#   curl -fsSL https://raw.githubusercontent.com/adamkowalski-dev/work6-config-debian-sandbox/main/install.sh | sudo bash
#
# Albo z pobraniem i przeglądem:
#
#   curl -fsSL -o install.sh https://raw.githubusercontent.com/adamkowalski-dev/work6-config-debian-sandbox/main/install.sh
#   less install.sh          # przejrzyj przed uruchomieniem
#   sudo bash install.sh
#
# Co robi:
#   1. sprawdza wymagania (root, Debian/Ubuntu, curl/tar/git),
#   2. klonuje repozytorium do tymczasowego katalogu,
#   3. uruchamia prepare-system.sh (etap 1 — pakiety, użytkownik),
#   4. kopiuje pliki do ~ai-agent/work6-config,
#   5. wypisuje instrukcje dalszych kroków (setup-work6.sh jako agent).
#
# Flagi:
#   --user NAZWA     nazwa użytkownika agenta (domyślnie: ai-agent)
#   --branch BRANCH  branch do pobrania (domyślnie: main)
#   --no-prepare     pomiń prepare-system.sh (sam go uruchomisz)
#   --yes            tryb nieinteraktywny (akceptuj domyślne odpowiedzi)
#   -h|--help        pokaż pomoc
#
# Zasady bezpieczeństwa:
#   * pobiera WYŁĄCZNIE z GitHub przez HTTPS,
#   * nie instaluje niczego spoza jawnej listy APT,
#   * nie dodaje użytkownika do grup uprzywilejowanych,
#   * sprząta po sobie katalog tymczasowy,
#   * skrypt jest samowystarczalny (nie source'uje lib/).
# ============================================================================
set -Eeuo pipefail

# --- stałe -------------------------------------------------------------------
REPO_URL="https://github.com/adamkowalski-dev/work6-config-debian-sandbox.git"
REPO_NAME="work6-config-debian-sandbox"

# --- kolory ------------------------------------------------------------------
if [ -t 2 ]; then
  C_I=$'\033[1;34m'; C_W=$'\033[1;33m'; C_E=$'\033[1;31m'
  C_G=$'\033[1;32m'; C_0=$'\033[0m'
else
  C_I=""; C_W=""; C_E=""; C_G=""; C_0=""
fi
info() { printf '%s[info]%s %s\n'  "$C_I" "$C_0" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n'  "$C_G" "$C_0" "$*"; }
warn() { printf '%s[uwaga]%s %s\n' "$C_W" "$C_0" "$*"; }
die()  { printf '%s[błąd]%s %s\n'  "$C_E" "$C_0" "$*" >&2; exit 1; }

trap 'echo "${C_E}[błąd]${C_0} ${BASH_SOURCE[0]}:${LINENO}: \"${BASH_COMMAND}\" (kod $?)" >&2' ERR

# --- sprzątanie --------------------------------------------------------------
TMPDIR_INSTALL=""
cleanup() {
  if [ -n "$TMPDIR_INSTALL" ] && [ -d "$TMPDIR_INSTALL" ]; then
    rm -rf -- "$TMPDIR_INSTALL"
    info "usunięto katalog tymczasowy: $TMPDIR_INSTALL"
  fi
}
trap cleanup EXIT

# --- pomoc -------------------------------------------------------------------
usage() {
  sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

# --- argumenty ---------------------------------------------------------------
AGENT_USER="ai-agent"
BRANCH="main"
RUN_PREPARE="1"
INTERACTIVE="1"

while [ $# -gt 0 ]; do
  case "$1" in
    --user)    AGENT_USER="${2:?--user wymaga nazwy}"; shift ;;
    --branch)  BRANCH="${2:?--branch wymaga nazwy}"; shift ;;
    --no-prepare) RUN_PREPARE="0" ;;
    --yes)     INTERACTIVE="0" ;;
    -h|--help) usage ;;
    *) die "nieznany argument: $1 (użyj --help)" ;;
  esac
  shift
done

# --- walidacje --------------------------------------------------------------
[[ "$AGENT_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] \
  || die "niepoprawna nazwa użytkownika: $AGENT_USER"

[[ "$BRANCH" =~ ^[a-zA-Z0-9._/-]+$ ]] \
  || die "niepoprawna nazwa brancha: $BRANCH"

# --- wymagania systemowe -----------------------------------------------------
info "=== work6 — instalator zdalny ==="
echo

# root?
[ "$(id -u)" -eq 0 ] \
  || die "uruchom jako root:  curl ... | sudo bash"

# system operacyjny
os_id="?"
if [ -r /etc/os-release ]; then
  os_id="$(. /etc/os-release && echo "${ID:-?}")"
fi
case "$os_id" in
  debian|ubuntu|linuxmint|pop|zorin|kali|raspbian)
    ok "wykryto system: $os_id" ;;
  *)
    warn "wykryto system: $os_id — skrypt projektowano pod Debian/Ubuntu."
    if [ "$INTERACTIVE" = "1" ]; then
      read -r -p "Kontynuować mimo to? [t/N] " ans </dev/tty || die "brak terminala"
      case "$ans" in t|tak|y|yes) ;; *) exit 1 ;; esac
    else
      warn "kontynuuję (--yes)"
    fi
    ;;
esac

# minimalne narzędzia do pobrania repo
BOOTSTRAP_PKGS=()
for cmd in git curl tar; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    BOOTSTRAP_PKGS+=("$cmd")
  fi
done

if [ "${#BOOTSTRAP_PKGS[@]}" -gt 0 ]; then
  info "instaluję minimalne zależności: ${BOOTSTRAP_PKGS[*]}"
  apt-get update -qq
  apt-get install -y --no-install-recommends "${BOOTSTRAP_PKGS[@]}"
  ok "zainstalowano: ${BOOTSTRAP_PKGS[*]}"
fi

# --- pobranie repozytorium ---------------------------------------------------
TMPDIR_INSTALL="$(mktemp -d /tmp/work6-install.XXXXXX)"
chmod 0700 "$TMPDIR_INSTALL"
info "katalog tymczasowy: $TMPDIR_INSTALL"

info "klonuję repozytorium (branch: $BRANCH)..."
git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$TMPDIR_INSTALL/$REPO_NAME"
ok "repozytorium pobrane"

INSTALL_DIR="$TMPDIR_INSTALL/$REPO_NAME"

# weryfikacja struktury
for f in prepare-system.sh setup-work6.sh lib/common.sh; do
  [ -f "$INSTALL_DIR/$f" ] \
    || die "brak pliku $f w repozytorium — uszkodzone pobieranie?"
done
ok "struktura repozytorium poprawna"

# --- uruchomienie prepare-system.sh ------------------------------------------
echo
if [ "$RUN_PREPARE" = "1" ]; then
  info "uruchamiam prepare-system.sh (etap 1)..."
  echo "================================================================"

  PREPARE_ARGS=("--user" "$AGENT_USER")
  chmod +x "$INSTALL_DIR/prepare-system.sh"
  bash "$INSTALL_DIR/prepare-system.sh" "${PREPARE_ARGS[@]}"

  echo "================================================================"
  ok "prepare-system.sh zakończony"
else
  warn "pominięto prepare-system.sh (--no-prepare)"
  warn "uruchom sam:  sudo $INSTALL_DIR/prepare-system.sh --user $AGENT_USER"
fi

# --- upewnienie się, że pliki są u agenta ------------------------------------
echo
AGENT_HOME=""
if getent passwd "$AGENT_USER" >/dev/null 2>&1; then
  AGENT_HOME="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
  DEST="$AGENT_HOME/work6-config"

  if [ ! -d "$DEST" ] || [ "$INSTALL_DIR" != "$DEST" ]; then
    info "kopiuję pliki instalacyjne do $DEST..."
    rsync -a --delete --chown="${AGENT_USER}:${AGENT_USER}" \
      "$INSTALL_DIR/" "$DEST/"
    chmod 0700 "$DEST"
    ok "pliki skopiowane do $DEST"
  fi
else
  warn "użytkownik '$AGENT_USER' nie istnieje — pliki pozostają w $INSTALL_DIR"
  warn "po utworzeniu użytkownika skopiuj ręcznie lub uruchom skrypt ponownie"
  DEST="$INSTALL_DIR"
fi

# --- podsumowanie ------------------------------------------------------------
echo
echo "================================================================"
ok "=== Instalacja wstępna zakończona ==="
echo "================================================================"
echo
info "Następne kroki:"
echo
if [ -n "$AGENT_HOME" ]; then
  echo "  1. Przełącz się na konto agenta:"
  echo "     sudo -iu $AGENT_USER"
  echo
  echo "  2. Uruchom kreator środowiska:"
  echo "     cd ~/work6-config && ./setup-work6.sh"
  echo
  echo "  3. Jeśli setup zgłosi zależności systemowe:"
  echo "     sudo $DEST/prepare-system.sh --stage2"
  echo
  echo "  4. Diagnostyka:"
  echo "     ~/work6/scripts/doctor.sh"
else
  echo "  1. Utwórz użytkownika agenta:"
  echo "     sudo adduser --disabled-password --gecos 'AI agent (work6)' $AGENT_USER"
  echo
  echo "  2. Skopiuj pliki instalacyjne:"
  echo "     sudo cp -a $INSTALL_DIR /home/$AGENT_USER/work6-config"
  echo "     sudo chown -R $AGENT_USER:$AGENT_USER /home/$AGENT_USER/work6-config"
  echo
  echo "  3. Przełącz się i uruchom kreator:"
  echo "     sudo -iu $AGENT_USER"
  echo "     cd ~/work6-config && ./setup-work6.sh"
fi
echo
info "Pełna dokumentacja: README.md w katalogu instalacyjnym"
