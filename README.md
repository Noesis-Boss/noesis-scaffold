# noesis-scaffold

The starting point for every Noesis build. Copy this directory, put your site in
`site/`, run `./bootstrap.sh <repo-name>`, get a public URL.

## Stack

| Layer      | Choice                    |
| ---------- | ------------------------- |
| Repo host  | GitHub (public repo)      |
| CI         | GitHub Actions            |
| Static host| GitHub Pages              |
| App host   | Cloudflare Workers        |
| Database   | Cloudflare D1             |

Full rationale, free-tier limits, and the app/database variants live in the
`infrastructure` document on NOE-4.

## Deploy

```sh
./bootstrap.sh my-project   # first time: creates repo, enables Pages, deploys
git push                    # every time after: Actions redeploys automatically
```

## Check a deploy

```sh
gh run list --limit 1                 # workflow status
gh api repos/{owner}/{repo}/pages --jq .html_url   # the live URL
curl -sI <url> | head -1              # should be HTTP/2 200
```

## Framework builds

`site/` is served as-is. If your project has a build step, add setup-node,
install, and build steps to `.github/workflows/deploy.yml` and point
`upload-pages-artifact`'s `path` at the build output. Set the framework's base
path to `/<repo-name>/` — Pages serves project sites from a subpath, and a
site built for `/` will load a blank page with 404s on every asset.
