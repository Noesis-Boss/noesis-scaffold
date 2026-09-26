#!/usr/bin/env bash
# Empty directory -> live public URL, in one command.
#
#   ./bootstrap.sh <repo-name>
#
# Idempotent: safe to re-run. Creates the GitHub repo if missing, enables
# Pages in Actions mode, pushes main, waits for the deploy, prints the URL.
#
# Requires: gh CLI authenticated (see the `infrastructure` doc on NOE-4).
set -euo pipefail

REPO_NAME="${1:-}"
if [[ -z "$REPO_NAME" ]]; then
  echo "usage: $0 <repo-name>" >&2
  exit 2
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "error: gh is not authenticated. Connect GitHub via Paperclip first." >&2
  exit 1
fi

OWNER="$(gh api user --jq .login)"
SLUG="$OWNER/$REPO_NAME"

# 1. Local repo.
git rev-parse --git-dir >/dev/null 2>&1 || git init -b main
git add -A
git diff --cached --quiet || git commit -m "Initial commit

Co-Authored-By: Paperclip <noreply@paperclip.ing>"

# 2. Remote repo. Public, so Actions minutes and Pages are free.
if gh repo view "$SLUG" >/dev/null 2>&1; then
  echo "repo $SLUG already exists"
else
  gh repo create "$SLUG" --public --disable-wiki
fi
git remote get-url origin >/dev/null 2>&1 \
  || git remote add origin "https://github.com/$SLUG.git"

# 3. Pages in Actions mode. Must exist before the workflow runs, or
#    deploy-pages fails with "Resource not accessible by integration".
gh api -X POST "repos/$SLUG/pages" -f build_type=workflow >/dev/null 2>&1 \
  || gh api -X PUT "repos/$SLUG/pages" -f build_type=workflow >/dev/null 2>&1 \
  || true

# 4. Push -> Actions deploys.
git push -u origin main

# 5. Wait for the deploy and report honestly.
echo "waiting for deploy..."
sleep 5
gh run watch --repo "$SLUG" --exit-status \
  "$(gh run list --repo "$SLUG" --limit 1 --json databaseId --jq '.[0].databaseId')"

URL="$(gh api "repos/$SLUG/pages" --jq .html_url)"
echo
echo "live: $URL"
curl -sS -o /dev/null -w "HTTP %{http_code}\n" --retry 10 --retry-all-errors \
  --retry-delay 6 "$URL"
