#!/usr/bin/env bash
# save_data.sh -- commits data/ and pushes it, pulling first if the repo moved on
# (for example you edited a file on GitHub while the bot was running).
# Replies are only sent after this succeeds.
set -euo pipefail

git config user.name "tracker-bot"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

git add data
if git diff --staged --quiet; then
  echo "No data changes."
  exit 0
fi
git commit -q -m "Update data"

for attempt in 1 2 3; do
  if git push -q; then
    echo "Data saved."
    exit 0
  fi
  echo "Push rejected (attempt $attempt). Pulling the latest changes and retrying..."
  sleep $((attempt * 5))
  if ! git pull --rebase -q; then
    git rebase --abort || true
    echo "::error::Your data changed on GitHub at the same time and could not be merged automatically."
    exit 1
  fi
done

echo "::error::Could not push the data after 3 attempts."
exit 1
