# DDEV-Add-on für Claude Code: Design

Datum: 2026-09-30
Status: Entwurf zur Freigabe

## Ziel

Aus `ddev-example/` wird ein installierbares DDEV-Add-on
(`ddev add-on get avhulst/ddev-claude-image`). Dabei legt Claude seinen
projektbezogenen Zustand (Sessions, Auto-Memory) im Web-Container unter dem
**DDEV-Projektnamen** ab statt unter dem Pfad des Arbeitsverzeichnisses.

### Problem heute

Claude leitet den projektbezogenen Speicherort aus dem Arbeitsverzeichnis ab
(`~/.claude/projects/<pfad-slug>/`). Im DDEV-Container ist das bei jedem
Projekt `/var/www/html`, also landet alles in `-var-www-html`. Weil
`config.claude.yaml` `~/.claude` außerdem in einen geteilten Ordner im globalen
Cache verlinkt, teilen sich alle Projekte dieselben Sessions und dieselbe Memory.

### Erfolgskriterien

- Zwei DDEV-Projekte, auch gleichzeitig laufend, haben getrennte Sessions und
  getrennte Memory unter `projects/<ddev-projektname>/`.
- Der Login gilt einmal für alle Projekte und übersteht `restart`, `rebuild`,
  `poweroff` und `delete`.
- Plugins, globale `settings.json` und globales `CLAUDE.md` bleiben projektübergreifend geteilt.
- Installation, Update und Entfernen laufen über die Standard-Add-on-Befehle von DDEV.

### Nicht-Ziele

- Automatische Plugin- oder Marketplace-Installation (entfällt ersatzlos).
- Getrennte Plugins oder Settings pro Projekt.
- Automatische Migration alter Sessions aus `projects/-var-www-html/`.

## Entscheidungsgrundlage (Spike)

Getestet mit Claude Code 2.1.235 im Image `ghcr.io/avhulst/claude-code:latest`:

| Variante | Ergebnis |
|---|---|
| Symlink `/var/www/<name>` → `/var/www/html`, `cd` hinein | Claude löst den Symlink auf und nutzt `-var-www-html` |
| Zweiter Bind-Mount desselben Ordners unter `/var/www/<name>` | `-var-www-<name>` |
| `CLAUDE_CODE_PROJECT_DIR_NAME=<name>` allein | wird ignoriert |
| `CLAUDE_CONFIG_DIR` + `CLAUDE_CODE_PROJECT_DIR_NAME=<name>` | `projects/<name>/`, auch aus Unterverzeichnissen heraus |
| Schlüssel in `.claude.json` bei der Env-Variante | bleibt `/var/www/html` |

Außerdem: Ist `CLAUDE_CONFIG_DIR` gesetzt, legt Claude die `.claude.json`
**innerhalb** des Config-Verzeichnisses ab, nicht in `~`.

Laut Binary nimmt Claude `CLAUDE_CODE_PROJECT_DIR_NAME` nur an, wenn der Wert
auf `^[A-Za-z0-9_-]{1,64}$` passt und kein reservierter Windows-Name ist
(`con`, `prn`, `aux`, `nul`, `com0-9`, `lpt0-9`). Andernfalls wird die
Variable stillschweigend ignoriert.

### Gewählt: Env-Variante

`CLAUDE_CONFIG_DIR` + `CLAUDE_CODE_PROJECT_DIR_NAME=<ddev-projektname>`.

### Verworfene Alternativen

- **Symlink:** funktioniert nicht, weil Claude den realen Pfad verwendet.
- **Zweiter Bind-Mount: nicht mit Mutagen kompatibel.** Mit Mutagen (Standard
  unter macOS) ist `/var/www/html` ein synchronisiertes Docker-Volume und kein
  Bind-Mount. Ein zusätzlicher Bind-Mount des Host-Ordners umgeht die
  Synchronisation, ist langsam und zeitweise inkonsistent mit `/var/www/html`.
- **`~/.claude` als echtes Verzeichnis mit einzeln verlinkten Einträgen:** Die
  Whitelist ist fragil, weil neue Dateien, die Claude künftig anlegt, verloren
  gingen. Die Kollision in `.claude.json` bliebe trotzdem bestehen.

### Bekannte Einschränkungen

1. **Projekteinträge in `.claude.json` sind geteilt.** Lokale MCP-Server
   (`claude mcp add --scope local`), der Trust-Dialog und lokal erlaubte Tools
   stehen unter dem Schlüssel `/var/www/html` und gelten damit für alle
   DDEV-Projekte. Workaround: Projektspezifisches ins Repo legen
   (`.mcp.json`, `.claude/settings.local.json`).
2. **`CLAUDE_CODE_PROJECT_DIR_NAME` ist nicht offiziell dokumentiert.** Ein
   Integrationstest (siehe Tests, Punkt 2) erkennt Verhaltensänderungen.

## Architektur

### Repo-Struktur

```
install.yaml                          # Add-on-Manifest (neu)
web-build/Dockerfile.claude-code      # COPY Binary + Wrapper
web-build/claude-wrapper.sh           # setzt Env, exec echtes Binary (neu)
commands/web/claude                   # `ddev claude`
config.claude-code.yaml               # post-start: Verzeichnis anlegen + Migration
tests/wrapper.bats                    # Unit-Tests Wrapper (neu)
tests/test.bats                       # Integrationstests (neu)
.github/workflows/test.yml            # Add-on-Tests in CI (neu)
claude-code/Dockerfile                # unverändert
.github/workflows/build.yml           # unverändert
```

`ddev-example/` wird entfernt, einschließlich
`.homeadditions/.bashrc.d/local-bin-path.sh`: Der Wrapper liegt in
`/usr/local/bin`, daher ist der `~/.local/bin`-Symlink überflüssig.

`Dockerfile.claude-code` statt `Dockerfile`, weil DDEV mehrere
`web-build/Dockerfile.*` unterstützt. So kollidiert das Add-on nicht mit einem
vorhandenen Dockerfile des Projekts.

### `web-build/Dockerfile.claude-code`

- `COPY --from=ghcr.io/avhulst/claude-code:latest /usr/local/bin/claude /usr/local/lib/claude-code/claude`
- `COPY claude-wrapper.sh /usr/local/bin/claude` mit Mode 755.
- Pinnen auf eine Version: `#ddev-generated` entfernen, Tag ändern (steht in der README).

### `web-build/claude-wrapper.sh`

Sorgt dafür, dass jeder Aufruf von `claude` (über `ddev claude`, `ddev ssh`,
Hooks, IDE) die richtige Umgebung hat. Alle Werte gelten nur, wenn die
Variable nicht schon von außen gesetzt ist.

| Variable | Standardwert |
|---|---|
| `CLAUDE_CODE_CACHE_DIR` | `/mnt/ddev-global-cache/claude-code/shared` |
| `CLAUDE_CONFIG_DIR` | `$CLAUDE_CODE_CACHE_DIR/.claude` |
| `CLAUDE_CODE_PROJECT_DIR_NAME` | bereinigter `$DDEV_PROJECT` (siehe unten) |
| `DISABLE_AUTOUPDATER` | `1` (Updates kommen über das Image, das Binary gehört root) |
| `CLAUDE_CODE_BIN` | `/usr/local/lib/claude-code/claude` (Test-Hook) |

Bereinigung des Projektnamens:
1. Ist `DDEV_PROJECT` leer, wird `CLAUDE_CODE_PROJECT_DIR_NAME` nicht gesetzt,
   und Claude verhält sich wie ohne Add-on.
2. Jedes Zeichen außerhalb von `[A-Za-z0-9_-]` wird durch `-` ersetzt.
3. Der Name wird auf 64 Zeichen gekürzt.
4. Ist das Ergebnis ein reservierter Name (`con|prn|aux|nul|com[0-9]|lpt[0-9]`,
   ohne Beachtung der Groß-/Kleinschreibung), wird `ddev-` vorangestellt und
   danach wieder auf 64 Zeichen gekürzt.

Zum Schluss `exec "$CLAUDE_CODE_BIN" "$@"`, wobei die Argumente unverändert
durchgereicht werden.

### `config.claude-code.yaml` (post-start-Hook)

1. `CLAUDE_CODE_CACHE_DIR` auflösen, mit demselben Standard wie im Wrapper.
2. `mkdir -p "$CLAUDE_CODE_CACHE_DIR/.claude"`.
3. Migration vom alten Layout, idempotent: Existiert
   `$CLAUDE_CODE_CACHE_DIR/.claude.json` und fehlt
   `$CLAUDE_CODE_CACHE_DIR/.claude/.claude.json`, wird die Datei verschoben.
   Eine vorhandene Zieldatei wird nie überschrieben.

Keine Plugin- oder Marketplace-Installation mehr, keine Symlinks in `~`.

### `commands/web/claude`

Wie bisher: `claude "$@"`, ruft also den Wrapper auf.

### `install.yaml`

- `name: claude-code`
- `project_files`: die vier Dateien oben. Alle tragen `#ddev-generated`.
- `ddev_version_constraint: '>= v1.24.0'`
- Keine `post_install_actions`.

### Speicherlayout im globalen Cache

```
/mnt/ddev-global-cache/claude-code/shared/.claude/
├── .credentials.json, .claude.json, settings.json, plugins/ …   # geteilt
└── projects/
    ├── <projekt-a>/      # Sessions + memory/
    └── <projekt-b>/
```

## Fehlerfälle

- `DDEV_PROJECT` leer: Standardverhalten von Claude (siehe Wrapper).
- Globaler Cache nicht beschreibbar: Der Hook bricht mit `set -eu` ab, und
  `ddev start` zeigt den Fehler an.
- Migration ist idempotent und überschreibt nie.
- `ddev add-on remove claude-code` entfernt die Projektdateien. Daten im
  globalen Cache bleiben bewusst erhalten. Die README beschreibt das Löschen
  (`ddev exec rm -rf /mnt/ddev-global-cache/claude-code`).

## Tests

TDD-Reihenfolge: Wrapper-Unit-Tests → Wrapper → Integrationstests → Hook/Add-on.

### `tests/wrapper.bats` (ohne DDEV)

Der Wrapper wird direkt ausgeführt. `CLAUDE_CODE_BIN` zeigt auf einen Stub, der
seine Umgebung und seine Argumente ausgibt. Fälle:

- `DDEV_PROJECT=shop` → `CLAUDE_CODE_PROJECT_DIR_NAME=shop`
- Sonderzeichen (`my.shop`) → `my-shop`
- Name mit 70 Zeichen → auf 64 gekürzt
- Reservierter Name (`CON`) → `ddev-CON`
- `DDEV_PROJECT` leer → Variable nicht gesetzt
- Standard `CLAUDE_CONFIG_DIR` = `/mnt/ddev-global-cache/claude-code/shared/.claude`
- `CLAUDE_CODE_CACHE_DIR` gesetzt → `CLAUDE_CONFIG_DIR` daraus abgeleitet
- Vorgesetzte Werte für `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_PROJECT_DIR_NAME` und
  `DISABLE_AUTOUPDATER` bleiben erhalten
- Argumente mit Leerzeichen werden unverändert durchgereicht

### `tests/test.bats` (Integration, DDEV-Add-on-Template)

Setup: Temp-Projekt, `config.test.yaml` mit
`web_environment: [CLAUDE_CODE_CACHE_DIR=/mnt/ddev-global-cache/claude-code-test-<zufall>]`,
damit der echte Login des Entwicklers unberührt bleibt. Dann
`ddev add-on get <repo-dir>` und `ddev restart`. Teardown: Test-Verzeichnis im
globalen Cache löschen, dann `ddev delete -Oy`.

1. `ddev exec claude --version` und `ddev claude --version` funktionieren.
2. **Regressionstest für die Projektbenennung:** `ddev exec` mit
   `ANTHROPIC_API_KEY=sk-ant-invalid claude -p hi` (Fehlschlag erwartet und
   toleriert). Danach existiert `…/.claude/projects/<projektname>/`, und
   `…/.claude/projects/-var-www-html` existiert nicht.
3. **Migration:** Alte `$CLAUDE_CODE_CACHE_DIR/.claude.json` vorbelegen →
   `ddev restart` → Datei liegt unter `.claude/.claude.json`, die alte ist weg.
   Zweiter Fall: Das Ziel existiert bereits und bleibt unverändert.
4. `ddev add-on remove claude-code` entfernt alle Projektdateien.

### CI (`.github/workflows/test.yml`)

`ddev/github-action-add-on-test@v2` bei Push/PR auf `main` und wöchentlich per
Schedule, damit Verhaltensänderungen neuer Claude-Versionen auch ohne
Code-Änderung auffallen. Voraussetzung: Das GHCR-Paket
`ghcr.io/avhulst/claude-code` ist public.

## Dokumentation (README)

Die README wird zur Add-on-README umgebaut. Der Image-Build-Teil bleibt als eigener Abschnitt.

- Installation: `ddev add-on get avhulst/ddev-claude-image` → `ddev restart` → `ddev claude`
- Auth: `/login` oder `CLAUDE_CODE_OAUTH_TOKEN` per gitignorter lokaler Config
- Speicherlayout, Umgebungsvariablen und Overrides
- Migration: Login wird automatisch übernommen. Alte Sessions liegen in
  `projects/-var-www-html/` und lassen sich manuell nach `projects/<name>/` verschieben.
- Plugins: einmal `claude plugin install …`, das gilt für alle Projekte
- Version pinnen
- Bekannte Einschränkungen und verworfene Alternativen, einschließlich des
  Hinweises, dass der Bind-Mount-Ansatz nicht mit Mutagen kompatibel ist
- Entfernen, einschließlich Aufräumen des globalen Cache
