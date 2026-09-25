# Changelog

Format wg [Keep a Changelog](https://keepachangelog.com/pl/1.1.0/),
wersjonowanie [SemVer](https://semver.org/lang/pl/): MAJOR = zmiana
łamiąca układ work6/konfigurację, MINOR = nowa funkcja, PATCH = fix.
Każdy PR dopisuje wpis do sekcji [Unreleased]; przy wydaniu sekcja
dostaje numer i datę, a commit merge - tag `vX.Y.Z`.

## [Unreleased]

### Dodane

- `scripts/share-with-user.sh` + flaga `SHARE_WITH_USER`/`SHARE_MODE`
  w kreatorze `setup-work6.sh` — ACL (POSIX, `setfacl`) otwierające
  `$WORK6` do odczytu/zapisu dla wskazanego konta hosta (np. operatora
  logującego się na maszynę), bez zmiany izolacji sandboxa w drugą
  stronę. Odświeżane automatycznie po każdym `setup-work6.sh`, bo
  `ensure_tree()` resetuje maskę ACL zwykłym `chmod`. Zweryfikowane
  w kontenerze Debian 13.

### Naprawione

- `scripts/share-with-user.sh`: jeden plik, na którym `setfacl` zwraca
  błąd (np. luźny obiekt gita zhardlinkowany do innego właściciela przy
  lokalnym `git clone`), nie przerywa już całej pętli po drzewie
  `$WORK6` — reszta katalogów dostaje ACL, a skrypt na końcu podsumowuje
  ścieżki, które się nie udały, zamiast umierać w połowie.
- `update-tools.sh` odświeża zapis wersji w `versions.env`, gdy binarka
  zgadza się ze źródłem, a ewidencja nie (np. ślad po self-update agy
  sprzed blokady RO) - wcześniej podpowiedź z doctora nie działała bez
  `--force`.

## [1.0.0] - 2026-09-02

Pierwsza wersjonowana odsłona - stan po audycie bezpieczeństwa
i uruchomieniu produkcyjnym na Dellu (Debian 13).

### Dodane

- Instalator `install.sh` i modularny setup (`setup.d/`): Node, Python,
  Claude Code (GPG, pin fingerprinta), agy (SHA-512), Playwright,
  Flutter, VSCodium - wszystko z weryfikacją sum/podpisów (PR #1).
- Sandbox bwrap na każdy start CLI: `--clearenv`, unshare, system RO,
  zapis tylko w podkatalogach work6.
- Tryby autonomii z capem: `CLAUDE_MAX_MODE` / `AGY_MAX_MODE`,
  jednorazowe obniżenie `AGENT_*_MODE`, egzekwowanie na surowych
  flagach CLI (PR #4).
- `scripts/doctor.sh`: diagnostyka + test szczelności wewnątrz bwrap,
  wykrywanie dryfu work6 vs repo (PR #3), autonaprawa trybów
  0700/0600 i odziedziczonego setgid (PR #8).
- `scripts/update-tools.sh` z `--check`, semver i jawnymi powodami
  pominięć (PR #2).
- `scripts/pre-uninstall-report.sh` - raport tylko-do-odczytu przed
  ręcznym usunięciem środowiska (PR #5).
- `scripts/ssh/activate.sh` / `deactivate.sh` - włączanie SSH na
  Dellu z backupem, pre-stanem i odpornością na przerwanie (PR #6).
- `prepare-system.sh`: opcjonalne `ripgrep`/`fd-find` dla agenta
  (PR #5); `scripts/enable-agent-path.sh` (opt-in PATH).
- `UPDATE.md` - ściąga kolejności aktualizacji (PR #7).

### Naprawione

- KRYTYCZNE: `config/` i `tools/` w sandboxie tylko-RO (wcześniej
  agent mógł nadpisać własne uprawnienia na następną sesję i podmienić
  binarki claude/agy); `XDG_CONFIG_HOME` przeniesione do
  `home/.config` (PR #4).
- Rekurencyjny sync i drift-check (`rsync --delete`) - podkatalogi
  typu `scripts/ssh` przestały być niewidzialne (PR #3, #4).
- Walidacja archiwum w `restore-config.sh` PRZED ekstrakcją;
  `--proto-redir '=https'` w pobraniach (PR #4).
- `update-tools.sh` padał, gdy była dostępna aktualizacja
  (`semver_cmp` pod `set -e`) (PR #9).

[Unreleased]: https://github.com/adamkowalski-dev/work6-config-debian-sandbox/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/adamkowalski-dev/work6-config-debian-sandbox/releases/tag/v1.0.0
