# DDEV-Add-on für Claude Code: Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ddev-example/` wird zu einem installierbaren DDEV-Add-on, das Claudes projektbezogenen Zustand (Sessions, Memory) unter dem DDEV-Projektnamen ablegt.

**Architecture:** Ein Wrapper-Skript ersetzt `/usr/local/bin/claude` im Web-Container. Es setzt `CLAUDE_CONFIG_DIR` (geteiltes Verzeichnis im globalen DDEV-Cache) und `CLAUDE_CODE_PROJECT_DIR_NAME` (bereinigter `$DDEV_PROJECT`) und ruft dann per `exec` das echte Binary unter `/usr/local/lib/claude-code/claude` auf. Ein post-start-Hook legt das Verzeichnis an und migriert eine alte `.claude.json`. Das Add-on liegt im Repo-Root (`install.yaml`), der Image-Build bleibt unverändert.

**Tech Stack:** DDEV-Add-ons (`install.yaml`, `>= v1.24.0`), Bash, Docker BuildKit (`COPY --chmod`), bats-core mit bats-support/bats-assert/bats-file, `ddev/github-action-add-on-test@v2`.

**Spec:** `docs/superpowers/specs/2026-09-30-ddev-addon-design.md`

## Global Constraints

- Add-on-Name: `claude-code`; Installation: `ddev add-on get avhulst/ddev-claude-image`
- `ddev_version_constraint: '>= v1.24.0'`
- Image: `ghcr.io/avhulst/claude-code:latest`
- Echtes Binary: `/usr/local/lib/claude-code/claude`; Wrapper: `/usr/local/bin/claude`
- Standard `CLAUDE_CODE_CACHE_DIR`: `/mnt/ddev-global-cache/claude-code/shared`
- `CLAUDE_CONFIG_DIR` = `$CLAUDE_CODE_CACHE_DIR/.claude`
- Projektname-Regel von Claude: `^[A-Za-z0-9_-]{1,64}$`, reserviert: `con|prn|aux|nul|com[0-9]|lpt[0-9]` (ohne Beachtung der Groß-/Kleinschreibung)
- Alle Add-on-Projektdateien beginnen mit (bzw. enthalten in Zeile 2) `#ddev-generated`
- Keine Plugin- oder Marketplace-Installation im Add-on
- **Commits:** nur nach Rückfrage beim User, einzeiliger englischer Conventional Commit, kein Body, keine `Co-Authored-By`-Zeile
- Doku (README) auf Deutsch, Code und Kommentare auf Englisch (wie im bestehenden Repo)

## Review Focus

1. **Upgrade eines Bestandsnutzers:** Liegt im alten Layout schon `shared/.claude/` mit `.credentials.json` vor, muss der Login nach dem Umstieg erhalten bleiben. Test in Task 3 („migrates legacy .claude.json and keeps existing state").
2. **Projekt hat bereits ein eigenes `.ddev/web-build/Dockerfile`:** Beide Dockerfiles müssen wirken, das Add-on darf nichts überschreiben. Test in Task 2 („coexists with a project's own web-build Dockerfile").
3. **Claude wird aus einem Unterverzeichnis gestartet** (`/var/www/html/sub`): Es muss derselbe Projektordner verwendet werden, nicht `-var-www-html-sub`. Test in Task 2 („per-project state dir is named after the DDEV project").
4. **Wiederholtes `ddev restart`:** Der Hook muss idempotent sein, darf also nicht fehlschlagen und darf nichts doppelt migrieren. Test in Task 3 (zweiter Restart im Migrationstest).
5. **Erneutes `ddev add-on get` (Update):** Login und Zustand im Cache müssen erhalten bleiben. Test in Task 3 („re-installing the add-on keeps login state").

---

## Voraussetzungen (einmalig, lokal)

```bash
brew install bats-core
brew tap bats-core/bats-core
brew install bats-support bats-assert bats-file
ddev --version   # >= v1.24.0
docker pull ghcr.io/avhulst/claude-code:latest   # Image muss erreichbar sein
```

## Dateiübersicht

| Datei | Aktion | Verantwortung |
|---|---|---|
| `web-build/claude-wrapper.sh` | neu | Umgebung setzen, Projektnamen bereinigen, echtes Binary per exec starten |
| `tests/wrapper.bats` | neu | Unit-Tests des Wrappers mit Stub-Binary |
| `web-build/Dockerfile.claude-code` | neu (ersetzt `ddev-example/web-build/Dockerfile`) | Binary und Wrapper ins Web-Image kopieren |
| `commands/web/claude` | verschoben aus `ddev-example/commands/web/claude` | `ddev claude` |
| `config.claude-code.yaml` | neu (ersetzt `ddev-example/config.claude.yaml`) | post-start: Verzeichnis anlegen, Migration |
| `install.yaml` | neu | Add-on-Manifest |
| `tests/test.bats` | neu | Integrationstests mit echtem DDEV |
| `.github/workflows/test.yml` | neu | CI für die Add-on-Tests |
| `README.md` | umschreiben | Add-on-Doku und Image-Build-Doku |
| `ddev-example/` | löschen | wird durch das Add-on ersetzt |

---

### Task 1: Wrapper-Skript mit Unit-Tests

**Files:**
- Create: `web-build/claude-wrapper.sh`
- Test: `tests/wrapper.bats`

**Interfaces:**
- Consumes: nichts
- Produces: ausführbares Skript `web-build/claude-wrapper.sh`. Es liest die Env-Variablen `DDEV_PROJECT`, `CLAUDE_CODE_CACHE_DIR`, `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_PROJECT_DIR_NAME`, `DISABLE_AUTOUPDATER` und `CLAUDE_CODE_BIN` und ruft `exec "$CLAUDE_CODE_BIN" "$@"` auf. Task 2 kopiert es nach `/usr/local/bin/claude`.

- [ ] **Step 1: Failing Tests schreiben**

`tests/wrapper.bats`:

```bash
#!/usr/bin/env bats
# Unit tests for web-build/claude-wrapper.sh. No DDEV needed:
# the real Claude binary is replaced by a stub that prints its environment.
# Run from the repo root: bats tests/wrapper.bats

setup() {
  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH:-}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  bats_load_library bats-support
  bats_load_library bats-assert

  WRAPPER="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)/web-build/claude-wrapper.sh"
  STUB="${BATS_TEST_TMPDIR}/claude-stub"
  cat > "${STUB}" <<'EOF'
#!/bin/bash
env | grep -E '^(CLAUDE_|DISABLE_AUTOUPDATER=)' | sort
for arg in "$@"; do echo "ARG=<${arg}>"; done
EOF
  chmod +x "${STUB}"
}

# Runs the wrapper in a clean environment plus the given VAR=value pairs.
run_wrapper() {
  run env -i PATH="${PATH}" CLAUDE_CODE_BIN="${STUB}" "$@" bash "${WRAPPER}"
}

@test "uses the DDEV project name" {
  run_wrapper DDEV_PROJECT=shop
  assert_success
  assert_line "CLAUDE_CODE_PROJECT_DIR_NAME=shop"
}

@test "replaces unsupported characters with a dash" {
  run_wrapper DDEV_PROJECT=my.shop
  assert_success
  assert_line "CLAUDE_CODE_PROJECT_DIR_NAME=my-shop"
}

@test "truncates the name to 64 characters" {
  run_wrapper DDEV_PROJECT="$(printf 'a%.0s' {1..70})"
  assert_success
  assert_line "CLAUDE_CODE_PROJECT_DIR_NAME=$(printf 'a%.0s' {1..64})"
}

@test "prefixes reserved names" {
  run_wrapper DDEV_PROJECT=CON
  assert_success
  assert_line "CLAUDE_CODE_PROJECT_DIR_NAME=ddev-CON"
}

@test "leaves the project dir name unset without DDEV_PROJECT" {
  run_wrapper
  assert_success
  refute_line --partial "CLAUDE_CODE_PROJECT_DIR_NAME="
}

@test "defaults to the shared dir in the DDEV global cache" {
  run_wrapper
  assert_success
  assert_line "CLAUDE_CODE_CACHE_DIR=/mnt/ddev-global-cache/claude-code/shared"
  assert_line "CLAUDE_CONFIG_DIR=/mnt/ddev-global-cache/claude-code/shared/.claude"
  assert_line "DISABLE_AUTOUPDATER=1"
}

@test "derives the config dir from CLAUDE_CODE_CACHE_DIR" {
  run_wrapper CLAUDE_CODE_CACHE_DIR=/tmp/cc
  assert_success
  assert_line "CLAUDE_CONFIG_DIR=/tmp/cc/.claude"
}

@test "keeps values that are already set" {
  run_wrapper DDEV_PROJECT=shop CLAUDE_CONFIG_DIR=/x CLAUDE_CODE_PROJECT_DIR_NAME=custom DISABLE_AUTOUPDATER=0
  assert_success
  assert_line "CLAUDE_CONFIG_DIR=/x"
  assert_line "CLAUDE_CODE_PROJECT_DIR_NAME=custom"
  assert_line "DISABLE_AUTOUPDATER=0"
}

@test "passes arguments through unchanged" {
  run env -i PATH="${PATH}" CLAUDE_CODE_BIN="${STUB}" bash "${WRAPPER}" "hello world" --flag ""
  assert_success
  assert_line "ARG=<hello world>"
  assert_line "ARG=<--flag>"
  assert_line "ARG=<>"
}
```

- [ ] **Step 2: Tests laufen lassen, Fehlschlag prüfen**

Run: `bats tests/wrapper.bats`
Expected: alle 9 Tests FAIL, `bash: …/web-build/claude-wrapper.sh: No such file or directory`

- [ ] **Step 3: Wrapper implementieren**

`web-build/claude-wrapper.sh`:

```bash
#!/bin/bash
#ddev-generated
# Claude Code wrapper installed by the claude-code DDEV add-on.
#
# Keeps Claude's config in DDEV's global cache (survives restart/rebuild/delete)
# and names the per-project state dir (sessions, memory) after the DDEV project
# instead of the working directory, which is /var/www/html in every project.
# Every variable can be overridden from outside, e.g. via web_environment.
set -eu

: "${CLAUDE_CODE_CACHE_DIR:=/mnt/ddev-global-cache/claude-code/shared}"
: "${CLAUDE_CONFIG_DIR:=${CLAUDE_CODE_CACHE_DIR}/.claude}"
: "${CLAUDE_CODE_BIN:=/usr/local/lib/claude-code/claude}"
# Updates come with the image; the root-owned binary can't update itself.
: "${DISABLE_AUTOUPDATER=1}"
export CLAUDE_CODE_CACHE_DIR CLAUDE_CONFIG_DIR DISABLE_AUTOUPDATER

# Claude only honours CLAUDE_CODE_PROJECT_DIR_NAME (together with
# CLAUDE_CONFIG_DIR) if it matches ^[A-Za-z0-9_-]{1,64}$ and is not a reserved
# Windows device name -- otherwise it silently falls back to the path.
if [ -z "${CLAUDE_CODE_PROJECT_DIR_NAME:-}" ] && [ -n "${DDEV_PROJECT:-}" ]; then
    name="$(printf '%s' "${DDEV_PROJECT}" | LC_ALL=C tr -c 'A-Za-z0-9_-' '-' | cut -c1-64)"
    if printf '%s' "${name}" | grep -qiE '^(con|prn|aux|nul|com[0-9]|lpt[0-9])$'; then
        name="$(printf 'ddev-%s' "${name}" | cut -c1-64)"
    fi
    export CLAUDE_CODE_PROJECT_DIR_NAME="${name}"
fi

exec "${CLAUDE_CODE_BIN}" "$@"
```

Dann: `chmod 755 web-build/claude-wrapper.sh`

- [ ] **Step 4: Tests laufen lassen, Erfolg prüfen**

Run: `bats tests/wrapper.bats`
Expected: `9 tests, 0 failures`

- [ ] **Step 5: Commit (nach Rückfrage beim User)**

```bash
git add web-build/claude-wrapper.sh tests/wrapper.bats
git commit -m "feat(addon): add claude wrapper naming state dir after ddev project"
```

---

### Task 2: Add-on-Gerüst mit Integrationstests

**Files:**
- Create: `install.yaml`
- Create: `web-build/Dockerfile.claude-code`
- Create: `config.claude-code.yaml`
- Move: `ddev-example/commands/web/claude` → `commands/web/claude`
- Delete: `ddev-example/` (vollständig)
- Test: `tests/test.bats`

**Interfaces:**
- Consumes: `web-build/claude-wrapper.sh` aus Task 1
- Produces: installierbares Add-on `claude-code`. `tests/test.bats` enthält `setup`/`teardown` und die Helper-Funktion `install_addon`, außerdem die Env-Variablen `DIR`, `PROJNAME=test-ddev-claude-image`, `TESTDIR` und `CACHE_DIR` (isoliertes Cache-Verzeichnis). Task 3 fügt dieser Datei Tests hinzu und erweitert `config.claude-code.yaml`.

- [ ] **Step 1: Failing Integrationstests schreiben**

`tests/test.bats`:

```bash
#!/usr/bin/env bats
# Integration tests for the claude-code DDEV add-on.
# Run from the repo root: bats tests/test.bats
# Needs ddev, docker and bats-core with bats-support, bats-assert, bats-file.

setup() {
  set -eu -o pipefail
  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH:-}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  bats_load_library bats-support
  bats_load_library bats-assert
  bats_load_library bats-file

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export PROJNAME="test-ddev-claude-image"
  mkdir -p ~/tmp
  export TESTDIR="$(mktemp -d ~/tmp/${PROJNAME}.XXXXXX)"
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  # Isolated cache dir, so the developer's real Claude login is never touched.
  export CACHE_DIR="/mnt/ddev-global-cache/claude-code-test-$$-${RANDOM}"

  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"
  run ddev config --project-name="${PROJNAME}" --project-tld=ddev.site
  assert_success
  cat > .ddev/config.test.yaml <<EOF
web_environment:
  - CLAUDE_CODE_CACHE_DIR=${CACHE_DIR}
EOF
  run ddev start -y
  assert_success
}

teardown() {
  set -eu -o pipefail
  ddev exec rm -rf "${CACHE_DIR}" >/dev/null 2>&1 || true
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}"
}

install_addon() {
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
}

@test "claude runs via ddev exec and ddev claude" {
  install_addon
  run ddev exec claude --version
  assert_success
  assert_output --partial "Claude Code"
  run ddev claude --version
  assert_success
  assert_output --partial "Claude Code"
}

@test "per-project state dir is named after the DDEV project" {
  install_addon
  # The API call fails on purpose (invalid key); Claude still writes the session.
  ddev exec 'ANTHROPIC_API_KEY=sk-ant-invalid timeout 60 claude -p hi' >/dev/null 2>&1 || true
  ddev exec 'mkdir -p /var/www/html/sub && cd /var/www/html/sub && ANTHROPIC_API_KEY=sk-ant-invalid timeout 60 claude -p hi' >/dev/null 2>&1 || true
  run ddev exec ls -A "${CACHE_DIR}/.claude/projects"
  assert_success
  # Exactly one dir, named after the project -- no -var-www-html(-sub).
  assert_output "${PROJNAME}"
}

@test "coexists with a project's own web-build Dockerfile" {
  mkdir -p .ddev/web-build
  echo 'RUN touch /usr/local/share/project-dockerfile-applied' > .ddev/web-build/Dockerfile
  install_addon
  run ddev exec test -f /usr/local/share/project-dockerfile-applied
  assert_success
  run ddev exec claude --version
  assert_success
}

@test "add-on remove deletes all project files" {
  install_addon
  run ddev add-on remove claude-code
  assert_success
  assert_file_not_exist .ddev/web-build/Dockerfile.claude-code
  assert_file_not_exist .ddev/web-build/claude-wrapper.sh
  assert_file_not_exist .ddev/commands/web/claude
  assert_file_not_exist .ddev/config.claude-code.yaml
}
```

- [ ] **Step 2: Tests laufen lassen, Fehlschlag prüfen**

Run: `bats tests/test.bats`
Expected: alle 4 Tests FAIL in `install_addon`, weil `ddev add-on get` keine `install.yaml` findet.

- [ ] **Step 3: `install.yaml` anlegen**

```yaml
name: claude-code

project_files:
  - web-build/Dockerfile.claude-code
  - web-build/claude-wrapper.sh
  - commands/web/claude
  - config.claude-code.yaml

ddev_version_constraint: '>= v1.24.0'
```

- [ ] **Step 4: `web-build/Dockerfile.claude-code` anlegen**

```dockerfile
#ddev-generated
# Pulls the prebuilt Claude Code binary into DDEV's web image and puts a small
# wrapper in front of it (see claude-wrapper.sh). DDEV appends this fragment
# after its own `FROM $BASE_IMAGE`; files in .ddev/web-build are the build context.
#
# To pin a version (e.g. :2.1.235), remove the #ddev-generated line and change the tag.
COPY --from=ghcr.io/avhulst/claude-code:latest /usr/local/bin/claude /usr/local/lib/claude-code/claude
COPY --chmod=755 claude-wrapper.sh /usr/local/bin/claude
```

- [ ] **Step 5: `commands/web/claude` verschieben**

```bash
mkdir -p commands/web
git mv ddev-example/commands/web/claude commands/web/claude
```

Der Inhalt bleibt unverändert (hat bereits `#ddev-generated`):

```bash
#!/bin/bash
#ddev-generated

## Description: Claude Code
## Usage: claude
## Example: ddev claude [...]

claude "$@"
```

- [ ] **Step 6: `config.claude-code.yaml` anlegen (ohne Migration, die kommt in Task 3)**

```yaml
#ddev-generated
# Claude Code state persistence for the claude-code add-on.
#
# Claude's config lives in DDEV's global cache volume, which survives
# `ddev restart`, `ddev rebuild`, `ddev poweroff` and `ddev delete`, stays out
# of Mutagen sync and never lands in git. The claude wrapper points
# CLAUDE_CONFIG_DIR there; login, settings and plugins are shared across
# projects, sessions and memory are kept per DDEV project.
hooks:
    post-start:
        - exec: |
              set -eu
              cache_dir="${CLAUDE_CODE_CACHE_DIR:-/mnt/ddev-global-cache/claude-code/shared}"
              mkdir -p "${cache_dir}/.claude"
```

- [ ] **Step 7: Rest von `ddev-example/` löschen**

```bash
git rm -r ddev-example
```

Damit sind `ddev-example/web-build/Dockerfile`, `ddev-example/config.claude.yaml` und `ddev-example/.homeadditions/.bashrc.d/local-bin-path.sh` entfernt. Kontrolle: `ls ddev-example` → `No such file or directory`.

- [ ] **Step 8: Tests laufen lassen, Erfolg prüfen**

Run: `bats tests/test.bats`
Expected: `4 tests, 0 failures`

Schlägt „per-project state dir is named after the DDEV project" fehl und die Ausgabe zeigt `-var-www-html`, dann greift `CLAUDE_CODE_PROJECT_DIR_NAME` nicht. In dem Fall mit `ddev exec env | grep CLAUDE` prüfen, ob der Wrapper läuft (`command -v claude` muss `/usr/local/bin/claude` sein). **Nicht** den Test anpassen.

- [ ] **Step 9: Wrapper-Tests erneut laufen lassen**

Run: `bats tests/wrapper.bats`
Expected: `9 tests, 0 failures`

- [ ] **Step 10: Commit (nach Rückfrage beim User)**

```bash
git add install.yaml web-build/Dockerfile.claude-code config.claude-code.yaml commands/web/claude tests/test.bats
git commit -m "feat(addon): turn ddev-example into installable ddev add-on"
```

(Die `git mv`/`git rm`-Änderungen aus Step 5 und 7 sind bereits gestaged.)

---

### Task 3: Migration vom alten Layout

**Files:**
- Modify: `config.claude-code.yaml` (Hook um die Migration erweitern)
- Test: `tests/test.bats` (drei Tests anhängen)

**Interfaces:**
- Consumes: `install_addon`, `CACHE_DIR`, `PROJNAME` aus `tests/test.bats` (Task 2)
- Produces: Hook verschiebt `$CLAUDE_CODE_CACHE_DIR/.claude.json` nach `$CLAUDE_CODE_CACHE_DIR/.claude/.claude.json`, wenn das Ziel fehlt

- [ ] **Step 1: Failing Tests anhängen**

Am Ende von `tests/test.bats` einfügen:

```bash
@test "migrates legacy .claude.json and keeps existing state" {
  install_addon
  # Old layout: .claude.json next to .claude/, credentials inside .claude/.
  ddev exec "rm -f ${CACHE_DIR}/.claude/.claude.json && echo '{\"legacy\":true}' > ${CACHE_DIR}/.claude.json && echo creds > ${CACHE_DIR}/.claude/.credentials.json"
  run ddev restart -y
  assert_success
  run ddev exec cat "${CACHE_DIR}/.claude/.claude.json"
  assert_output '{"legacy":true}'
  run ddev exec test -e "${CACHE_DIR}/.claude.json"
  assert_failure
  run ddev exec cat "${CACHE_DIR}/.claude/.credentials.json"
  assert_output "creds"

  # A second restart must be a no-op.
  run ddev restart -y
  assert_success
  run ddev exec cat "${CACHE_DIR}/.claude/.claude.json"
  assert_output '{"legacy":true}'
}

@test "migration never overwrites an existing config" {
  install_addon
  ddev exec "echo '{\"new\":true}' > ${CACHE_DIR}/.claude/.claude.json && echo '{\"legacy\":true}' > ${CACHE_DIR}/.claude.json"
  run ddev restart -y
  assert_success
  run ddev exec cat "${CACHE_DIR}/.claude/.claude.json"
  assert_output '{"new":true}'
  run ddev exec cat "${CACHE_DIR}/.claude.json"
  assert_output '{"legacy":true}'
}

@test "re-installing the add-on keeps login state" {
  install_addon
  ddev exec "echo creds > ${CACHE_DIR}/.claude/.credentials.json"
  install_addon
  run ddev exec cat "${CACHE_DIR}/.claude/.credentials.json"
  assert_output "creds"
}
```

- [ ] **Step 2: Tests laufen lassen, Fehlschlag prüfen**

Run: `bats tests/test.bats --filter "migrat|re-installing"`
Expected: „migrates legacy .claude.json …" FAIL (`cat: …/.claude/.claude.json: No such file or directory`). Die beiden anderen Tests passen schon, weil der Hook bisher gar nichts verschiebt.

- [ ] **Step 3: Migration im Hook implementieren**

`config.claude-code.yaml`, der `exec`-Block wird zu:

```yaml
        - exec: |
              set -eu
              cache_dir="${CLAUDE_CODE_CACHE_DIR:-/mnt/ddev-global-cache/claude-code/shared}"
              mkdir -p "${cache_dir}/.claude"
              # Migrate the pre-add-on layout: with CLAUDE_CONFIG_DIR set, Claude
              # keeps .claude.json inside the config dir. Never overwrite.
              if [ -f "${cache_dir}/.claude.json" ] && [ ! -e "${cache_dir}/.claude/.claude.json" ]; then
                  mv "${cache_dir}/.claude.json" "${cache_dir}/.claude/.claude.json"
              fi
```

- [ ] **Step 4: Gesamte Suite laufen lassen, Erfolg prüfen**

Run: `bats tests/wrapper.bats tests/test.bats`
Expected: `16 tests, 0 failures`

- [ ] **Step 5: Commit (nach Rückfrage beim User)**

```bash
git add config.claude-code.yaml tests/test.bats
git commit -m "feat(addon): migrate legacy claude.json into config dir"
```

---

### Task 4: CI-Workflow für Add-on-Tests

**Files:**
- Create: `.github/workflows/test.yml`

**Interfaces:**
- Consumes: `tests/*.bats` aus Task 1–3 (die Action führt alle `.bats`-Dateien in `tests/` aus)
- Produces: GitHub-Workflow `tests`

- [ ] **Step 1: Workflow anlegen**

```yaml
name: tests

# Runs the add-on tests (tests/*.bats) on every push/PR and weekly, so a
# behaviour change in a new Claude Code release (e.g. CLAUDE_CODE_PROJECT_DIR_NAME
# being dropped) shows up even without code changes here.
on:
  pull_request:
  push:
    branches: [main]
    paths-ignore:
      - "**.md"
  schedule:
    - cron: "30 7 * * 1" # Mondays 07:30 UTC, after the daily image build
  workflow_dispatch:
    inputs:
      debug_enabled:
        description: "Debug with tmate"
        type: boolean
        default: false

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.head_ref || github.run_id }}
  cancel-in-progress: true

jobs:
  tests:
    strategy:
      matrix:
        ddev_version: [stable, HEAD]
      fail-fast: false
    runs-on: ubuntu-latest
    steps:
      - uses: ddev/github-action-add-on-test@v2
        with:
          ddev_version: ${{ matrix.ddev_version }}
          token: ${{ secrets.GITHUB_TOKEN }}
          debug_enabled: ${{ github.event.inputs.debug_enabled }}
          addon_repository: ${{ github.repository }}
          addon_ref: ${{ github.ref }}
```

- [ ] **Step 2: Syntax prüfen**

Run: `command -v actionlint >/dev/null && actionlint .github/workflows/test.yml || ruby -ryaml -e 'YAML.load_file(".github/workflows/test.yml"); puts "yaml ok"'`
Expected: keine Ausgabe von actionlint bzw. `yaml ok`

Hinweis: Die echte Verifikation passiert erst beim ersten Push bzw. PR. Pushen ist nicht Teil dieses Plans und passiert nur auf Anweisung des Users.

- [ ] **Step 3: Commit (nach Rückfrage beim User)**

```bash
git add .github/workflows/test.yml
git commit -m "ci: add ddev add-on test workflow"
```

---

### Task 5: README auf Add-on umstellen

**Files:**
- Modify: `README.md` (vollständig ersetzen)

**Interfaces:**
- Consumes: Namen und Pfade aus Task 1–4 (`claude-code`, `CLAUDE_CODE_CACHE_DIR`, `web-build/Dockerfile.claude-code`, …)
- Produces: Nutzerdoku

- [ ] **Step 1: README ersetzen**

`README.md` komplett durch folgenden Inhalt ersetzen:

````markdown
# ddev-claude-image

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
ddev add-on get avhulst/ddev-claude-image
ddev restart
ddev claude
```

`claude` funktioniert auch in `ddev ssh`, `ddev exec` und in Hooks, überall mit
derselben Konfiguration.

## Authentifizierung (Pro/Max/Team)

- **Interaktiv:** beim ersten `ddev claude` `/login` durchlaufen. Der Login liegt im
  globalen Cache und übersteht `restart`, `rebuild`, `poweroff` und `delete`.
- **Headless / zum Teilen:** auf einer Maschine mit Browser `claude setup-token`
  ausführen und den Token über eine **gitignorte** lokale Config einspeisen:

  ```yaml
  # .ddev/config.token.local.yaml  (gitignored)
  web_environment:
    - CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
  ```

**Niemals** Credentials oder Token ins Image backen.

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
   `shared/.claude.json` wandert nach `shared/.claude/.claude.json`.
4. Alte Sessions und Memory aller Projekte liegen gemischt in
   `shared/.claude/projects/-var-www-html/`. Wer sie behalten will, verschiebt sie
   von Hand in den neuen Projektordner:

   ```bash
   ddev exec 'cd /mnt/ddev-global-cache/claude-code/shared/.claude/projects && mkdir -p "$DDEV_PROJECT" && cp -a -- -var-www-html/. "$DDEV_PROJECT"/'
   ```

## Version pinnen

`.ddev/web-build/Dockerfile.claude-code` bezieht standardmäßig `:latest`. Zum Pinnen die
Zeile `#ddev-generated` entfernen (sonst überschreibt ein Add-on-Update die Datei) und
den Tag ändern, z. B. `ghcr.io/avhulst/claude-code:2.1.235`.

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
ddev add-on remove claude-code
ddev restart
```

Login, Sessions und Memory im globalen Cache bleiben erhalten. Komplett löschen
(betrifft alle Projekte):

```bash
ddev exec rm -rf /mnt/ddev-global-cache/claude-code
```

## Tests

```bash
brew install bats-core && brew tap bats-core/bats-core \
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
````

- [ ] **Step 2: Doku gegen Code prüfen**

Run:
```bash
grep -n "ddev-example" README.md; \
grep -o 'CLAUDE_[A-Z_]*\|DISABLE_AUTOUPDATER' README.md | sort -u; \
grep -o 'CLAUDE_[A-Z_]*\|DISABLE_AUTOUPDATER' web-build/claude-wrapper.sh | sort -u
```
Expected: `ddev-example` taucht nur im Abschnitt „Umstieg" auf. Jede Variable aus dem Wrapper kommt in der README vor (`CLAUDE_CODE_OAUTH_TOKEN` steht zusätzlich nur in der README, `CLAUDE_CODE_BIN` ist als Test-Hook bewusst undokumentiert).

- [ ] **Step 3: Commit (nach Rückfrage beim User)**

```bash
git add README.md
git commit -m "docs: rewrite readme for ddev add-on"
```

---

### Task 6: Manueller End-to-End-Check (mit echtem Login)

**Files:** keine

**Interfaces:**
- Consumes: das fertige Add-on
- Produces: Bestätigung in einem echten Projekt

- [ ] **Step 1: Zwei Wegwerf-Projekte mit dem Add-on starten**

```bash
for p in cc-e2e-a cc-e2e-b; do
  mkdir -p ~/tmp/$p && cd ~/tmp/$p && ddev config --project-name=$p --auto \
    && ddev add-on get /Users/avh/Projekte/docker/ddev-claude-image && ddev start -y
done
```

- [ ] **Step 2: In beiden einloggen bzw. prüfen, dass der Login geteilt ist**

In `cc-e2e-a`: `ddev claude`, `/login` durchlaufen, eine Nachricht senden, beenden.
In `cc-e2e-b`: `ddev claude` starten. Erwartet: **kein** erneuter Login nötig. Eine Nachricht senden, beenden.

- [ ] **Step 3: Trennung prüfen**

Run: `cd ~/tmp/cc-e2e-a && ddev exec ls /mnt/ddev-global-cache/claude-code/shared/.claude/projects`
Expected: enthält `cc-e2e-a` und `cc-e2e-b` (plus ggf. ein altes `-var-www-html`, falls das Layout früher schon benutzt wurde)

In `cc-e2e-b`: `ddev claude --resume`. Erwartet: Es wird nur die Session aus `cc-e2e-b` angeboten.

- [ ] **Step 4: Aufräumen**

```bash
for p in cc-e2e-a cc-e2e-b; do ddev delete -Oy $p; rm -rf ~/tmp/$p; done
```

(Der Login im globalen Cache bleibt, genau wie gewünscht.)
