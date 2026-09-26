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

# Agent runners often have no git identity, and `git commit` hard-fails with
# "Author identity unknown" rather than defaulting. Set a repo-local one.
git config user.email >/dev/null 2>&1 \
  || git config user.email "noreply@paperclip.ing"
git config user.name >/dev/null 2>&1 \
  || git config user.name "Noesis"

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

# 5. Find the run for *this* commit. Never `gh run list --limit 1`: that races
#    run registration after a push, and on a re-run it happily watches an older
#    unrelated run and reports a false success.
HEAD_SHA="$(git rev-parse HEAD)"
echo "waiting for the deploy run for $HEAD_SHA ..."
RUN_ID=""
for _ in $(seq 1 30); do
  RUN_ID="$(gh run list --repo "$SLUG" --commit "$HEAD_SHA" --limit 1 \
    --json databaseId --jq '.[0].databaseId // empty')"
  [[ -n "$RUN_ID" ]] && break
  sleep 4
done

# Re-running on an unchanged tree pushes nothing, so no new run exists.
# Dispatch one rather than silently skipping verification.
if [[ -z "$RUN_ID" ]]; then
  echo "no run for HEAD; dispatching deploy.yml"
  gh workflow run deploy.yml --repo "$SLUG" --ref main
  for _ in $(seq 1 30); do
    RUN_ID="$(gh run list --repo "$SLUG" --workflow deploy.yml --limit 1 \
      --json databaseId --jq '.[0].databaseId // empty')"
    [[ -n "$RUN_ID" ]] && break
    sleep 4
  done
fi

if [[ -z "$RUN_ID" ]]; then
  echo "error: no Actions run ever appeared. Check the Actions tab for $SLUG." >&2
  exit 1
fi

gh run watch --repo "$SLUG" --exit-status "$RUN_ID"

# 6. A green run is not proof the site is live. Verify with -f so an HTTP 404
#    counts as a failure and actually retries: without -f, curl calls a 404 a
#    success, --retry-all-errors never fires, and first-deploy propagation lag
#    prints "HTTP 404" while the script exits 0.
URL="$(gh api "repos/$SLUG/pages" --jq .html_url)"
echo
echo "live: $URL"
if ! curl -fsS -o /dev/null -w "HTTP %{http_code}\n" \
     --retry 20 --retry-all-errors --retry-delay 6 "$URL"; then
  echo "error: deploy run was green but $URL did not serve 200." >&2
  echo "       Usually a wrong base path — see the infrastructure doc." >&2
  exit 1
fi
