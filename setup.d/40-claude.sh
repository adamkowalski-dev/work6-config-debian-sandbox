# shellcheck shell=bash
# ============================================================================
# Moduł: Claude Code CLI — natywna binarka z oficjalnego bucketu release'ów,
# weryfikowana DWUSTOPNIOWO:
#   1. podpis GPG manifestu (manifest.json.sig) kluczem Anthropic
#      z PINOWANYM fingerprintem,
#   2. SHA-256 binarki z podpisanego manifestu.
# Zero `curl | bash`, zero npm. Auto-updater wyłączony — aktualizacje
# wyłącznie przez scripts/update-tools.sh.
# Źródło mechanizmu: https://code.claude.com/docs/en/setup (2026-07).
# ============================================================================

MODULE_LIST+=("claude")

CLAUDE_DL_BASE="https://downloads.claude.ai/claude-code-releases"
CLAUDE_KEY_URL="https://downloads.claude.ai/keys/claude-code.asc"
# Fingerprint klucza podpisującego release'y (pin bezpieczeństwa!).
# Zweryfikowany w dokumentacji 2026-07-16. Zmieniaj tylko po ręcznym
# sprawdzeniu ogłoszenia Anthropic.
CLAUDE_GPG_FPR="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"

claude_enabled() { is_yes "$INSTALL_CLAUDE"; }

claude_platform() {
  local arch
  case "$(uname -m)" in
    x86_64)  arch="x64" ;;
    aarch64) arch="arm64" ;;
    *) die "Claude Code: nieobsługiwana architektura $(uname -m)" ;;
  esac
  if ldd /bin/ls 2>&1 | grep -q musl; then
    echo "linux-${arch}-musl"
  else
    echo "linux-${arch}"
  fi
}

# Źródłem prawdy jest BINARKA, nie versions.env: Claude Code potrafi się
# doaktualizować sam (albo plik odjeżdża po restore z backupu), a wtedy
# zapis w versions.env kłamie. versions.env zostaje jako fallback, gdy
# binarka nie odpowiada.
claude_installed_version() {
  local bin="$WORK6/tools/claude/current/claude" ver
  [ -x "$bin" ] || return 0
  ver="$(timeout 20 env HOME="$WORK6/home" \
    CLAUDE_CONFIG_DIR="$WORK6/home/.claude" "$bin" --version 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  [ -n "$ver" ] || ver="$(read_kv "$VERSIONS_FILE" CLAUDE_VERSION)"
  printf '%s' "$ver"
}

# Wersja zapisana przy ostatniej instalacji — do wykrywania dryfu.
claude_recorded_version() { read_kv "$VERSIONS_FILE" CLAUDE_VERSION; }

# NIE wywołuje die: to funkcja diagnostyczna, wołana także z --check.
# Błąd → komunikat na stderr i kod 1, żeby wywołujący mógł pokazać powód
# zamiast cichego „nie mogę ustalić wersji".
claude_remote_version() {
  local ch="${CLAUDE_CHANNEL:-stable}" ver
  case "$ch" in
    stable|latest)
      if ! ver="$(download_stdout "$CLAUDE_DL_BASE/$ch" 2>&1)"; then
        error "Claude Code: nie mogę pobrać wersji z kanału '$ch': $ver"
        return 1
      fi
      ;;
    *) ver="$ch" ;;
  esac
  ver="$(printf '%s' "$ver" | tr -d '[:space:]')"
  if ! [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    error "Claude Code: kanał '$ch' zwrócił coś, co nie jest wersją: '${ver:0:80}'"
    return 1
  fi
  printf '%s' "$ver"
}

# Co jest na DRUGIM kanale — czysto informacyjnie, żeby było widać dystans
# między stable a latest i dało się świadomie zdecydować o przełączeniu.
claude_channel_note() {
  local ch="${CLAUDE_CHANNEL:-stable}" other ver
  case "$ch" in
    stable) other="latest" ;;
    latest) other="stable" ;;
    *) return 0 ;;
  esac
  ver="$(download_stdout "$CLAUDE_DL_BASE/$other" 2>/dev/null | tr -d '[:space:]')" || return 0
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || return 0
  printf 'kanał %s ma %s (zmiana: CLAUDE_CHANNEL w config/install.env)' "$other" "$ver"
}

# Weryfikacja podpisu GPG manifestu w JEDNORAZOWYM, izolowanym keyringu.
_claude_verify_manifest() {
  local manifest="$1" sig="$2" keyfile="$3" gnupg fpr
  need_cmd gpg "apt install gnupg (przez prepare-system.sh)"
  gnupg="$(mktemp -d "$WORK6/tmp/gnupg.XXXXXX")"
  chmod 0700 "$gnupg"
  # Fingerprint klucza PRZED importem musi zgadzać się z pinem.
  fpr="$(GNUPGHOME="$gnupg" gpg --batch --with-colons \
    --import-options show-only --import "$keyfile" 2>/dev/null \
    | awk -F: '/^fpr:/{print $10; exit}')"
  if [ "$fpr" != "$CLAUDE_GPG_FPR" ]; then
    rm -rf -- "$gnupg"
    die "Claude Code: fingerprint klucza ($fpr) NIE zgadza się z pinem — możliwa podmiana!"
  fi
  GNUPGHOME="$gnupg" gpg --batch --import "$keyfile" 2>/dev/null
  if ! GNUPGHOME="$gnupg" gpg --batch --status-fd 1 \
        --verify "$sig" "$manifest" 2>/dev/null \
      | grep -q "VALIDSIG ${CLAUDE_GPG_FPR}"; then
    rm -rf -- "$gnupg"
    die "Claude Code: podpis GPG manifestu NIEPOPRAWNY — przerywam"
  fi
  rm -rf -- "$gnupg"
  ok "podpis GPG manifestu poprawny (klucz ${CLAUDE_GPG_FPR:0:8}...)"
}

claude_install() {
  local action="$1" ver plat manifest sig keyfile checksum bin_url bin_dl dest old
  ver="$(claude_remote_version)" \
    || die "Claude Code: nie mogę ustalić wersji do instalacji (szczegóły wyżej)"
  plat="$(claude_platform)"
  need_cmd jq "apt install jq"

  info "Claude Code ${ver} (${plat}), kanał: ${CLAUDE_CHANNEL:-stable}"
  manifest="$DL_DIR/claude-manifest-${ver}.json"
  sig="$DL_DIR/claude-manifest-${ver}.json.sig"
  keyfile="$DL_DIR/claude-code-signing.asc"
  download "$CLAUDE_DL_BASE/$ver/manifest.json" "$manifest"
  download "$CLAUDE_DL_BASE/$ver/manifest.json.sig" "$sig"
  download "$CLAUDE_KEY_URL" "$keyfile"
  _claude_verify_manifest "$manifest" "$sig" "$keyfile"

  checksum="$(jq -r --arg p "$plat" '.platforms[$p].checksum // empty' "$manifest")"
  [[ "$checksum" =~ ^[a-f0-9]{64}$ ]] \
    || die "Claude Code: brak sumy dla platformy ${plat} w manifeście"

  bin_url="$CLAUDE_DL_BASE/$ver/$plat/claude"
  bin_dl="$DL_DIR/claude-${ver}-${plat}"
  download "$bin_url" "$bin_dl"
  sha256_verify "$bin_dl" "$checksum"

  dest="$WORK6/tools/claude/versions/$ver"
  ensure_dir "$dest" 0700
  install -m 0755 -- "$bin_dl" "$dest/claude"
  rm -f -- "$bin_dl"
  ln -sfn -- "$dest" "$WORK6/tools/claude/current"

  # Smoke test z HOME przekierowanym do work6 (żadnych śladów poza work6).
  HOME="$WORK6/home" CLAUDE_CONFIG_DIR="$WORK6/home/.claude" \
    "$dest/claude" --version >/dev/null \
    || die "Claude Code: binarka nie uruchamia się"
  ok "claude --version: $(HOME="$WORK6/home" CLAUDE_CONFIG_DIR="$WORK6/home/.claude" "$dest/claude" --version 2>/dev/null | head -n1)"

  # Ustawienia: wyłączony auto-update (aktualizacje tylko update-tools.sh).
  # Wymuszamy to TAKŻE gdy plik już istnieje — inaczej Claude Code
  # doaktualizowałby się sam i rozjechał z tym, co zweryfikowaliśmy
  # podpisem GPG. Reszta ustawień użytkownika zostaje nietknięta.
  ensure_dir "$WORK6/home/.claude" 0700
  local settings="$WORK6/home/.claude/settings.json" stmp
  if [ ! -f "$settings" ]; then
    cat >"$settings" <<EOF
{
  "autoUpdatesChannel": "${CLAUDE_CHANNEL:-stable}",
  "env": {
    "DISABLE_AUTOUPDATER": "1"
  }
}
EOF
    chmod 0600 "$settings"
  elif ! jq -e '.env.DISABLE_AUTOUPDATER == "1"' "$settings" >/dev/null 2>&1; then
    stmp="$(mktemp "${settings}.XXXXXX")"
    if jq '.env.DISABLE_AUTOUPDATER = "1"' "$settings" >"$stmp" 2>/dev/null; then
      chmod 0600 "$stmp"
      mv -- "$stmp" "$settings"
      ok "Claude Code: auto-updater wyłączony w istniejącym settings.json"
    else
      rm -f -- "$stmp"
      warn "Claude Code: settings.json nie jest poprawnym JSON — NIE mogę wyłączyć"
      warn "auto-updatera; popraw plik ręcznie: $settings"
    fi
  fi

  record_component claude "$ver" "$bin_url" "$checksum" "$action"

  for old in "$WORK6/tools/claude/versions"/*; do
    [ -d "$old" ] || continue
    [ "$old" = "$dest" ] && continue
    if confirm "Usunąć starą wersję Claude Code: $(basename "$old")?" tak; then
      rm -rf -- "$old"
    fi
  done
}
