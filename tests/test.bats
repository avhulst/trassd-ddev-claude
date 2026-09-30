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
