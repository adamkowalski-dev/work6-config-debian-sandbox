# work6 — odizolowane środowisko agentów AI na Debianie

Kompletne, lokalne środowisko dla **Claude Code CLI**, **Antigravity CLI
(agy)**, **Playwrighta**, opcjonalnie **Fluttera** i **VS Code/VSCodium
(portable)** — uruchamiane wyłącznie jako dedykowany użytkownik Linux
(domyślnie `ai-agent`), w sandboxie **bubblewrap**, z całością danych w
`/home/ai-agent/work6`.

Konfigurację wybierasz **kreatorem na docelowym systemie** — skrypt
`setup-work6.sh` pyta o komponenty i tryby, a przy kolejnych
uruchomieniach proponuje per komponent: zachowaj / zaktualizuj /
napraw / pomiń.

## 1. Model zagrożeń — co to daje, a czego NIE

Chronimy **administratora przed agentem**: agent (i wszystko, co
uruchomi) nie ma dostępu do Twojego konta, `~/.ssh`, `~/.gnupg`,
przeglądarek, cookies, sesji, tokenów, socketów (`SSH_AUTH_SOCK`,
Docker, D-Bus) ani `/run/user/<twój-uid>`.

Warstwy: **(1)** osobny użytkownik Linux bez grup uprzywilejowanych,
**(2)** sandbox bwrap na każdy start CLI: `--clearenv`, unshare
user/pid/ipc/uts, prywatne `/proc`, `/dev`, `/tmp`, `/run`, system
tylko-RO (`/usr` + minimalne `/etc`), zapis wyłącznie w podkatalogach
`work6`, **(3)** wszystkie tokeny/configi/cache w `work6` (0700/0600).

**Czego bwrap NIE gwarantuje:** współdzieli jądro z hostem — exploit
kernelowy ucieka z sandboxa; to nie jest maszyna wirtualna. Sieć jest
domyślnie współdzielona (agent „widzi" LAN) — do pracy bez sieci służy
`agent-shell-offline`. Aplikacje **graficzne** (przeglądarka OAuth,
VSCodium, headed testy) działają poza bwrap — nadal na koncie agenta
i na danych w `work6`, ale bez warstwy (2). Wewnątrz konta agenta
izolacji między narzędziami nie ma: to jeden użytkownik.

Backupy (`backups/`) i `downloads/`, `logs/`, `bin/`, `lib/`,
`scripts/` są **niewidoczne z sandboxa** — agent nie zmanipuluje kopii
zapasowych ani launcherów.

## 2. Struktura katalogów

```text
/home/ai-agent/work6/
├── bin/              # launchery (agent-shell, run-claude, ...)
├── home/             # HOME wewnątrz sandboxa (tokeny CLI: home/.claude itd.)
├── cache/            # npm, pip, pub
├── config/           # install.env, sandbox.env, versions.env, npmrc
├── tmp/              # TMPDIR środowiska
├── logs/             # logi setup/update/doctor + metadane startów
├── tools/            # claude/, agy/, flutter/, vscode/ (wersjonowane)
├── npm-global/       # npm prefix (playwright itd.)
├── node/             # lokalny Node LTS (node/current → wersja)
├── python/           # venv
├── projects/         # JEDYNE miejsce na kod (w sandboxie też /workspace)
├── browsers/         # binaria Playwrighta (PLAYWRIGHT_BROWSERS_PATH)
├── browser-profile/  # profil Chromium wyłącznie do OAuth
├── scripts/          # activate, update-tools, backup, restore, doctor, new-project
├── backups/          # archiwa konfiguracji (poza sandboxem)
├── downloads/        # pobrania instalatora (poza sandboxem)
├── runtime/          # pliki generowane na start sandboxa
├── setup.d/          # moduły instalacyjne (używane też przez update-tools)
├── lib/              # common.sh, sandbox.sh, env.sh
└── state/            # manifest.tsv, admin-todo.pkgs, XDG_STATE_HOME
```

## 3. Twoje konto vs `ai-agent`

| | Twoje konto (admin) | `ai-agent` |
|---|---|---|
| rola | administracja, `sudo`, prywatne dane | wyłącznie praca agentów |
| grupy | jak dotąd | **żadnych** uprzywilejowanych |
| sekrety | Twoje SSH/GPG/przeglądarki | tylko tokeny kont automatyzacyjnych, w `work6` |
| uruchamia | `prepare-system.sh` (sudo) | `setup-work6.sh`, launchery, skrypty |

Przełączanie: `sudo -iu ai-agent` (pełny login shell, bez zmiennych
Twojej sesji). **Nie używaj** `sudo -u ai-agent <gui>` bez `-i` —
launchery GUI i tak odmówią pracy na cudzej sesji.

## 4. Jednorazowe przygotowanie systemu (administrator)

```bash
sudo ./prepare-system.sh
```

Skrypt (wszystko za potwierdzeniem): wykrywa Debiana i architekturę;
instaluje minimalny zestaw APT (`bubblewrap ca-certificates curl wget
git tar xz-utils gnupg jq unzip zip rsync file procps`, opcjonalnie
`python3*` i `chromium`); tworzy/weryfikuje użytkownika agenta (pokazuje
UID/HOME/grupy, ostrzega o grupach uprzywilejowanych); sprawdza
uprawnienia katalogów domowych (proponuje `o-rwx`); testuje bwrap pod
restrykcją userns/AppArmor Debiana 13; sprawdza dysk; kopiuje ten
katalog do `~ai-agent/work6-config`.

## 5. Utworzenie / wybór użytkownika agenta

Domyślna nazwa: `ai-agent` (zmiana: edytuj `AGENT_USER` w
`config/install.env` **przed** `prepare-system.sh`, albo uruchom
`sudo ./prepare-system.sh --user inna-nazwa`). Jeśli użytkownik
istnieje — zostanie pokazany i sprawdzony; jeśli nie — skrypt zapyta,
czy go utworzyć (`adduser`, bez hasła, bez dodatkowych grup). Hasło —
potrzebne wyłącznie do logowania w sesję graficzną — ustawiasz sam:
`sudo passwd ai-agent`.

## 6. Pierwsza instalacja (jako `ai-agent`)

```bash
sudo -iu ai-agent
cd ~/work6-config
./setup-work6.sh
```

Kreator zapyta o: komponenty (Node/Python/Claude/agy/Playwright/
Flutter/VS Code), politykę wersji Node (pin 24.x ↔ follow-LTS), kanał
i **tryb autonomii** Claude (default/acceptEdits/bypass — zawsze tylko
w sandboxie), silniki Playwrighta, kanał+targety Fluttera,
VSCodium↔VS Code + rozszerzenia, wariant OAuth/GUI. Potem: preflight
(czego brakuje w systemie — dokładna lista dla administratora),
pobrania **z weryfikacją sum/podpisów** (Claude Code: manifest
podpisany GPG, pinowany fingerprint; Node: SHASUMS256; agy: SHA-512
z manifestu; Flutter: SHA-256; VSCodium: `.sha256`), synchronizacja
launcherów, zapis wersji do `config/versions.env` i
`state/manifest.tsv`.

Jeśli setup zgłosi zależności systemowe (Playwright/Flutter desktop):

```bash
# jako administrator:
sudo ~ai-agent/work6-config/prepare-system.sh --stage2
```

Ponowne uruchomienie `setup-work6.sh` niczego nie niszczy: dla
zainstalowanych komponentów wybierasz zachowaj/zaktualizuj/napraw/pomiń.
Przydatne flagi: `--reconfigure` (kreator od nowa), `--only claude`
(jeden moduł), `--yes` (bez pytań, wg zapisanej konfiguracji).

## 7. Codzienne uruchamianie

```bash
sudo -iu ai-agent
~/work6/bin/agent-shell                       # powłoka w sandboxie (projekt: projects/)
~/work6/bin/agent-shell --workspace mojapka   # konkretny projekt
~/work6/bin/run-claude  --workspace mojapka   # Claude Code w sandboxie
~/work6/bin/run-agy     --workspace mojapka   # Antigravity CLI w sandboxie
~/work6/bin/run-playwright --workspace mojapka test
~/work6/bin/run-flutter --workspace mojapka pub get
~/work6/bin/run-vscode                        # edytor (sesja graficzna agenta)
~/work6/bin/agent-shell-offline               # sandbox BEZ sieci
```

Każdy launcher sprawdza: użytkownik = `ai-agent`, nie-root, właściciela
katalogów, obecność binarki i działanie sandboxa — inaczej kończy pracę
z podpowiedzią (`sudo -iu ai-agent ...`).

Tryb autonomii Claude: domyślnie ten z kreatora (`CLAUDE_MAX_MODE`).
Jednorazowe obniżenie: `AGENT_CLAUDE_MODE=default ~/work6/bin/run-claude`.
Podniesienie powyżej maksimum jest blokowane. Dla `agy` flag autonomii
nie dokładamy (brak w dokumentacji 2026-07) — sprawdź `run-agy --help`.

Do ręcznej pracy poza sandboxem (npm/pip/git we własnej powłoce):
`source ~/work6/scripts/activate.sh` — ustawia PATH/zmienne, nie
zmienia HOME i nie dotyka plików startowych powłoki.

## 8. Logowanie OAuth — bezpiecznie

**Zawsze konta przeznaczone dla automatyzacji** (osobne konto
Google/GitHub; przy Anthropic pamiętaj, że Claude Code wymaga płatnego
planu — decyzja kosztowa). Nigdy nie loguj w profilu agenta swoich
głównych kont i nigdy nie używaj swojej przeglądarki/profilu.

Wariant A — `desktop-session` (osobna sesja pulpitu agenta):

1. Zaloguj się na ekranie logowania jako `ai-agent`.
2. W terminalu: `~/work6/bin/run-claude` → w sesji `/login`
   (lub `claude auth login`); `~/work6/bin/run-agy` → agy wykryje brak
   przeglądarki (środowisko jak SSH) i wypisze URL autoryzacji.
3. URL otwórz przez `~/work6/bin/open-agent-browser '<URL>'` —
   dedykowany Chromium z profilem `work6/browser-profile`
   (`--no-first-run`, bez keyringa, zero importu czegokolwiek).
4. Kod potwierdzenia przepisz do CLI.

Wariant B — `headless-remote` / `shared-gui` (bez sesji agenta):
URL z CLI otwierasz w **dedykowanym profilu** przeglądarki na innym
urządzeniu (np. Twoim laptopie), zalogowanym na konto automatyzacyjne;
kod wracasz do CLI. Niczego nie przekazujemy z Twojej sesji: launchery
nie używają `xdg-open`, nie dotykają `$DISPLAY`/`$XAUTHORITY`/D-Bus
Twojej sesji i odmówią użycia cudzych socketów.

Tokeny lądują wyłącznie w `work6/home` (np. `home/.claude/`). GitHub:
najlepiej **fine-grained PAT** ograniczony do konkretnych repozytoriów,
podawany gitowi per repozytorium; nigdy nie wpisuj tokenów do skryptów,
konfigów globalnych ani logów.

## 9. Projekty i Git

```bash
~/work6/scripts/new-project.sh mojapka --git --branch
```

Tworzy `projects/mojapka`, `git init -b main`, tożsamość **tylko
lokalną** (per repo), startowy `.gitignore` (m.in. `.env`), opcjonalny
branch `agent/<data>-mojapka`. Żadnych auto-commitów, auto-push ani
globalnej konfiguracji gita. Przed merge/push: `git diff`, testy,
Twoja ręczna akceptacja. Zapis kodu tylko w `projects/` (w sandboxie
widocznym też jako `/workspace`).

## 10. Aktualizacje

```bash
~/work6/scripts/update-tools.sh            # wszystkie włączone komponenty
~/work6/scripts/update-tools.sh claude agy # wybrane
```

Pokazuje plan (obecna → dostępna), pyta, robi backup konfiguracji,
aktualizuje **z tą samą weryfikacją co instalacja**, na końcu odpala
`doctor.sh --quick`. Node trzyma się polityki z kreatora (pin 24.x /
follow-LTS — uwaga: w 10.2026 Active LTS zmienia się na 26). Claude ma
wyłączony auto-updater (aktualizujesz świadomie); **agy self-update'uje
się sam w tle** — doctor raportuje dryf wersji względem manifestu.
Pakiety systemowe: nigdy stąd — tylko `prepare-system.sh`.

## 11. Backup i restore

```bash
~/work6/scripts/backup-config.sh
~/work6/scripts/restore-config.sh ~/work6/backups/work6-config-<data>.tar.gz
```

Backup = **jawna lista**: `config/*.env`, `npmrc`, manifesty, ustawienia
Claude (`settings.json`, `CLAUDE.md`) + wygenerowany spis wersji.
**Nigdy**: tokeny/sesje OAuth, profil przeglądarki, projekty, pliki
`.env`. Restore pokazuje zawartość, pyta per plik i odrzuca ścieżki
spoza listy. Szyfrowania nie implementujemy — w razie potrzeby
zaszyfruj archiwum samodzielnie (`age`/`gpg`).

## 12. Diagnostyka

```bash
~/work6/scripts/doctor.sh          # pełna (kod wyjścia 1 przy problemach krytycznych)
~/work6/scripts/doctor.sh --quick  # bez wolnych testów
```

Sprawdza m.in.: użytkownika i uprawnienia (0700/0600), komponenty
i wersje, npm prefix/cache w `work6`, start sandboxa (z siecią i bez)
oraz **test szczelności wewnątrz bwrap** (brak `SSH_AUTH_SOCK`/D-Bus/
docker.sock, niewidoczność cudzych `/home` i `/run/user`, poprawne
`HOME`/`TMPDIR`/`PLAYWRIGHT_BROWSERS_PATH`, `/usr` tylko-RO,
zapisywalny `/workspace`), wolne miejsce, ostrzeżenia o poszerzeniach
(`SANDBOX_ALLOW_DISPLAY`, `SANDBOX_EXTRA_RO_BINDS`).

## 13. Kolejny agent (inne narzędzie CLI)

1. Zainstaluj narzędzie **w `work6`** (np. `npm install -g <cli>` po
   `source scripts/activate.sh` → trafi do `npm-global/`; albo nowy
   moduł `setup.d/55-nazwa.sh` na wzór `50-agy.sh` — zyskujesz
   weryfikację sum i wpis w `update-tools`).
2. Launcher: skopiuj `bin/run-agy` jako `bin/run-<nazwa>`, podmień
   ścieżkę binarki — sandbox i guardy dostajesz gratis.
3. `doctor.sh` + logowanie OAuth jak w sekcji 8.

## 14. Typowe błędy

| Objaw | Przyczyna → rozwiązanie |
|---|---|
| `bwrap: setting up uid map: Permission denied` / sandbox nie startuje | restrykcja userns (AppArmor, Debian 13) → `sudo apt install --reinstall bubblewrap`; test: `prepare-system.sh` sekcja 5; nie wyłączaj sysctl globalnie |
| `to polecenie działa wyłącznie jako 'ai-agent'` | jesteś na swoim koncie → `sudo -iu ai-agent` |
| `XDG_RUNTIME_DIR nie należy do...` przy GUI | użyłeś `sudo -u` z własnej sesji → zaloguj się w sesję agenta (ekran logowania) |
| CLI nie widzi sieci w sandboxie | użyłeś `agent-shell-offline`, albo brak `/etc/resolv.conf` na hoście → sprawdź `doctor.sh` |
| Playwright: błędy bibliotek przy starcie przeglądarki | brak zależności systemowych → `sudo .../prepare-system.sh --stage2` |
| Chromium w sandboxie: błąd wewnętrznego sandboxa | zagnieżdżone userns zablokowane → w projekcie Playwrighta `launchOptions: { chromiumSandbox: false }` (zewnętrzną izolację daje bwrap) |
| `claude` prosi o login mimo logowania | logowałeś się poza sandboxem (inne HOME) → zawsze przez `run-claude` |
| agy ma inną wersję niż w `versions.env` | wbudowany self-update → `update-tools.sh agy` odświeży zapis |
| `może zabraknąć miejsca` | Flutter/przeglądarki są duże → zwolnij miejsce albo odchudź wybór w `--reconfigure` |

## 15. Całkowite usunięcie środowiska

Nie dotyka to Twojego konta ani systemu poza wymienionymi elementami:

```bash
# 1. (agent) — nic nie musi być uruchomione; sprawdź, że nie działają procesy:
pgrep -u ai-agent && echo "coś działa — pozamykaj"

# 2. (admin) usuń środowisko i pliki instalacyjne:
sudo rm -rf ~ai-agent/work6 ~ai-agent/work6-config

# 3. (admin, opcjonalnie) usuń użytkownika wraz z HOME:
sudo deluser --remove-home ai-agent

# 4. (admin, opcjonalnie) pakiety instalowane dla work6 — usuń tylko te,
#    których nie używasz gdzie indziej:
sudo apt purge bubblewrap chromium   # + zależności Playwrighta wg stage2
```

Tokeny/sesje agenta żyły wyłącznie w `work6` — po kroku 2 nie ma ich
na dysku (konta w usługach unieważnij w ich panelach).

---

*Wiedza projektowa i źródła weryfikacji: `LESSONS.md`. Konfiguracja:
`config/install.env` (przełączniki), `config/sandbox.env` (pokrętła
sandboxa — lista mountów celowo w `lib/sandbox.sh`).*
