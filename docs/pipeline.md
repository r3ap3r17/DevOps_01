# Pipeline

GitHub Actions builds, tests, scans and deploys the three app services (`vote`, `result`, `worker`).
Redis and Postgres are stock images and are not built.

```
PR or push to main
  ├─ branch age      (PRs only) warns after 2 days, fails after 5
  ├─ static checks   action pinning, actionlint, hadolint
  └─ unit ×3         install, compile, load each service
        │  fail fast: nothing is built until all of these pass
        ▼
     build ×3        buildx, per-service layer cache in the GitHub Actions cache
        │            image saved once and handed to every later job
        ├─ scan ×3   Grype, fails on critical vulnerabilities that have a fix
        └─ integration   full stack in docker compose + upstream end-to-end test
              │
              ▼  (main only from here)
           publish ×3      push ghcr.io/<owner>/<repo>/<service>:sha-<commit>
              ▼
           staging         automatic
              ▼
           production      waits for a reviewer
```

## Files

| File | What it does |
|---|---|
| `.github/workflows/ci.yml` | The pipeline above |
| `.github/workflows/deploy.yml` | Points an environment at one commit's images. Called by CI, or run by hand |
| `.github/workflows/rollback.yml` | One-click rollback |
| `.github/dependabot.yml` | Weekly PRs that bump pinned actions |
| `ci/compose.yml` | Integration stack used by CI |
| `ci/deploy.sh`, `ci/rollback-target.sh` | Tag moves behind deploy and rollback |
| `ci/pin-actions.sh` | Rewrites `@vX.Y.Z` pins to commit SHAs |

## One-time setup in GitHub

1. **Environments.** Settings > Environments: create `staging` and `production`.
   On `production`, turn on *Required reviewers* and add yourself.
   Optionally limit both to the `main` branch under *Deployment branches*.
2. **Protect main.** Settings > Rules > Rulesets, targeting `main`:
   require a pull request, require linear history, block force pushes,
   and require these status checks: `branch age`, `static checks`, `unit (vote)`, `unit (result)`,
   `unit (worker)`, `scan (vote)`, `scan (result)`, `scan (worker)`, `integration`.
3. **Short-lived branches.** Settings > General: turn on *Automatically delete head branches*
   and allow only squash or rebase merges.
4. **Pin actions to SHAs.** The workflows pin exact versions (`@v5.0.0`). Run this once and commit the result:
   ```
   bash ci/pin-actions.sh
   ```
   It fails if a version does not exist, which is also a quick check of the pins.

Packages appear in GHCR after the first push to main. They are linked to the repo by the
`org.opencontainers.image.source` label, so the workflow's own token can keep pushing to them.

## Tags

- `sha-<full commit>` is written once and never overwritten. GHCR cannot lock tags, so `publish` refuses to push over an existing one.
- `staging`, `production` point at what each environment runs.
- `staging-previous`, `production-previous` point at what ran before. Rollback uses these.

Every service is rebuilt on every commit, so one commit always names a complete release.

Today "deploy" means moving these tags in the registry. No cluster exists yet.
In the Kubernetes milestone only the *Promote* step in `deploy.yml` changes:
it will write image digests into the manifests Argo CD watches.

## Rollback

From the Actions tab, run *rollback* and pick the environment. From a terminal:

```
gh workflow run rollback.yml -f environment=production
gh workflow run rollback.yml -f environment=production -f version=<commit>
```

Without a version, it returns to the release that ran before the current one.
Running it twice swaps back. To go further back, pass any commit that passed CI on main.
Production rollbacks still wait for approval, because they go through the same deploy job.

To deploy any older commit on purpose, run the *deploy* workflow with that commit.

## Measuring the cache

Run *ci* from the Actions tab with **no_cache** ticked to get a cold build time.
Then run it again without it, or push a commit, to compare.
Each build job's summary shows how many steps came from the cache.

## Known risks

- **The end-to-end test uses PhantomJS.** It comes from the upstream repo. Its original image no longer builds, so `ci/compose.yml` rebuilds it on a current base with the same test files. If the PhantomJS download breaks, this job is the one that fails.
- **The worker runs on .NET 7, which no longer gets security updates.** If the scan fails on it, the fix is moving the worker Dockerfile to .NET 8. The same applies to `node:18` in `result`.
- **Production deploys queue.** Only one deploy per environment runs at a time. A newer commit waiting for production approval replaces an older one that was also waiting.

## Not done yet

Canary or blue/green with Argo Rollouts needs a cluster, so it waits for the Kubernetes milestone.
