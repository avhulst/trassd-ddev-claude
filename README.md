# ddev-claude-image

Baut ein schlankes, wiederverwendbares **„nur Claude Code"-Image** und veröffentlicht es
täglich automatisch nach GitHub Container Registry (GHCR). DDEV-Projekte ziehen das
Binary dann per einer einzigen `COPY --from=…`-Zeile in ihr Webserver-Image — ohne
Installation pro Projekt und ohne das DDEV-Webserver-Image zu ersetzen.

## Warum dieser Ansatz

- **Keine Installation pro Projekt:** kein `curl | install.sh` bei jedem `ddev restart`,
  nur ein schneller Datei-Copy aus einem gecachten Image.
- **Keine DDEV-Versionskopplung:** Du ersetzt das Webserver-Image *nicht* (`webimage`),
  sondern legst nur eine `COPY`-Zeile obendrauf. DDEV pflegt die Basis weiter.
- **Immer aktuell:** Die Action baut täglich neu und veröffentlicht nur, wenn npm
  tatsächlich eine neuere Claude-Code-Version hat.

## Struktur

```
.
├── .github/workflows/build.yml   # tägliche Build+Push-Action (GHCR)
├── claude-code/Dockerfile        # das "nur Claude"-Image (Multi-Stage)
└── ddev-example/                 # zum Kopieren in dein/e Projekt/e nach .ddev/
    ├── web-build/Dockerfile      # COPY --from=ghcr.io/OWNER/claude-code:latest
    ├── commands/web/claude       # das `ddev claude`-Kommando
    └── config.claude.yaml        # Auth-Persistenz-Hook
```

## Einrichtung

1. **Repo anlegen und pushen** (ersetze `OWNER`):

   ```bash
   gh repo create OWNER/ddev-claude-image --public --source=. --remote=origin --push
   # oder klassisch:
   # git init && git add . && git commit -m "init" \
   #   && git remote add origin git@github.com:OWNER/ddev-claude-image.git \
   #   && git push -u origin main
   ```

2. **Action einmal manuell starten** (Tab *Actions* → *build-claude-code-image* →
   *Run workflow*), damit das erste Image entsteht. Danach läuft sie täglich um
   06:00 UTC von selbst. Es ist keine zusätzliche Secret-Konfiguration nötig — die
   Action nutzt das eingebaute `GITHUB_TOKEN` zum Push nach GHCR.

3. **GHCR-Paket sichtbar machen:** Ein neu gepushtes GHCR-Paket ist standardmäßig
   *privat*. Für reibungsloses Ziehen gibt es zwei Optionen:
   - **Public:** Paket-Einstellungen → *Package settings* → *Change visibility* →
     *Public*. Dann kann jeder ohne Login `COPY --from=…` nutzen.
   - **Privat:** Auf jeder Dev-Maschine einmal `docker login ghcr.io` (mit einem
     GitHub-Token mit `read:packages`), damit der lokale Docker-Daemon das Image
     beim DDEV-Build ziehen darf.

## Nutzung in einem DDEV-Projekt

Kopiere die drei Dateien aus `ddev-example/` in das `.ddev/`-Verzeichnis deines
Projekts und ersetze `OWNER` in `web-build/Dockerfile` durch deinen GHCR-Namespace:

```
.ddev/web-build/Dockerfile
.ddev/commands/web/claude
.ddev/config.claude.yaml
```

Dann:

```bash
ddev restart      # baut das Webimage einmal neu und kopiert das Binary hinein
ddev claude       # startet Claude Code im Web-Container
```

Pinne für reproduzierbare Builds auf eine Version statt `:latest`, z. B.
`COPY --from=ghcr.io/OWNER/claude-code:2.1.179 …`.

## Authentifizierung (Pro/Max/Team)

Das Abo authentifiziert über **OAuth, nicht über einen API-Key**:

- **Interaktiv (lokal am einfachsten):** beim ersten `ddev claude` `/login` durchlaufen.
  Die Credentials landen in `~/.claude` und werden vom Hook ins globale Cache-Volume
  symlinkt — der Login hält über Rebuilds.
- **Headless / zum Teilen:** auf einer Maschine mit Browser einmal `claude setup-token`
  ausführen und den Token als `CLAUDE_CODE_OAUTH_TOKEN` über eine **gitignorte** lokale
  Config einspeisen (`setup-token` setzt einen Pro-, Max-, Team- oder Enterprise-Plan
  voraus):

  ```yaml
  # .ddev/config.token.local.yaml  (gitignored)
  web_environment:
    - CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
  ```

**Niemals** Credentials oder Token ins Image backen — Auth bleibt strikt zur Laufzeit
(Volume oder Env-Var).

## Wie die tägliche Action arbeitet

1. Liest die neueste veröffentlichte Version via `npm view @anthropic-ai/claude-code version`.
2. Prüft, ob dieser Version-Tag in GHCR bereits existiert → wenn ja, **Abbruch ohne Push**.
3. Sonst Multi-Arch-Build (`linux/amd64` + `linux/arm64`) und Push der Tags `latest`
   und `<version>`.

Manuell erzwingen geht über *Run workflow* mit gesetztem `force`.

## Aufräumen / Retention (nur 3 Images vorhalten)

Nach jedem erfolgreichen Push läuft ein `cleanup`-Job, der via
`dataaxiom/ghcr-cleanup-action` **nur die 3 neuesten Releases behält** und ältere
löscht — inklusive ihrer Multi-Arch-Kind-Manifeste. Genutzt wird hier bewusst diese
Action und **nicht** `actions/delete-package-versions`, die Multi-Arch-Images
beschädigt.

Zählung: Pro Release entstehen zwar zwei Tags (`latest` + `<version>`), aber beide
zeigen auf dieselbe Digest = **eine** GHCR-Version. `keep-n-tagged: 3` behält also die
drei jüngsten Releases.

**Vor dem ersten Scharfschalten testen:** In `build.yml` im `cleanup`-Job einmal
`dry-run: true` setzen, die Action manuell starten und im Job-Log prüfen, was *gelöscht
würde*. Passt es, wieder auf `dry-run: false`. Die Zahl 3 änderst du über `keep-n-tagged`.

Hinweis zu Rechten: Für repo-gebundene Pakete reicht das eingebaute `GITHUB_TOKEN`. Liegt
das Paket bei einer Organisation und ist nicht mit dem Repo verknüpft, hinterlege ein PAT
mit `delete:packages` als Secret und gib es der Action via `token:` mit.

## Hinweise

- Das Binary ist glibc-dynamisch; sowohl das Carrier-Image (`debian:bookworm-slim`) als
  auch der DDEV-Webserver sind Debian-basiert — passt.
- Multi-Arch ist abgedeckt; `COPY --from` zieht automatisch die passende Architektur
  (arm64 auf Apple Silicon, sonst amd64).
- Der Webimage-Build läuft weiter bei `ddev start`/`restart`, falls neu gebaut werden
  muss — dank Layer-Cache ist die `COPY` danach sofort durch.
