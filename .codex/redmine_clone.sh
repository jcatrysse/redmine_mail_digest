#!/usr/bin/env bash
set -euo pipefail

REDMINE_VERSION="${1:-5.1-stable}"   # 5.1-stable, 6.0-stable, 6.1-stable
REDMINE_DIR="${REDMINE_DIR:-redmine}"
REDMINE_REPO_URL="https://github.com/redmine/redmine.git"

if ! git ls-remote --heads "$REDMINE_REPO_URL" "$REDMINE_VERSION" | grep -q "$REDMINE_VERSION"; then
  echo "ERROR: Redmine branch '$REDMINE_VERSION' not found on $REDMINE_REPO_URL" >&2
  exit 1
fi

if [ ! -d "$REDMINE_DIR/.git" ]; then
  git clone --depth 1 --branch "$REDMINE_VERSION" "$REDMINE_REPO_URL" "$REDMINE_DIR"
else
  (
    cd "$REDMINE_DIR"
    # "+": the GEOxyz branch is rebased upstream from time to time; follow it.
    git fetch --depth 1 origin "+$REDMINE_VERSION:refs/remotes/origin/$REDMINE_VERSION"
    # test_setup.sh appends rails-controller-testing to Redmine's Gemfile; that local
    # change would block the checkout, so set it aside and put it back afterwards.
    extra_gems="$(git diff --no-color -U0 -- Gemfile | sed -n 's/^+\([^+].*\)$/\1/p')"
    git checkout -- Gemfile
    git checkout -B "$REDMINE_VERSION" "origin/$REDMINE_VERSION"
    [ -z "$extra_gems" ] || printf '%s\n' "$extra_gems" >> Gemfile
  )
fi

PLUGIN_NAME="$(basename "$(pwd)")"
mkdir -p "$REDMINE_DIR/plugins/$PLUGIN_NAME"
rsync -a --delete --exclude "$REDMINE_DIR/" --exclude .git/ ./ "$REDMINE_DIR/plugins/$PLUGIN_NAME/"
