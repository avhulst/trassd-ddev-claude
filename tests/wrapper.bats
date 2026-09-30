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
