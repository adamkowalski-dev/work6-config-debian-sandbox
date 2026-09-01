# Migracja ustawień Claude Code: macOS → Dell (Debian 13, ai-agent)

Notatka robocza. Cel: przenieść z tego macOS na Della z Debianem 13
(użytkownik sandboxu `ai-agent`, środowisko `work6`) trzy rzeczy:
pasek statusu, `CLAUDE.md`, skill `skill-kb-archiver`. Reszta skilli
(cloudflare, wrangler...) - nie kopiować, instalować przez plugin
marketplace na miejscu.

Cel: 192.168.1.62.

## 0. Włączenie SSH na Dellu

Wykonać **bezpośrednio na Dellu** (klawiatura/monitor albo już
istniejący zdalny dostęp) - nie da się tego zrobić przez SSH, skoro
SSH jeszcze nie działa.

Sformalizowane w skryptach `scripts/ssh/activate.sh` /
`scripts/ssh/deactivate.sh` (w tym repo) - patrz sekcja 0a. Poniżej
zostaje wersja ręczna jako odniesienie/awaryjna.

```bash
# sprawdź, czy serwer SSH jest już zainstalowany i działa
systemctl status ssh

# jeśli nie ma / nieaktywny - zainstaluj i włącz
sudo apt update
sudo apt install -y openssh-server
sudo systemctl enable --now ssh

# sprawdź, że nasłuchuje
sudo systemctl status ssh
ss -tlnp | grep :22
```

Firewall (jeśli `ufw` aktywny):

```bash
sudo ufw status
sudo ufw allow ssh
```

Na tym Dellu ani `ufw`, ani `iptables` nie są zainstalowane (czysty,
minimalny Debian) - brak firewalla blokującego ruch, krok pomijamy.

### Ochrona przed brute-force - fail2ban

Zamiast firewalla, ochrona przed błędnymi próbami logowania SSH:

```bash
sudo apt install -y fail2ban
```

Plik lokalny (nie edytować `jail.conf` bezpośrednio - nadpisuje się przy
aktualizacjach):

```bash
sudo tee /etc/fail2ban/jail.local > /dev/null <<'EOF'
[sshd]
enabled = true
port = ssh
maxretry = 5
findtime = 10m
bantime = 30m

bantime.increment = true
bantime.factor = 2
bantime.maxtime = 24h

[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 192.168.1.0/24
EOF

sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

- `maxretry=5` / `findtime=10m` / `bantime=30m` - 5 błędnych haseł w 10
  min → blokada IP na 30 min.
- `bantime.increment` - każda kolejna blokada tego IP dłuższa (30m → 1h
  → 2h... do max 24h).
- `ignoreip` zawiera lokalną sieć domową (`192.168.1.0/24`), żeby
  literówka w haśle nie zablokowała własnego dostępu.

## 0a. Skrypty `scripts/ssh/activate.sh` i `deactivate.sh`

Zamiast ręcznych komend z sekcji 0 - para skryptów w tym repo,
uruchamiana **jako root, bezpośrednio na Dellu** (skopiuj repo na Della
albo przepisz plik ręcznie, skoro SSH jeszcze nie działa):

```bash
sudo scripts/ssh/activate.sh
```

Co robi, w kolejności, z potwierdzeniem na każdym kroku zmieniającym
system:

1. **Backup** bieżącej konfiguracji PRZED jakąkolwiek zmianą -
   `/etc/ssh/sshd_config` i (jeśli istnieje) `/etc/fail2ban/jail.local`
   trafiają do `/var/backups/work6-ssh-hardening/backup-<znacznik-czasu>/`.
2. Instaluje `openssh-server` (jeśli brak) i włącza usługę `ssh`.
3. **Pyta** o aktywację blokady logowań po nieudanych próbach
   (fail2ban) - domyślnie tak; przy zgodzie instaluje `fail2ban` i
   zapisuje `jail.local` z tymi samymi progami co w sekcji 0
   (5 prób/10 min → 30 min, eskalacja x2 do 24h, whitelist
   `192.168.1.0/24`).
4. Zapisuje stan wyjściowy (co było zainstalowane/aktywne PRZED
   zmianami) do `/var/backups/work6-ssh-hardening/state.env` - potrzebne
   do dokładnego cofnięcia.

Cofnięcie do poprzedniej konfiguracji:

```bash
sudo scripts/ssh/deactivate.sh
```

Przywraca dokładnie to, co było: `jail.local` przywrócony albo usunięty
(zależnie, czy istniał wcześniej), `sshd_config` przywrócony z backupu
jeśli się różni, fail2ban zatrzymany/odinstalowany/przywrócony zależnie
od stanu sprzed aktywacji. `openssh-server`/usługę `ssh` **pyta osobno i
głośno ostrzega** przed zatrzymaniem - zrobienie tego przez samo SSH
zrywa bieżącą sesję.

## 1. Sposób łączenia - hasło nigdy w czacie z Claude

Zasada: hasło SSH wpisujesz **wyłącznie we własnym terminalu**, nigdy
wklejone do rozmowy z Claude - wklejone w czacie ląduje w transkrypcie
sesji (patrz `sekret-wklejony-w-czacie-trafia-do-transkryptu` w
`knowledge_base_ag/claude-code/`).

Wybrany wariant: **ręczny relay**, bez trwałego klucza SSH. Claude nie
ma narzędzia do zdalnego sterowania terminalem - może tylko wykonywać
komendy lokalnie na swoim komputerze. Więc:

1. Ty łączysz się i wpisujesz hasło **sam, lokalnie**:

   ```bash
   ssh <TWOJ_USER>@192.168.1.62
   ```

2. Claude podaje komendy do wklejenia w tej sesji.
3. Ty wklejasz wynik z powrotem do czatu.
4. Nic trwałego (żaden klucz) nie zostaje na Dellu po zakończeniu.

Alternatywa (odrzucona przez usera - nie chce trwałego klucza):
tymczasowy klucz SSH wygenerowany lokalnie na macOS
(`~/.ssh/id_ed25519_dell-debian`), dodany przez `ssh-copy-id`, usuwany
na koniec z `~/.ssh/authorized_keys` na Dellu. Zostawione jako opcja,
gdyby ręczny relay okazał się zbyt uciążliwy przy większej liczbie
komend.

## 2. Pierwsze komendy po zalogowaniu (rozpoznanie środowiska)

```bash
whoami; hostname; cat /etc/os-release | head -3
sudo -iu ai-agent -- bash -lc 'echo $WORK6; ls $WORK6 2>/dev/null'
```

## 3. Zakres transferu (ustalony z userem)

| Co | Skąd (macOS) | Dokąd (Debian, ai-agent) | Uwagi |
|---|---|---|---|
| Pasek statusu | `~/.claude/statusline-command.sh` | `$WORK6/home/.claude/statusline-command.sh` | czysty POSIX `sh` + `jq`, bez zmian; wymaga `jq` zainstalowanego na Debianie |
| Wpis `statusLine` | fragment `~/.claude/settings.json` | scalić do `$WORK6/home/.claude/settings.json` | użyć `"$HOME"` zamiast zaszytej ścieżki `/Users/adam/...`; **scalić**, nie nadpisać - plik już ma wymuszony `DISABLE_AUTOUPDATER` (patrz `setup.d/40-claude.sh`) |
| Reguły ogólne | `~/.claude/CLAUDE.md` | `$WORK6/home/.claude/CLAUDE.md` | podmienić ścieżkę cache Playwright: `~/Library/Caches/ms-playwright/` (macOS) → `~/.cache/ms-playwright/` (Linux) |
| Skill | `~/.claude/skills/skill-kb-archiver/SKILL.md` | `$WORK6/home/.claude/skills/skill-kb-archiver/` | + `git clone` repo `knowledge_base_ag` na Dellu, bo skill się do niego odwołuje i bez niego nie zadziała |
| Pozostałe skille (cloudflare, wrangler, agents-sdk...) | - | - | **nie kopiować** - to skille z pluginu `frontend-design@claude-plugins-official` (marketplace), instalować tam przez plugin manager, nie scp |

## 4. Status

- [ ] SSH włączony i dostępny na Dellu (`scripts/ssh/activate.sh`)
- [ ] rozpoznanie środowiska (`$WORK6`, wersja Debiana)
- [ ] pasek statusu przeniesiony
- [ ] `CLAUDE.md` przeniesiony (ze zmianą ścieżki Playwright)
- [ ] `skill-kb-archiver` przeniesiony + `knowledge_base_ag` sklonowane
- [ ] weryfikacja: nowa sesja Claude Code na Dellu widzi pasek, reguły, skill
