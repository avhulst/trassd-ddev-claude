#!/bin/bash
#ddev-generated
# Claude Code wrapper installed by the trassd-ddev-claude DDEV add-on.
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
