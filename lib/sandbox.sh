# shellcheck shell=bash
# ============================================================================
# work6 — budowa sandboxa bubblewrap (serce izolacji)
#
# Zasady (świadome decyzje bezpieczeństwa — zmieniaj tylko z review):
#   * --clearenv zawsze; każda zmienna przekazana jawnie,
#   * ŻADNEGO --ro-bind / /, --bind $HOME, /run hosta, /tmp hosta,
#     socketów SSH/GPG/Docker/D-Bus, /run/user/<uid> hosta,
#   * system tylko do odczytu: /usr + symlinki merged-usr + minimalne /etc,
#   * zapis wyłącznie w wybranych podkatalogach work6 (bez backups/,
#     downloads/, logs/, bin/, lib/, scripts/ — sandbox ich nie widzi),
#   * /etc/passwd i /etc/group to generowane atrapy (hostowe wyciekałyby
#     listę kont),
#   * /tmp, /var/tmp, /run — prywatne tmpfs; /run/user/<uid> świeży, 0700.
#
# Ograniczenie: bwrap współdzieli jądro z hostem. To mocna warstwa
# izolacji uprawnień i systemu plików, ale NIE odpowiednik maszyny
# wirtualnej.
#
# Kontrakt: source po lib/common.sh, po common_init (WORK6 ustawione).
# ============================================================================

# Katalogi work6 widoczne w sandboxie DO ZAPISU. backups/ i downloads/
# celowo poza listą (agent nie może manipulować kopiami zapasowymi),
# logs/ poza listą (integralność logów launcherów).
# config/ i tools/ NIE są tu — montowane osobno TYLKO DO ODCZYTU
# (patrz sandbox_build_args): config/ steruje uprawnieniami następnej
# sesji, tools/ to binarki CLI, którym ufa operator.
SANDBOX_RW_DIRS=(home projects tmp cache state runtime
  browsers npm-global node python)

# --- atrapy /etc/passwd i /etc/group -----------------------------------------
_sandbox_write_fake_ids() {
  local uid="$1" gid="$2" pw="$3" gr="$4"
  cat >"$pw" <<EOF
root:x:0:0:root:/root:/usr/sbin/nologin
${AGENT_USER}:x:${uid}:${gid}:AI agent:${WORK6}/home:/bin/bash
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
EOF
  cat >"$gr" <<EOF
root:x:0:
${AGENT_USER}:x:${gid}:
nogroup:x:65534:
EOF
  chmod 0600 -- "$pw" "$gr"
}

# Stały, sztuczny machine-id (niektóre narzędzia go oczekują; hostowego
# nie ujawniamy). Generowany raz.
_sandbox_machine_id_file() {
  local f="$WORK6/state/sandbox-machine-id"
  if [ ! -s "$f" ]; then
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n' >"$f"
    printf '\n' >>"$f"
    chmod 0600 -- "$f"
  fi
  printf '%s' "$f"
}

# --- budowa argumentów --------------------------------------------------------
# sandbox_build_args TRYB_SIECI(net|no-net) KATALOG_PROJEKTU
# Wynik w globalnej tablicy SANDBOX_ARGS.
sandbox_build_args() {
  local net_mode="$1" workspace="$2"
  local uid gid d f real p
  uid="$(id -u)"; gid="$(id -g)"

  need_cmd bwrap "apt install bubblewrap (przez prepare-system.sh)"
  require_owned_dir "$WORK6"

  # Walidacja workspace: tylko drzewo projects (zapis do kodu wyłącznie tam).
  workspace="$(readlink -f -- "$workspace")" \
    || die "nie mogę rozwiązać ścieżki projektu"
  case "$workspace/" in
    "$WORK6/projects/"*|"$WORK6/projects/") : ;;
    *) die "katalog roboczy musi leżeć w $WORK6/projects (jest: $workspace)" ;;
  esac
  [ -d "$workspace" ] || die "katalog projektu nie istnieje: $workspace"

  local pw="$WORK6/runtime/sandbox-passwd" gr="$WORK6/runtime/sandbox-group"
  _sandbox_write_fake_ids "$uid" "$gid" "$pw" "$gr"

  SANDBOX_ARGS=(
    --die-with-parent --new-session
    --unshare-user --unshare-pid --unshare-ipc --unshare-uts
    --unshare-cgroup-try
    --hostname "${SANDBOX_HOSTNAME:-work6}"
    --clearenv
    --proc /proc
    --dev /dev
    --tmpfs /tmp
    --tmpfs /var/tmp
    --tmpfs /run
    --dir /run/user
    --perms 0700 --dir "/run/user/$uid"
  )
  if [ "$net_mode" = "no-net" ]; then
    SANDBOX_ARGS+=( --unshare-net )
  fi

  # System RO — Debian 12+ ma merged-usr, więc /bin itd. to symlinki.
  SANDBOX_ARGS+=( --ro-bind /usr /usr
    --symlink usr/bin /bin --symlink usr/sbin /sbin --symlink usr/lib /lib )
  [ -e /lib64 ] && SANDBOX_ARGS+=( --symlink usr/lib64 /lib64 )

  # Minimalne /etc — tylko to, czego potrzebują dynamiczny linker,
  # DNS/TLS i TUI. /etc/alternatives jest niezbędne (awk, pager, ...).
  for d in /etc/alternatives /etc/ssl /etc/terminfo; do
    [ -d "$d" ] && SANDBOX_ARGS+=( --ro-bind "$d" "$d" )
  done
  for f in /etc/ld.so.cache /etc/nsswitch.conf /etc/hosts /etc/services \
           /etc/protocols /etc/gai.conf /etc/ca-certificates.conf; do
    [ -f "$f" ] && SANDBOX_ARGS+=( --ro-bind "$f" "$f" )
  done
  if [ "$net_mode" = "net" ] && [ -e /etc/resolv.conf ]; then
    # resolv.conf bywa symlinkiem (systemd-resolved) — bindujemy cel.
    real="$(readlink -f /etc/resolv.conf || true)"
    [ -n "$real" ] && [ -e "$real" ] \
      && SANDBOX_ARGS+=( --ro-bind "$real" /etc/resolv.conf )
  fi
  if [ -e /etc/localtime ]; then
    real="$(readlink -f /etc/localtime)"
    case "$real" in
      /usr/*) SANDBOX_ARGS+=( --symlink "$real" /etc/localtime ) ;;
    esac
  fi
  SANDBOX_ARGS+=( --ro-bind "$pw" /etc/passwd --ro-bind "$gr" /etc/group )
  SANDBOX_ARGS+=( --ro-bind "$(_sandbox_machine_id_file)" /etc/machine-id )

  # Zapisywalne katalogi work6 (tylko istniejące — komponenty bywają
  # wyłączone). Ścieżki wewnątrz = te same co na hoście.
  for d in "${SANDBOX_RW_DIRS[@]}"; do
    p="$WORK6/$d"
    [ -e "$p" ] || continue
    [ -L "$p" ] && die "$p jest dowiązaniem symbolicznym — odmawiam montowania"
    [ -d "$p" ] && SANDBOX_ARGS+=( --bind "$p" "$p" )
  done
  # config/ tylko RO: install.env i sandbox.env decydują o UPRAWNIENIACH
  # kolejnej sesji (load_config czyta je na hoście, przed bwrap) — agent
  # nie może ich modyfikować. tools/ tylko RO: agent nie może podmienić
  # binarek claude/agy (DISABLE_AUTOUPDATER=1 to ta sama decyzja).
  # Wyjątek: Flutter SDK dopisuje do własnego drzewa (bin/cache) — RW.
  [ -d "$WORK6/config" ] && SANDBOX_ARGS+=( --ro-bind "$WORK6/config" "$WORK6/config" )
  [ -d "$WORK6/tools" ] && SANDBOX_ARGS+=( --ro-bind "$WORK6/tools" "$WORK6/tools" )
  [ -d "$WORK6/tools/flutter" ] \
    && SANDBOX_ARGS+=( --bind "$WORK6/tools/flutter" "$WORK6/tools/flutter" )

  # Projekt widoczny też jako /workspace; start w nim.
  SANDBOX_ARGS+=( --bind "$workspace" /workspace --chdir /workspace )

  # --- środowisko: wyłącznie jawne zmienne ---
  SANDBOX_ARGS+=(
    --setenv HOME "$WORK6/home"
    --setenv PATH "$(work6_sandbox_path "$WORK6")"
    --setenv USER "$AGENT_USER"
    --setenv LOGNAME "$AGENT_USER"
    --setenv SHELL /bin/bash
    --setenv LANG C.UTF-8
    --setenv LC_ALL C.UTF-8
    --setenv TERM "${TERM:-xterm-256color}"
    --setenv XDG_RUNTIME_DIR "/run/user/$uid"
    --setenv WORK6 "$WORK6"
  )
  [ -n "${COLORTERM:-}" ] && SANDBOX_ARGS+=( --setenv COLORTERM "$COLORTERM" )
  local line
  while IFS= read -r line; do
    SANDBOX_ARGS+=( --setenv "${line%%=*}" "${line#*=}" )
  done < <(work6_env_pairs "$WORK6")

  # --- opcjonalne GUI: sockety WŁASNEJ sesji agenta (sandbox.env) ---
  # Guard użytkownika w launcherze gwarantuje, że DISPLAY/WAYLAND należą
  # do sesji agenta, nie administratora. Domyślnie wyłączone.
  if is_yes "${SANDBOX_ALLOW_DISPLAY:-no}"; then
    require_own_session
    if [ -n "${DISPLAY:-}" ] && [ -d /tmp/.X11-unix ]; then
      SANDBOX_ARGS+=( --ro-bind /tmp/.X11-unix /tmp/.X11-unix
        --setenv DISPLAY "$DISPLAY" )
      local xauth="${XAUTHORITY:-$HOME/.Xauthority}"
      if [ -f "$xauth" ]; then
        SANDBOX_ARGS+=( --ro-bind "$xauth" "$WORK6/home/.Xauthority"
          --setenv XAUTHORITY "$WORK6/home/.Xauthority" )
      fi
    fi
    if [ -n "${WAYLAND_DISPLAY:-}" ] \
       && [ -S "${XDG_RUNTIME_DIR:-/run/user/$uid}/$WAYLAND_DISPLAY" ]; then
      SANDBOX_ARGS+=(
        --ro-bind "${XDG_RUNTIME_DIR:-/run/user/$uid}/$WAYLAND_DISPLAY" \
                  "/run/user/$uid/$WAYLAND_DISPLAY"
        --setenv WAYLAND_DISPLAY "$WAYLAND_DISPLAY" )
    fi
  fi

  # --- dodatki z sandbox.env (świadome poszerzenia) ---
  if [ -n "${SANDBOX_EXTRA_RO_BINDS:-}" ]; then
    local IFS=':'
    set -f
    for d in $SANDBOX_EXTRA_RO_BINDS; do
      [ -e "$d" ] || { warn "SANDBOX_EXTRA_RO_BINDS: brak $d — pomijam"; continue; }
      warn "dodatkowy ro-bind z konfiguracji: $d"
      SANDBOX_ARGS+=( --ro-bind "$d" "$d" )
    done
    set +f
  fi
  if [ -n "${SANDBOX_EXTRA_ENV:-}" ]; then
    set -f
    for line in $SANDBOX_EXTRA_ENV; do
      case "$line" in
        *=*) SANDBOX_ARGS+=( --setenv "${line%%=*}" "${line#*=}" ) ;;
      esac
    done
    set +f
  fi
}

# sandbox_exec TRYB_SIECI WORKSPACE -- KOMENDA [ARG...]
# Zastępuje bieżący proces sandboxem (dla launcherów).
sandbox_exec() {
  local net="$1" ws="$2"; shift 2
  [ "${1:-}" = "--" ] && shift
  sandbox_build_args "$net" "$ws"
  exec bwrap "${SANDBOX_ARGS[@]}" -- "$@"
}

# sandbox_try TRYB_SIECI WORKSPACE -- KOMENDA [ARG...]
# Jak wyżej, ale wraca z kodem wyjścia (dla doctor.sh).
sandbox_try() {
  local net="$1" ws="$2"; shift 2
  [ "${1:-}" = "--" ] && shift
  sandbox_build_args "$net" "$ws"
  bwrap "${SANDBOX_ARGS[@]}" -- "$@"
}
