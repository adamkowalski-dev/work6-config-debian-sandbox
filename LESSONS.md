# LESSONS — wiedza zebrana przy projektowaniu work6 (2026-07-16)

Fakty zweryfikowane w oficjalnych źródłach podczas projektowania tego
środowiska. Mogą się zdezaktualizować — przy każdej pozycji jest źródło,
sprawdzaj datę.

## Claude Code — dystrybucja i weryfikacja (2026-07)

- Oficjalny kanał to **natywna binarka** (nie npm; npm nadal wspierany,
  instaluje tę samą binarkę przez optional dependency per platforma).
- Bucket release'ów: `https://downloads.claude.ai/claude-code-releases`
  - `GET /stable` i `GET /latest` zwracają **czysty string wersji**
    (np. `2.1.204` — stan na 2026-07-16).
  - `GET /<ver>/manifest.json` — SHA-256 per platforma w
    `.platforms["linux-x64"].checksum`.
  - `GET /<ver>/manifest.json.sig` — **podpis GPG** manifestu; klucz:
    `https://downloads.claude.ai/keys/claude-code.asc`, fingerprint
    (pin!): `31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE`.
  - `GET /<ver>/<platforma>/claude` — binarka; platformy:
    `linux-x64`, `linux-arm64`, `-musl` warianty, `darwin-*`.
  - Podpisy manifestu istnieją od wersji `2.1.89`.
- Oficjalny `install.sh` robi dokładnie: resolve wersji → manifest →
  sha256 → pobranie binarki → `claude install [stable|latest|X.Y.Z]`.
  Można to odtworzyć bez `curl | bash` (tak robi `setup.d/40-claude.sh`).
- `claude install` tworzy launcher `~/.local/bin/claude` (symlink do
  `~/.local/share/claude/versions/<ver>`) — **nie jest konieczny**, sama
  binarka jest self-contained; wystarczy własny symlink.
- Config/tokeny: `~/.claude/` + `~/.claude.json`; przenosi się przez
  **`CLAUDE_CONFIG_DIR`**.
- Auto-update wyłącza `DISABLE_AUTOUPDATER=1` (env lub `settings.json`
  → `env`); kanał: `autoUpdatesChannel: stable|latest`; `DISABLE_UPDATES`
  blokuje też ręczne. Wymaga ~512 MB wolnego RAM przy instalacji.
- Tryby uprawnień (zweryfikowane w cli-reference, 2026-07):
  `--permission-mode default|acceptEdits|plan|auto|dontAsk|bypassPermissions`,
  `--dangerously-skip-permissions` ≡ `bypassPermissions`,
  `--allow-dangerously-skip-permissions` (dodaje tryb do cyklu Shift+Tab).
- Logowanie: `claude auth login` (URL + kod — działa headless),
  `claude setup-token` (długożyjący token do CI), `claude auth status`.
- Istnieją też podpisane repo `apt/dnf/apk`
  (`https://downloads.claude.ai/claude-code/apt/...`) — alternatywa
  systemowa, nieużyta tu celowo (chcemy wszystko w `work6`).
- npm package wymaga Node >= 22 (tylko do instalacji; binarka nie używa
  Node w runtime).

Źródła: <https://code.claude.com/docs/en/setup>,
<https://code.claude.com/docs/en/cli-reference>, treść
`claude.ai/install.sh` (pobrany i przeanalizowany 2026-07-16).

## Antigravity CLI (`agy`) — nowość, wydane po 2025 (2026-07)

- **Istnieje oficjalne CLI Google**: `agy`, TUI napisane w Go, osobne od
  IDE Antigravity. Repo: `github.com/google-antigravity/antigravity-cli`
  (release 1.1.3 z 2026-07-16). Docs:
  <https://antigravity.google/docs/cli-overview>.
- Oficjalny instalator: `curl -fsSL https://antigravity.google/cli/install.sh | bash`.
  Przeanalizowana treść instalatora (2026-07-16):
  - Manifest per platforma:
    `https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/<platforma>.json`
    gdzie platforma ∈ `linux_amd64`, `linux_arm64`, `*_musl`, `darwin_*`.
  - Manifest to JSON: `{version, url, sha512}` — weryfikacja **SHA-512**;
    payload bywa `tar.gz` (członek `antigravity`) albo goła binarka.
  - Instaluje do `~/.local/bin/agy`; brak flagi pinowania wersji
    (zawsze latest z manifestu); `-d/--dir` zmienia katalog docelowy.
  - Brak podpisu GPG — tylko sumy z manifestu (HTTPS trust).
- **`agy` self-update'uje się w tle podczas normalnych uruchomień** —
  instalator mówi o tym wprost. Konsekwencja: pin wersji jest miękki,
  `versions.env` może dryfować; doctor powinien porównywać
  `agy --version` z zapisem. Brak udokumentowanej opcji wyłączenia
  (stan na 2026-07-16) — sprawdzać `agy --help`.
- Logowanie: system keyring → fallback Google Sign-In w przeglądarce;
  **w sesji SSH/headless wykrywa to i drukuje URL** do autoryzacji na
  innym urządzeniu — to samo zachowanie ratuje nas w sandboxie bwrap
  (brak keyringa/D-Bus → ścieżka „SSH"). Wylogowanie: `/logout` w TUI.
- Flagi autonomii (zweryfikowane 2026-07-23,
  <https://antigravity.google/docs/cli/using>): **`--dangerously-skip-permissions`**
  auto-akceptuje wszystkie żądania uprawnień na starcie (odpowiednik
  „YOLO"/no-confirmation; dokładnie ta sama nazwa co w Claude Code), oraz
  **`--sandbox`** (własny preset „proceed-in-sandbox" agy). U nas bypass =
  `--dangerously-skip-permissions`, sterowane `AGY_MAX_MODE` w install.env
  (jak `CLAUDE_MAX_MODE`); `--sandbox` agy nie używamy — izolację daje bwrap.
- Czyta `AGENTS.md` (konwencja Antigravity/Gemini), nie `CLAUDE.md`.

## Debian 13 (trixie) — bwrap i user namespaces

- Debian 13 (stable od 2025-08) **ogranicza unprivileged user
  namespaces przez AppArmor** (analogicznie do Ubuntu 24.04:
  `kernel.apparmor_restrict_unprivileged_userns=1`).
- Pakiet `bubblewrap` z apt **zawiera profil AppArmor**, który pozwala
  `bwrap` tworzyć userns mimo restrykcji → **instalować bwrap tylko
  z apt**, nie z ręcznie zbudowanej binarki. Po instalacji warto
  przetestować: `bwrap --unshare-user ... /usr/bin/true`.
- Typowy błąd przy restrykcji: `bwrap: setting up uid map: Permission
  denied` albo śmierć od SIGTRAP. Naprawa: `apt install --reinstall
  bubblewrap` (wgrywa profil), NIE wyłączać sysctl globalnie.
- Debian 12+ ma merged-usr: `/bin`, `/sbin`, `/lib`, `/lib64` to
  symlinki do `/usr/*` → w sandboxie wystarczy `--ro-bind /usr /usr`
  + `--symlink usr/bin /bin` itd. Nie bindować `/` ani realnych
  `/bin`, `/lib`.
- **`/etc/alternatives` jest krytyczne**: `awk`, `editor`, `pager` itd.
  w `/usr/bin` to symlinki przez `/etc/alternatives/*` — bez tego
  ro-bindu w sandboxie „znika" nawet awk.
- Domyślne uprawnienia nowych HOME na Debianie 12+: `0700`
  (`DIR_MODE` w adduser.conf) — ale sprawdzać istniejące konta
  założone wcześniej.
- Chromium **wewnątrz** bwrap: jego wewnętrzny sandbox potrzebuje
  zagnieżdżonych userns; pod restrykcją AppArmor może być zablokowany.
  Obejście per projekt Playwright: `launchOptions: { chromiumSandbox:
  false }` — akceptowalne, bo zewnętrzną izolację daje bwrap.

## Node.js — kalendarz (2026-07)

- Active LTS: **24.x** (EOL 2028-04-30). Maintenance: 22.x (EOL
  2027-04-30). Current: 26.x → zostaje LTS w **październiku 2026**.
- Od października 2026 zmiana modelu wydań: jeden major rocznie,
  numeracja zgodna z rokiem, każde wydanie LTS, kanał Alpha.
- Pobrania: `https://nodejs.org/dist/index.json` (posortowane od
  najnowszych; pole `lts` = false albo nazwa linii) +
  `https://nodejs.org/dist/<ver>/SHASUMS256.txt` — oficjalny manifest
  sum; weryfikować zamiast ufać samemu TLS.

## Playwright

- `PLAYWRIGHT_BROWSERS_PATH` przenosi binaria przeglądarek (musi być
  ustawione i przy `install`, i przy każdym uruchomieniu testów).
  `=0` → instalacja hermetyczna w `node_modules`.
- `npx playwright install-deps` wymaga roota (woła apt-get); istnieje
  wariant `--dry-run` drukujący komendę — ale traktować jego output
  jako dane niezaufane, root ma instalować wyłącznie zwalidowane nazwy
  pakietów, nigdy nie wykonywać wyklejonego stringa.
- Nagłówkowe (headed) przeglądarki wymagają X/Wayland — w sandboxie
  tylko przez jawne przekazanie socketów WŁASNEJ sesji agenta.

## VS Code / VSCodium — portable

- VSCodium publikuje na GitHub Releases assety + pliki `.sha256` —
  łatwa weryfikacja. VS Code (MS) tarball z
  `update.code.visualstudio.com/latest/linux-x64/stable` **nie ma
  publikowanych sum** — stąd rekomendacja VSCodium.
- Portable Mode (tarball): katalog `data/` obok binarki trzyma
  ustawienia+rozszerzenia+cache; przy aktualizacji podmienia się
  katalog aplikacji, a `data/` przenosi (u nas: `data` to symlink do
  wspólnego katalogu poza katalogiem wersji).
- `--install-extension` działa headless (bez X).

## Flutter

- Oficjalny manifest z sumami:
  `https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json`
  (`current_release.stable` → hash → wpis z `archive` i `sha256`).
- Brak oficjalnego SDK linux-arm64 (stan 2026-07).
- `PUB_CACHE` przenosi cache puba; SDK aktualizuje się sam przez
  `flutter upgrade` (git).
- Desktop Linux wymaga: clang, cmake, ninja-build, pkg-config,
  libgtk-3-dev (apt → krok administratora).

## Wzorce, które się tu sprawdziły

- **Zamiast `curl | bash`**: pobrać instalator do pliku i przeczytać,
  a najlepiej odtworzyć jego logikę (resolve wersji → manifest →
  suma → binarka) we własnym, idempotentnym module.
- Sekrety a logi: launchery agentów NIE logują treści sesji (OAuth
  URL-e i kody lecą tylko na terminal); logowane są wyłącznie
  metadane startu.
- Root nigdy nie wykonuje niczego wygenerowanego przez konto agenta;
  co najwyżej czyta listę nazw pakietów przez whitelist-regex
  `^[a-z0-9][a-z0-9+.-]*$` i sam składa komendę apt.
- bwrap: `--clearenv` + jawna lista env; `--tmpfs /run` + własny
  `/run/user/<uid>` (`--perms 0700 --dir`); fałszywe minimalne
  `/etc/passwd` i `/etc/group` generowane per start (nie bindować
  hostowych — wyciekają listę użytkowników).
