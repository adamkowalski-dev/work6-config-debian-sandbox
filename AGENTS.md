# AGENTS.md — zasady pracy agentów w tym repozytorium

Repo zawiera skrypty bezpieczeństwa (sandbox bwrap, instalatory z
weryfikacją sum). Obowiązują zasady:

1. **Zmiany na `main`/`master` wyłącznie przez Pull Request** — branch →
   commit → push → PR → merge po zielonym CI i akceptacji użytkownika.
   Nigdy bezpośredni commit na główny branch, nawet „drobny fix".
2. **Żadnych sekretów** w kodzie, przykładach, logach i README —
   tokeny/kody OAuth nie mogą pojawić się nawet w komunikatach `echo`.
3. Lista mountów sandboxa (`lib/sandbox.sh`) i guardy (`lib/common.sh`)
   to decyzje bezpieczeństwa — każdą zmianę opisz w PR z uzasadnieniem;
   nie „poszerzaj, żeby działało".
4. Skrypty Bash: `set -Eeuo pipefail`, funkcje, cytowane zmienne,
   idempotencja; po zmianach uruchom `bash -n` i (jeśli dostępny)
   `shellcheck`.
5. Fakty o instalatorach zewnętrznych (URL-e, sumy, fingerprinty)
   weryfikuj w oficjalnej dokumentacji i aktualizuj `LESSONS.md`.
