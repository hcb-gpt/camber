#!/bin/bash
# Keeps chad-device branch in sync with master
# Run manually or via cron/launchd
set -e
cd "$(git rev-parse --show-toplevel)"
git fetch origin
git checkout chad-device
git merge origin/master --ff-only || {
  echo "FF merge failed — master has diverged. Resetting chad-device to master."
  git reset --hard origin/master
}
git push origin chad-device --force-with-lease
echo "chad-device synced to $(git rev-parse --short HEAD)"
