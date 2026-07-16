# shellcheck shell=bash
# ============================================================================
# Moduł: Flutter SDK — tarball z oficjalnego manifestu release'ów
# (releases_linux.json zawiera SHA-256), SDK i cały cache w work6.
#   * PUB_CACHE=work6/cache/pub (środowisko work6),
#   * aktualizacje: `flutter upgrade` (mechanizm własny SDK, git),
#   * Android: TYLKO wykrycie istniejącego SDK — niczego nie instalujemy,
#   * target linux: brakujące narzędzia budowania zgłaszane do
#     state/admin-todo.pkgs (instaluje administrator w stage2).
# ============================================================================

MODULE_LIST+=("flutter")

FLUTTER_RELEASES_URL="https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json"

flutter_enabled() { is_yes "$INSTALL_FLUTTER"; }

_flutter_bin() { printf '%s' "$WORK6/tools/flutter/flutter/bin/flutter"; }

flutter_installed_version() {
  [ -x "$(_flutter_bin)" ] || return 0
  read_kv "$VERSIONS_FILE" FLUTTER_VERSION
}

_FLUTTER_RELEASES_JSON=""
_flutter_releases() {
  if [ -z "$_FLUTTER_RELEASES_JSON" ]; then
    _FLUTTER_RELEASES_JSON="$(download_stdout "$FLUTTER_RELEASES_URL")"
  fi
  printf '%s' "$_FLUTTER_RELEASES_JSON"
}

flutter_remote_version() {
  need_cmd jq "apt install jq"
  _flutter_releases | jq -r --arg ch "${FLUTTER_CHANNEL:-stable}" \
    '. as $r | $r.current_release[$ch] as $h
     | [$r.releases[] | select(.hash == $h and .channel == $ch)][0].version // empty'
}

_flutter_report_linux_deps() {
  local -a miss=()
  command -v clang >/dev/null 2>&1 || miss+=(clang)
  command -v cmake >/dev/null 2>&1 || miss+=(cmake)
  command -v ninja >/dev/null 2>&1 || miss+=(ninja-build)
  command -v pkg-config >/dev/null 2>&1 || miss+=(pkg-config)
  pkg-config --exists gtk+-3.0 2>/dev/null || miss+=(libgtk-3-dev)
  if [ "${#miss[@]}" -gt 0 ]; then
    {
      echo "# flutter linux desktop — $(timestamp)"
      echo "${miss[*]}"
    } >>"$ADMIN_TODO"
    chmod 0600 "$ADMIN_TODO"
    warn "target linux wymaga pakietów: ${miss[*]} — zgłoszono do $ADMIN_TODO (stage2)"
  fi
}

flutter_install() {
  local action="$1" ver archive sha base_url url tarball tgt
  [ "$(uname -m)" = "x86_64" ] \
    || die "Flutter: oficjalne SDK Linux istnieje tylko dla x86_64"
  need_cmd git "apt install git (Flutter wymaga gita)"
  need_cmd jq "apt install jq"
  tgt="$WORK6/tools/flutter"

  if [ "$action" = "update" ] && [ -x "$(_flutter_bin)" ]; then
    info "flutter upgrade (kanał: ${FLUTTER_CHANNEL:-stable})"
    "$(_flutter_bin)" upgrade
  else
    ver="$(flutter_remote_version)"
    [ -n "$ver" ] || die "Flutter: nie mogę ustalić wersji dla kanału ${FLUTTER_CHANNEL}"
    read -r archive sha < <(_flutter_releases | jq -r \
      --arg ch "${FLUTTER_CHANNEL:-stable}" \
      '. as $r | $r.current_release[$ch] as $h
       | [$r.releases[] | select(.hash == $h and .channel == $ch)][0]
       | "\(.archive) \(.sha256)"')
    base_url="$(_flutter_releases | jq -r '.base_url')"
    [ -n "$archive" ] && [ -n "$sha" ] && [ -n "$base_url" ] \
      || die "Flutter: niekompletny manifest release'ów"
    url="${base_url}/${archive}"
    tarball="$DL_DIR/$(basename "$archive")"

    info "Flutter ${ver} (${FLUTTER_CHANNEL:-stable}) — pobieram (~1 GB, chwilę potrwa)"
    download "$url" "$tarball"
    sha256_verify "$tarball" "$sha"

    if [ -d "$tgt/flutter" ]; then
      warn "usuwam poprzednią kopię SDK ($tgt/flutter) — akcja: $action"
      rm -rf -- "$tgt/flutter"
    fi
    ensure_dir "$tgt" 0700
    tar -xf "$tarball" -C "$tgt"
    rm -f -- "$tarball"
    [ -x "$(_flutter_bin)" ] || die "Flutter: rozpakowanie nie powiodło się"
  fi

  "$(_flutter_bin)" config --no-analytics >/dev/null 2>&1 || true

  local t precache_flags=()
  for t in ${FLUTTER_TARGETS:-linux web}; do
    case "$t" in
      linux)   precache_flags+=(--linux); _flutter_report_linux_deps ;;
      web)     precache_flags+=(--web) ;;
      android)
        if [ -n "${ANDROID_HOME:-}" ] || [ -d "$WORK6/tools/android-sdk" ]; then
          precache_flags+=(--android)
        else
          warn "target android: nie znaleziono Android SDK — pomijam (patrz README)"
        fi
        ;;
      *) warn "Flutter: nieznany target '$t' — pomijam" ;;
    esac
  done
  if [ "${#precache_flags[@]}" -gt 0 ]; then
    info "flutter precache ${precache_flags[*]}"
    "$(_flutter_bin)" precache "${precache_flags[@]}"
  fi

  ver="$("$(_flutter_bin)" --version 2>/dev/null | head -n1 | awk '{print $2}')"
  ok "Flutter ${ver}"
  record_component flutter "$ver" "$FLUTTER_RELEASES_URL (kanał ${FLUTTER_CHANNEL:-stable})" "${sha:--}" "$action"
}
