# UPDATE.md - szybka sciezka aktualizacji work6 na Dellu

Sciaga "co po kolei", gdy chcesz podniesc wszystko do aktualnych wersji.
Szczegoly i troubleshooting: README sekcja 10 (aktualizacje) i 12
(diagnostyka) - w razie rozjazdu wygrywa README.

## 0. Najpierw samo work6 (jako ai-agent)

```bash
sudo -iu ai-agent
cd ~/work6-config && git pull && ./setup-work6.sh --yes
```

Uwaga: to synchronizuje skrypty/launchery do `~/work6`, ale **wersji
narzedzi nie podnosi** - od tego jest `update-tools.sh` (krok 2).

## 1. Pakiety systemowe (admin na Dellu)

```bash
sudo ~ai-agent/work6-config/prepare-system.sh   # zapyta m.in. o ripgrep/fd-find
sudo apt update && sudo apt upgrade             # zwykla higiena Debiana, poza work6
```

## 2. Narzedzia work6 (jako ai-agent)

```bash
~/work6/scripts/update-tools.sh --check   # pokaze, co jest do podniesienia
~/work6/scripts/update-tools.sh           # zaktualizuje claude/agy wg kanalu
```

## 3. Kontrola

```bash
~/work6/scripts/doctor.sh --quick
```

Doctor ma wyjsc zielony; dryf work6 vs repo, dziury w uprawnieniach
albo zapisywalne config/tools w sandboxie zglosi wprost.
