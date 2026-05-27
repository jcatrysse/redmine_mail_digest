#!/usr/bin/env bash
set -euo pipefail

REDMINE_DIR="${REDMINE_DIR:-redmine}"
PLUGIN_NAME="$(basename "$(pwd)")"
MISE_BIN="${MISE_BIN:-mise}"

detect_ruby_version() {
  local version=""

  if [ -f ".ruby-version" ]; then
    version="$(tr -d '\n' < .ruby-version)"
  elif [ -f "Gemfile" ]; then
    local ruby_line=""
    ruby_line="$(grep -E "^[[:space:]]*ruby " Gemfile | head -n 1 || true)"

    version="$(echo "$ruby_line" | sed -E -n "s/.*ruby[[:space:]]*['\\\"]([0-9]+\\.[0-9]+(\\.[0-9]+)?)[\"'].*$/\\1/p")"
    if [ -z "$version" ]; then
      version="$(echo "$ruby_line" | sed -E -n "s/.*~>[[:space:]]*([0-9]+\\.[0-9]+(\\.[0-9]+)?).*/\\1/p")"
    fi
    if [ -z "$version" ]; then
      local upper=""
      upper="$(echo "$ruby_line" | sed -E -n "s/.*<[[:space:]]*([0-9]+\\.[0-9]+(\\.[0-9]+)?).*/\\1/p")"
      if [ -n "$upper" ]; then
        local major="${upper%%.*}"
        local minor="${upper#*.}"
        minor="${minor%%.*}"
        if [ "$minor" -gt 0 ]; then
          minor=$((minor - 1))
        fi
        version="${major}.${minor}"
      fi
    fi
  fi

  echo "$version"
}

cd "$REDMINE_DIR"
mkdir -p tmp/test-results

RUBY_VERSION="$(detect_ruby_version)"
PLUGIN_DIR="plugins/$PLUGIN_NAME"
SPEC_DIR="$PLUGIN_DIR/spec"
TEST_DIR="$PLUGIN_DIR/test"

run_command() {
  if [ -n "$RUBY_VERSION" ]; then
    if command -v "$MISE_BIN" >/dev/null 2>&1; then
      "$MISE_BIN" exec "ruby@$RUBY_VERSION" -- "$@"
    else
      echo "mise is required to run tests with Ruby $RUBY_VERSION. Please run ./.codex/test_setup.sh first." >&2
      exit 1
    fi
  else
    if ! command -v bundle >/dev/null 2>&1; then
      echo "Bundler is not available. Please run ./.codex/test_setup.sh first." >&2
      exit 1
    fi
    "$@"
  fi
}

ran_tests=false

if [ -d "$SPEC_DIR" ]; then
  run_command bundle exec rspec "$SPEC_DIR" --format progress
  ran_tests=true
fi

if [ -d "$TEST_DIR" ]; then
  run_command bundle exec rake redmine:plugins:test NAME="$PLUGIN_NAME"
  ran_tests=true
fi

if [ "$ran_tests" = false ]; then
  echo "No spec/ or test/ directory found for $PLUGIN_NAME." >&2
  exit 1
fi
