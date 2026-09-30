# trassd-ddev-claude

DDEV-Add-on, das **Claude Code** in den Web-Container bringt, plus die GitHub Action,
die das dafür genutzte schlanke „nur Claude"-Image täglich nach GHCR baut.

- **Keine Installation pro Projekt:** Das Binary kommt per `COPY --from=…` aus einem
  gecachten Image, das DDEV-Webserver-Image wird nicht ersetzt.
- **Einmal einloggen, überall nutzen:** Login, Settings und Plugins liegen im globalen
  DDEV-Cache und gelten für alle Projekte.
- **Getrennter Kontext pro Projekt:** Sessions und Memory liegen unter dem
  **DDEV-Projektnamen**, nicht unter `/var/www/html`, das bei jedem Projekt gleich ist.

## Installation

```bash
ddev add-on get avhulst/trassd-ddev-claude
ddev restart
ddev claude
```

`claude` funktioniert auch in `ddev ssh`, `ddev exec` und in Hooks, überall mit
derselben Konfiguration.

## Authentifizierung (Pro/Max/Team)

- **Interaktiv:** beim ersten `ddev claude` `/login` durchlaufen. Der Login liegt im
  globalen Cache und übersteht `restart`, `rebuild`, `poweroff` und `delete`.
- **Headless / zum Teilen:** auf einer Maschine mit Browser `claude setup-token`
  ausführen und den Token in der Host-Shell exportieren, z. B. in `~/.zshrc`:

  ```bash
  export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
  export CONTEXT7_API_KEY=ctx7sk-...   # optional, für das Context7-Plugin
  ```

  Das Add-on reicht `CLAUDE_CODE_OAUTH_TOKEN` und `CONTEXT7_API_KEY` per
  `web_environment` in den Web-Container durch. Die Werte werden beim `ddev start` bzw.
  `ddev restart` aus der Shell gelesen, in der der Befehl läuft. Nach einer Änderung also
  neu starten. Nicht gesetzte Variablen bleiben leer, dann gilt der normale `/login`.

  Alternativ pro Projekt über eine **gitignorte** lokale Config:

  ```yaml
  # .ddev/config.token.local.yaml  (gitignored)
  web_environment:
    - CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
  ```

**Niemals** Credentials oder Token ins Image backen oder in eine versionierte Datei
schreiben.

## Wo Claude seine Daten ablegt

```
/mnt/ddev-global-cache/claude-code/shared/.claude/
├── .credentials.json, .claude.json, settings.json, plugins/ …   # geteilt
└── projects/
    ├── <projekt-a>/      # Sessions + memory/ von DDEV-Projekt "projekt-a"
    └── <projekt-b>/
```

Das erledigt ein Wrapper unter `/usr/local/bin/claude`, der vor dem Start des echten
Binarys (`/usr/local/lib/claude-code/claude`) diese Variablen setzt, jeweils nur, wenn
sie noch nicht gesetzt sind:

| Variable | Standard |
|---|---|
| `CLAUDE_CODE_CACHE_DIR` | `/mnt/ddev-global-cache/claude-code/shared` |
| `CLAUDE_CONFIG_DIR` | `$CLAUDE_CODE_CACHE_DIR/.claude` |
| `CLAUDE_CODE_PROJECT_DIR_NAME` | `$DDEV_PROJECT`, auf `A-Z a-z 0-9 _ -` bereinigt, max. 64 Zeichen |
| `DISABLE_AUTOUPDATER` | `1` (Updates kommen über das Image) |

Überschreiben geht per `web_environment` in einer eigenen `.ddev/config.*.yaml`, z. B.
für einen eigenen, nicht geteilten Login pro Projekt:

```yaml
web_environment:
  - CLAUDE_CODE_CACHE_DIR=/mnt/ddev-global-cache/claude-code/mein-projekt
```

## Plugins

Das Add-on installiert keine Plugins. Einmal im Container installieren genügt, weil
das Config-Verzeichnis geteilt und dauerhaft ist:

```bash
ddev claude plugin marketplace add https://github.com/anthropics/claude-plugins-official
ddev claude plugin install context7@claude-plugins-official
```

## Umstieg von der alten `ddev-example/`-Kopie

1. Alte Dateien aus `.ddev/` entfernen: `web-build/Dockerfile` (nur die `COPY`-Zeile
   für Claude), `commands/web/claude`, `config.claude.yaml`,
   `homeadditions/.bashrc.d/local-bin-path.sh`.
2. Add-on installieren (siehe oben).
3. Der Login wird beim ersten Start automatisch übernommen: Die alte
   `shared/.claude.json` wandert nach `shared/.claude/.claude.json`. An der alten Stelle
   bleibt ein Symlink zurück, sodass Projekte, die noch das alte Setup nutzen, weiter
   denselben Login und dieselben Einstellungen sehen. Alte und neue Projekte können also
   eine Weile parallel laufen.
4. Alte Sessions und Memory aller Projekte liegen gemischt in
   `shared/.claude/projects/-var-www-html/`. Wer sie behalten will, verschiebt sie
   von Hand in den neuen Projektordner:

   ```bash
   ddev exec 'cd /mnt/ddev-global-cache/claude-code/shared/.claude/projects && mkdir -p "$DDEV_PROJECT" && cp -a -- -var-www-html/. "$DDEV_PROJECT"/'
   ```

## Umstieg vom früheren Add-on-Namen `claude-code`

Das Add-on hieß früher `claude-code`. Nach `ddev add-on get avhulst/trassd-ddev-claude`
die alten Dateien aus `.ddev/` löschen, sonst laufen Hook und Dockerfile doppelt:
`config.claude-code.yaml` und `web-build/Dockerfile.claude-code`. Login, Sessions und
Memory bleiben erhalten, weil das Cache-Verzeichnis unverändert ist.

## Updates und Version pinnen

`.ddev/web-build/Dockerfile.trassd-ddev-claude` bezieht standardmäßig `:latest`. Docker
aktualisiert ein lokal vorhandenes `:latest` nie von selbst, und der Build würde sonst
diese veraltete Kopie nehmen. Deshalb führt das Add-on vor jedem `ddev start` bzw.
`ddev restart` auf dem Host `docker pull ghcr.io/avhulst/claude-code:latest` aus. Eine
neue Claude-Version kommt also mit dem nächsten Restart. Offline oder bei einem Fehler
startet DDEV trotzdem, dann mit der vorhandenen Version.

Zum Pinnen die Zeile `#ddev-generated` aus dem Dockerfile entfernen (sonst überschreibt
ein Add-on-Update die Datei) und den Tag ändern, z. B.
`ghcr.io/avhulst/claude-code:2.1.235`. Der Pull-Hook zieht dann zwar weiterhin
`:latest`, das gepinnte Image ist davon aber nicht betroffen.

## Bekannte Einschränkungen

- **Projekteinstellungen in `.claude.json` sind geteilt.** Lokale MCP-Server
  (`claude mcp add --scope local`), der Trust-Dialog und lokal erlaubte Tools stehen
  unter dem Pfad `/var/www/html` und gelten damit für alle DDEV-Projekte.
  Projektspezifisches gehört ins Repo: `.mcp.json` bzw. `.claude/settings.local.json`.
- **`CLAUDE_CODE_PROJECT_DIR_NAME` ist nicht offiziell dokumentiert.** Die Tests in
  `tests/test.bats` prüfen die Projektbenennung, und die CI läuft wöchentlich, damit eine
  Verhaltensänderung in neuen Claude-Versionen auffällt.

## Verworfene Alternativen

- **Symlink `/var/www/<projekt>` → `/var/www/html`:** Claude löst Symlinks auf und
  landet wieder in `-var-www-html`.
- **Zweiter Bind-Mount des Projekts unter `/var/www/<projekt>`: nicht mit Mutagen
  kompatibel.** Mit Mutagen (Standard unter macOS) ist `/var/www/html` ein
  synchronisiertes Volume. Ein zusätzlicher Bind-Mount umgeht die Synchronisation, ist
  langsam und zeitweise inkonsistent mit `/var/www/html`.
- **`~/.claude` mit einzeln verlinkten Einträgen:** fragile Whitelist, die
  `.claude.json`-Kollision bliebe trotzdem.

## Entfernen

```bash
ddev add-on remove trassd-ddev-claude
ddev restart
```

Login, Sessions und Memory im globalen Cache bleiben erhalten. Komplett löschen
(betrifft alle Projekte):

```bash
ddev exec rm -rf /mnt/ddev-global-cache/claude-code
```

## Tests

```bash
brew install bats-core && brew tap bats-core/bats-core && brew trust bats-core/bats-core \
  && brew install bats-support bats-assert bats-file
bats tests/wrapper.bats   # schnell, ohne DDEV
bats tests/test.bats      # Integration mit echtem DDEV, nutzt ein isoliertes Cache-Verzeichnis
```

---

## Das Image: `ghcr.io/avhulst/claude-code`

`claude-code/Dockerfile` baut ein minimales Image, das nur das Claude-Code-Binary enthält
und ausschließlich als `COPY --from`-Quelle dient.

### Wie die tägliche Action arbeitet

1. Liest die neueste Version via `npm view @anthropic-ai/claude-code version`.
2. Prüft, ob dieser Version-Tag in GHCR bereits existiert. Wenn ja, **Abbruch ohne Push**.
3. Sonst Multi-Arch-Build (`linux/amd64` + `linux/arm64`) und Push der Tags `latest`
   und `<version>`.

Manuell erzwingen geht über *Run workflow* mit gesetztem `force`.

### GHCR-Sichtbarkeit

Ein neu gepushtes GHCR-Paket ist standardmäßig *privat*. Damit `ddev add-on get` bei
allen funktioniert und die CI-Tests laufen, das Paket auf **Public** stellen
(*Package settings* → *Change visibility*). Bleibt es privat, braucht jede Maschine
einmal `docker login ghcr.io` mit einem Token mit `read:packages`.

### Aufräumen / Retention (nur 3 Images vorhalten)

Nach jedem erfolgreichen Push behält der `cleanup`-Job via
`dataaxiom/ghcr-cleanup-action` **nur die 3 neuesten Releases** und löscht ältere,
inklusive ihrer Multi-Arch-Kind-Manifeste. Bewusst nicht `actions/delete-package-versions`,
die Multi-Arch-Images beschädigt.

Pro Release entstehen zwei Tags (`latest` + `<version>`) auf dieselbe Digest, also
**eine** GHCR-Version. `keep-n-tagged: 3` behält damit die drei jüngsten Releases.

**Vor dem Scharfschalten testen:** im `cleanup`-Job einmal `dry-run: true` setzen, die
Action manuell starten und im Log prüfen, was gelöscht würde.

Für repo-gebundene Pakete reicht das eingebaute `GITHUB_TOKEN`. Liegt das Paket bei einer
Organisation ohne Repo-Verknüpfung, ein PAT mit `delete:packages` als Secret hinterlegen
und per `token:` übergeben.

### Hinweise

- Das Binary ist glibc-dynamisch. Carrier-Image (`debian:bookworm-slim`) und
  DDEV-Webserver sind beide Debian-basiert.
- `COPY --from` zieht automatisch die passende Architektur (arm64 auf Apple Silicon,
  sonst amd64).
