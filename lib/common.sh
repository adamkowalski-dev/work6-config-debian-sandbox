# shellcheck shell=bash
# ============================================================================
# work6 — wspólna biblioteka: logowanie, trap błędów, guardy, pobieranie
#
# Kontrakt: plik jest source'owany przez skrypty mające już ustawione
#   set -Eeuo pipefail
# oraz zmienną ROOT_DIR (katalog zawierający lib/, config/, bin/ ...).
# Po common_init dostępne są: WORK6, CONFIG_FILE, VERSIONS_FILE itd.
# ============================================================================

# --- kolory (tylko na terminalu) -------------------------------------------
if [ -t 2 ]; then
  _C_INFO=$'\033[1;34m'; _C_WARN=$'\033[1;33m'; _C_ERR=$'\033[1;31m'
  _C_OK=$'\033[1;32m'; _C_OFF=$'\033[0m'
else
  _C_INFO=""; _C_WARN=""; _C_ERR=""; _C_OK=""; _C_OFF=""
fi

info()  { printf '%s[info]%s %s\n'  "$_C_INFO" "$_C_OFF" "$*" >&2; }
ok()    { printf '%s[ ok ]%s %s\n'  "$_C_OK"   "$_C_OFF" "$*" >&2; }
warn()  { printf '%s[uwaga]%s %s\n' "$_C_WARN" "$_C_OFF" "$*" >&2; }
error() { printf '%s[błąd]%s %s\n'  "$_C_ERR"  "$_C_OFF" "$*" >&2; }
die()   { error "$*"; exit 1; }

# --- trap błędów: plik, linia, komenda --------------------------------------
_on_error() {
  local code="$1" line="$2" cmd="$3" src="${4:-?}"
  error "przerwano: ${src}:${line}: '${cmd}' zakończone kodem ${code}"
  exit "$code"
}
enable_error_trap() {
  # BASH_SOURCE[0] w trapie wskazuje plik, w którym wystąpił błąd
  trap '_on_error "$?" "$LINENO" "$BASH_COMMAND" "${BASH_SOURCE[0]}"' ERR
}

# --- pytania interaktywne ----------------------------------------------------
# confirm "pytanie" [tak|nie]  -> kod 0 = tak
# Przy ASSUME_YES=1 (tryb --yes) zwraca odpowiedź domyślną bez pytania.
confirm() {
  local q="$1" def="${2:-nie}" hint ans
  if [ "${ASSUME_YES:-0}" = "1" ]; then
    info "auto (--yes): '$q' -> $def"
    [ "$def" = "tak" ] && return 0 || return 1
  fi
  case "$def" in
    tak) hint="[T/n]" ;;
    *)   hint="[t/N]" ;;
  esac
  while true; do
    read -r -p "$q $hint " ans </dev/tty || die "brak terminala do potwierdzenia"
    ans="$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')"
    case "$ans" in
      "") [ "$def" = "tak" ] && return 0 || return 1 ;;
      t|tak|y|yes) return 0 ;;
      n|nie|no)    return 1 ;;
      *) echo "Odpowiedz: t / n" ;;
    esac
  done
}

# choose ZMIENNA "pytanie" domyślna opcja1 opcja2 ...
# Wypisuje ponumerowane opcje, wynik ląduje w zmiennej o podanej nazwie.
choose() {
  local -n _out="$1"; shift
  local q="$1" def="$2"; shift 2
  local opts=("$@") i ans
  if [ "${ASSUME_YES:-0}" = "1" ]; then
    info "auto (--yes): '$q' -> $def"
    _out="$def"
    return 0
  fi
  echo "$q" >&2
  for i in "${!opts[@]}"; do
    if [ "${opts[$i]}" = "$def" ]; then
      printf '  %d) %s  (domyślne)\n' "$((i + 1))" "${opts[$i]}" >&2
    else
      printf '  %d) %s\n' "$((i + 1))" "${opts[$i]}" >&2
    fi
  done
  while true; do
    read -r -p "Wybór [Enter = domyślne]: " ans </dev/tty \
      || die "brak terminala do wyboru"
    if [ -z "$ans" ]; then _out="$def"; return 0; fi
    if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "${#opts[@]}" ]; then
      _out="${opts[$((ans - 1))]}"; return 0
    fi
    echo "Podaj numer 1-${#opts[@]}" >&2
  done
}

is_yes() { [ "${1:-}" = "yes" ] || [ "${1:-}" = "tak" ]; }

# --- narzędzia ---------------------------------------------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "brak wymaganego narzędzia: $1 ($2)"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

timestamp() { date +%Y-%m-%dT%H:%M:%S%z; }

# --- porównywanie wersji ------------------------------------------------------
# Wersje bywają zapisane raz z "v", raz bez, i z sufiksem (-rc1, +meta).
# Do porównania bierzemy wyłącznie człony numeryczne MAJOR.MINOR.PATCH.
#
# OGRANICZENIE: sufiks przedwydaniowy jest OBCINANY, więc 2.0.0-rc1
# i 2.0.0 wychodzą jako RÓWNE (semver mówi, że rc1 jest wcześniejsze).
# Skutek: na kanale RC aktualizacja rc -> finalna wersja nie zostanie
# wykryta i wymaga `update-tools.sh --force`. Świadomy kompromis:
# kanały stable/latest Claude Code i manifest agy nie używają sufiksów,
# a pełne reguły precedencji semver to spory kawałek kodu w bashu.
# Jeśli kiedyś dojdzie kanał z RC — trzeba tu dopisać porównanie
# sufiksów (brak sufiksu > sufiks; dalej leksykograficznie po członach).
version_core() {
  local v="${1#v}"
  v="${v%%[-+]*}"
  printf '%s' "$v"
}

# semver_cmp A B — kod wyjścia: 0 gdy A==B, 1 gdy A>B, 2 gdy A<B,
# 3 gdy któraś wersja jest niepoprawna (wtedy NIE zgadujemy kierunku).
semver_cmp() {
  local a b ai bi i
  a="$(version_core "${1:-}")"; b="$(version_core "${2:-}")"
  [[ "$a" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 3
  [[ "$b" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 3
  IFS='.' read -r -a ai <<<"$a"
  IFS='.' read -r -a bi <<<"$b"
  for i in 0 1 2; do
    local x="${ai[$i]:-0}" y="${bi[$i]:-0}"
    [ "$x" -gt "$y" ] && return 1
    [ "$x" -lt "$y" ] && return 2
  done
  return 0
}

# Bezpieczne pobieranie: tylko HTTPS, retry, fail na HTTP >= 400.
# download URL PLIK_DOCELOWY
download() {
  local url="$1" out="$2"
  need_cmd curl "apt install curl"
  info "pobieram: $url"
  curl --fail --location --proto '=https' --tlsv1.2 \
    --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 3600 \
    --silent --show-error --output "$out" "$url"
}

# download_stdout URL  — jak wyżej, na stdout (krótkie odpowiedzi typu wersja)
download_stdout() {
  local url="$1"
  curl --fail --location --proto '=https' --tlsv1.2 \
    --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 300 \
    --silent --show-error "$url"
}

# sha256_verify PLIK OCZEKIWANA_SUMA
sha256_verify() {
  local f="$1" want="$2" got
  got="$(sha256sum "$f" | cut -d' ' -f1)"
  if [ "$got" != "$want" ]; then
    rm -f -- "$f"
    die "SHA-256 nie zgadza się dla $f (oczekiwano ${want}, jest ${got}) — plik usunięty"
  fi
  ok "SHA-256 OK: $(basename "$f")"
}

# sha512_verify PLIK OCZEKIWANA_SUMA
sha512_verify() {
  local f="$1" want="$2" got
  got="$(sha512sum "$f" | cut -d' ' -f1)"
  if [ "$got" != "$want" ]; then
    rm -f -- "$f"
    die "SHA-512 nie zgadza się dla $f — plik usunięty"
  fi
  ok "SHA-512 OK: $(basename "$f")"
}

# ensure_dir KATALOG [TRYB]
ensure_dir() {
  local d="$1" mode="${2:-}"
  mkdir -p -- "$d"
  [ -n "$mode" ] && chmod "$mode" -- "$d"
  return 0
}

# record_kv PLIK KLUCZ WARTOŚĆ — nadpisz lub dopisz KLUCZ="WARTOŚĆ"
record_kv() {
  local file="$1" key="$2" val="$3" tmp
  touch -- "$file"
  tmp="$(mktemp "${file}.XXXXXX")"
  grep -v "^${key}=" -- "$file" >"$tmp" || true
  printf '%s="%s"\n' "$key" "$val" >>"$tmp"
  chmod 0600 -- "$tmp"
  mv -- "$tmp" "$file"
}

# read_kv PLIK KLUCZ — wypisz wartość (pusty string gdy brak)
read_kv() {
  local file="$1" key="$2" line
  [ -f "$file" ] || return 0
  line="$(grep "^${key}=" -- "$file" | tail -n1 || true)"
  line="${line#*=}"
  line="${line%\"}"; line="${line#\"}"
  printf '%s' "$line"
}

# record_component NAZWA WERSJA ŹRÓDŁO SUMA AKCJA
# Aktualizuje versions.env + dopisuje wiersz do state/manifest.tsv.
record_component() {
  local name="$1" ver="$2" src="$3" hash="$4" action="$5" key
  key="$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')"
  record_kv "$VERSIONS_FILE" "${key}_VERSION" "$ver"
  record_kv "$VERSIONS_FILE" "${key}_SOURCE"  "$src"
  record_kv "$VERSIONS_FILE" "${key}_SHA"     "$hash"
  record_kv "$VERSIONS_FILE" "${key}_DATE"    "$(timestamp)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(timestamp)" "$name" "$ver" "$src" "$hash" "$action" >>"$MANIFEST_FILE"
  chmod 0600 -- "$MANIFEST_FILE" 2>/dev/null || true
}

# --- guardy bezpieczeństwa ---------------------------------------------------
require_not_root() {
  [ "$(id -u)" -ne 0 ] || die "nie uruchamiaj tego jako root"
}

# Wymusza konto agenta; podpowiada właściwą komendę.
require_agent_user() {
  require_not_root
  local me; me="$(id -un)"
  if [ "$me" != "$AGENT_USER" ]; then
    error "to polecenie działa wyłącznie jako '${AGENT_USER}' (jesteś: ${me})."
    error "Przełącz się:  sudo -iu ${AGENT_USER}"
    exit 1
  fi
}

# Weryfikuje, że zmienne sesji graficznej wskazują sesję BIEŻĄCEGO
# użytkownika — chroni przed przypadkowym użyciem sesji administratora
# (np. `sudo -u ai-agent bin/run-vscode` bez `-i` dziedziczy DISPLAY
# i XAUTHORITY admina; tego nie wolno przekazać procesom agenta).
require_own_session() {
  if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    { [ -d "$XDG_RUNTIME_DIR" ] \
      && [ "$(stat -c %u -- "$XDG_RUNTIME_DIR")" = "$(id -u)" ]; } \
      || die "XDG_RUNTIME_DIR nie należy do $(id -un) — zaloguj się do WŁASNEJ sesji agenta (nie 'sudo -u' z cudzej)"
  fi
  if [ -n "${XAUTHORITY:-}" ]; then
    { [ -f "$XAUTHORITY" ] \
      && [ "$(stat -c %u -- "$XAUTHORITY")" = "$(id -u)" ]; } \
      || die "XAUTHORITY nie należy do $(id -un) — odmowa użycia cudzej sesji X"
  fi
}

# Weryfikuje, że katalog należy do bieżącego użytkownika i nie jest
# dowiązaniem — chroni przed podmianą ścieżek środowiska.
require_owned_dir() {
  local d="$1"
  [ -d "$d" ] || die "brak katalogu: $d (uruchom setup-work6.sh)"
  [ ! -L "$d" ] || die "$d jest dowiązaniem symbolicznym — odmowa"
  [ "$(stat -c %u -- "$d")" = "$(id -u)" ] || die "$d nie należy do $(id -un) — odmowa"
}

# --- dryf kodu: klon repo vs zainstalowane work6 -------------------------------
# work6 uruchamia kod ze SWOJEJ kopii ($WORK6/{bin,scripts,lib,setup.d}),
# zsynchronizowanej z klonu repo przez setup-work6.sh. Po `git pull` bez
# ponownego setupu obie kopie się rozjeżdżają i wszystko leci starym
# kodem — to jest cichy powód dla „poprawka jest w repo, a nic się nie
# zmienia".

# work6_repo_dir — wypisuje ścieżkę klonu repo (źródła synchronizacji).
# Kolejność: jawny $WORK6_CONFIG_REPO > $ROOT_DIR, jeśli sam jest klonem
# (skrypt odpalony z repo, nie z work6) > $HOME/work6-config.
# Kod wyjścia 1, gdy żaden kandydat nie wygląda na klon repo.
work6_repo_dir() {
  local c
  for c in "${WORK6_CONFIG_REPO:-}" "${ROOT_DIR:-}" "$HOME/work6-config"; do
    [ -n "$c" ] && [ -d "$c" ] || continue
    [ -f "$c/setup-work6.sh" ] && [ -d "$c/setup.d" ] || continue
    # $WORK6 nie jest własnym źródłem (praca bezpośrednio w drzewie repo)
    [ "$(readlink -f "$c")" = "$(readlink -f "$WORK6")" ] && continue
    readlink -f "$c"
    return 0
  done
  return 1
}

# work6_repo_sync_status — czy $WORK6 ma ten sam kod co klon repo.
# Rozbieżne pliki wypisuje sam (info); werdykt i jego wagę ustala
# wywołujący. Kod wyjścia:
#   0 = zgodne, 1 = dryf, 2 = NIE DA SIĘ ustalić (powód na ekranie).
# Kod 2 nigdy nie udaje 0: „nie sprawdziłem" to inna informacja niż
# „sprawdziłem i jest dobrze" — ciche przepuszczanie było dokładnie tym
# błędem, który ta funkcja ma wykrywać u innych.
work6_repo_sync_status() {
  local repo d f base drift=0
  if [ -n "${WORK6_CONFIG_REPO:-}" ] \
     && { [ ! -d "$WORK6_CONFIG_REPO" ] || [ ! -f "$WORK6_CONFIG_REPO/setup-work6.sh" ]; }; then
    warn "WORK6_CONFIG_REPO='$WORK6_CONFIG_REPO' nie wygląda na klon work6-config"
    return 2
  fi
  # $WORK6 bywa samym drzewem repo (praca w klonie, .work6-root w nim) —
  # wtedy nie ma dwóch kopii i nie ma czemu się rozjechać.
  if [ -f "$WORK6/setup-work6.sh" ] && [ -d "$WORK6/setup.d" ]; then
    return 0
  fi
  if ! repo="$(work6_repo_dir)"; then
    warn "nie znalazłem klonu repo work6-config (sprawdzałem: \$WORK6_CONFIG_REPO,"
    warn "  \$ROOT_DIR, $HOME/work6-config) — nie wiem, czy $WORK6 ma aktualny kod"
    warn "wskaż klon jawnie:  WORK6_CONFIG_REPO=/ścieżka/do/work6-config $0 ..."
    return 2
  fi
  for d in setup.d lib bin scripts; do
    [ -d "$repo/$d" ] || continue
    for f in "$repo/$d"/*; do
      [ -f "$f" ] || continue
      base="$(basename "$f")"
      if [ ! -f "$WORK6/$d/$base" ]; then
        info "  dryf: $d/$base — jest w repo, brak w work6"
        drift=1
      elif ! cmp -s "$f" "$WORK6/$d/$base"; then
        info "  dryf: $d/$base — inna treść niż w repo"
        drift=1
      fi
    done
  done
  [ "$drift" -eq 0 ]
}

# --- inicjalizacja -----------------------------------------------------------
# load_config: wczytuje install.env + sandbox.env i ustala WORK6.
# Kolejność: zainstalowany config w work6 > szablon z ROOT_DIR.
load_config() {
  local inst
  # AGENT_USER potrzebny zanim znamy WORK6 → najpierw szablon, potem nadpis.
  # shellcheck source=/dev/null
  [ -f "$ROOT_DIR/config/install.env" ] && . "$ROOT_DIR/config/install.env"
  WORK6="${WORK6_DIR:-$HOME/work6}"
  # Launchery i skrypty ZAINSTALOWANE w work6 działają zawsze na drzewie,
  # w którym leżą — nie na tym, co wskaże środowisko.
  [ -f "$ROOT_DIR/.work6-root" ] && WORK6="$ROOT_DIR"
  inst="$WORK6/config/install.env"
  if [ -f "$inst" ] && [ "$inst" != "$ROOT_DIR/config/install.env" ]; then
    # shellcheck source=/dev/null
    . "$inst"
    WORK6="${WORK6_DIR:-$HOME/work6}"
  fi
  # shellcheck source=/dev/null
  if [ -f "$WORK6/config/sandbox.env" ]; then . "$WORK6/config/sandbox.env"
  elif [ -f "$ROOT_DIR/config/sandbox.env" ]; then . "$ROOT_DIR/config/sandbox.env"
  fi
  CONFIG_FILE="$WORK6/config/install.env"
  VERSIONS_FILE="$WORK6/config/versions.env"
  MANIFEST_FILE="$WORK6/state/manifest.tsv"
  ADMIN_TODO="$WORK6/state/admin-todo.pkgs"
  DL_DIR="$WORK6/downloads"
  export WORK6
}

# Pełne drzewo środowiska. Wszystko 0700 — środowisko jest prywatne
# dla konta agenta (spec: home/config/browser-profile/backups/state
# muszą być 0700; resztę też tak trzymamy, prościej i bezpieczniej).
WORK6_TREE=(bin home cache config tmp logs tools npm-global node python
  projects browsers browser-profile scripts backups downloads runtime
  state setup.d lib)

ensure_tree() {
  local d
  ensure_dir "$WORK6" 0700
  for d in "${WORK6_TREE[@]}"; do
    ensure_dir "$WORK6/$d" 0700
  done
  ensure_dir "$WORK6/cache/npm" 0700
  ensure_dir "$WORK6/cache/pip" 0700
  ensure_dir "$WORK6/cache/pub" 0700
  [ -f "$WORK6/.work6-root" ] || {
    printf 'created=%s\n' "$(timestamp)" >"$WORK6/.work6-root"
    chmod 0600 "$WORK6/.work6-root"
  }
}

# parse_launcher_args "$@" — obsługa wspólnej flagi launcherów:
#   [--workspace KATALOG] (względny = podkatalog projects/)
# Ustawia: WS (katalog roboczy) i tablicę LAUNCH_ARGS (reszta argumentów).
parse_launcher_args() {
  WS="${AGENT_WORKSPACE:-$WORK6/projects}"
  if [ "${1:-}" = "--workspace" ]; then
    [ -n "${2:-}" ] || die "--workspace wymaga katalogu"
    WS="$2"; shift 2
  fi
  case "$WS" in
    /*) : ;;
    *) WS="$WORK6/projects/$WS" ;;
  esac
  LAUNCH_ARGS=("$@")
}

# launch_log NARZĘDZIE — zapisuje TYLKO metadane startu (bez argumentów
# i bez treści sesji: w sesjach agentów pojawiają się URL-e i kody OAuth,
# które nie mogą trafić do logów).
launch_log() {
  local logf="$WORK6/logs/launch.log"
  [ -d "$WORK6/logs" ] || return 0
  printf '%s\t%s\tworkspace=%s\n' "$(timestamp)" "$1" "${WS:-?}" >>"$logf"
  chmod 0600 -- "$logf" 2>/dev/null || true
}

# log_init NAZWA — loguje całe stdout+stderr do work6/logs/NAZWA-<ts>.log.
# Wywoływać dopiero, gdy katalog logs/ istnieje. Skrypty obsługujące
# logowanie OAuth NIE używają log_init (sekrety nie mogą trafić do logów).
log_init() {
  local name="$1" logdir="$WORK6/logs" logfile
  [ -d "$logdir" ] || return 0
  logfile="$logdir/${name}-$(date +%Y%m%d-%H%M%S).log"
  touch -- "$logfile" && chmod 0600 -- "$logfile"
  exec > >(tee -a -- "$logfile") 2>&1
  info "log: $logfile"
}

# common_init — standardowy start skryptu (po ustawieniu ROOT_DIR).
common_init() {
  umask 077
  enable_error_trap
  # shellcheck source=lib/env.sh
  . "$ROOT_DIR/lib/env.sh"
  load_config
  # Lokalny Node na PATH procesu: npm i CLI z npm-global mają shebang
  # `#!/usr/bin/env node` — bez tego nie ruszą (dotyczy skryptów
  # pomocniczych; wewnątrz sandboxa PATH i tak jest budowany jawnie).
  if [ -d "$WORK6/node/current/bin" ]; then
    case ":$PATH:" in
      *":$WORK6/node/current/bin:"*) : ;;
      *) PATH="$WORK6/node/current/bin:$PATH" ;;
    esac
  fi
}
