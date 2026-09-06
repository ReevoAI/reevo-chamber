# Reevo fork of `segmentio/chamber`

This repository (`github.com/ReevoAI/chamber`) is a private fork of
[`segmentio/chamber`](https://github.com/segmentio/chamber). We maintain it so we can pick up Go and
dependency security fixes on our own schedule and publish images we control to our private ECR,
instead of consuming the public `segment/chamber` image from Docker Hub.

The Go **module path is intentionally unchanged** (`github.com/segmentio/chamber/v3`) — renaming it
would churn every import for no security benefit.

## Divergence ledger

Everything below is deliberately different from upstream. Keep this list current — it is the source
of truth when resolving an upstream merge conflict (resolve **in our favor** for these files).

| Area | File(s) | What we changed / why |
| --- | --- | --- |
| Go toolchain | `Dockerfile` (`FROM golang:…-alpine`) | Pinned to the latest stable Go (currently `1.27.0`) so released binaries/images are built with a supported, patched toolchain. |
| Go CI matrix | `.github/workflows/build.yml`, `.github/workflows/release.yml` | Test/build/release on the two Go majors still in Go's security-support window (currently `1.27.x`, `1.26.x`). |
| Go module floor | `go.mod` (`go` directive) | Set to the oldest major we test (currently `1.26.0`). |
| Image registry | `Makefile.release` (`publish-ecr`), `.github/workflows/release.yml` (`publish-ecr` job) | Replaced Docker Hub publishing (`segment/chamber`) with a push to our **private ECR** using GitHub OIDC (no long-lived AWS keys). See [`docs/ECR.md`](./ECR.md). |
| Version tracking | `VERSION`, `.github/workflows/release.yml` | Base version lives in a `VERSION` file, bumped by hand via PR. The `Release` workflow (manual `workflow_dispatch`, **no version/tag input**) reads it and auto-increments the `-reevo.N` build suffix from the tags already in ECR. |
| Release artifacts | `Makefile.release` (`dist`), `.github/workflows/build.yml`, `.github/workflows/release.yml` | Dropped `.deb`/`.rpm` packaging (nfpm) and GitHub Releases — the fork ships **only** the ECR image. `dist` still builds the raw binaries + sha256sums for CI. |
| Action pinning | `.github/workflows/*.yml` | All third-party actions upgraded to their latest release and pinned to a full commit SHA (with a `# vX.Y.Z` comment) for supply-chain hardening. When bumping, update both the SHA and the comment. |
| Docs | `docs/ECR.md`, `docs/FORK.md` | Fork-specific operational docs. |

Unchanged from upstream: all Go source, the module path, `WORKDIR`, and the Codecov slug
(`segmentio/chamber`).

## Keeping the fork legible

- Prefix fork-only commits with `reevo:` so `git log --grep '^reevo:'` shows exactly what we carry.
- Keep divergence concentrated in the files above; avoid editing upstream Go source.
- Update the ledger in this file whenever the divergence changes.

## Syncing with upstream

### One-time setup

```
git remote add upstream https://github.com/segmentio/chamber.git
git fetch upstream --tags
```

Prefer syncing to upstream **tagged releases** (e.g. `upstream v3.2.0`) rather than `master` HEAD, so
we adopt stable points.

### Periodic sync procedure

1. `git fetch upstream --tags`
2. Review what's new (scan the file list first):
   ```
   git log --oneline master..upstream/<tag>
   git diff master...upstream/<tag>
   ```
3. Triage each change with the rubric below.
4. Create a sync branch and merge:
   ```
   git switch -c sync/upstream-<version>
   git merge <tag>          # e.g. git merge v3.2.0
   ```
5. Resolve conflicts **favoring ours** for the files in the divergence ledger; take upstream
   everywhere else.
6. `go mod tidy && make test`, build the image locally, open a PR. On merge, set `VERSION` to the new
   upstream base and run the `Release` workflow → this publishes the image (auto-incrementing
   `-reevo.N`) to ECR (see [`docs/ECR.md`](./ECR.md)).

### Assessment rubric — what to bring in

- **Always take:** upstream security fixes; dependency bumps (Go toolchain, `aws-sdk-go-v2`,
  `golang.org/x/*` — especially crypto/net/sys); bug fixes to commands we use.
- **Review before taking:** CLI/behavior changes, new backends/features (do we actually need them?),
  and anything touching build/release plumbing (may collide with our ECR/Go changes).
- **Keep ours:** every row in the divergence ledger above. If upstream reworked one of those files,
  re-apply our change on top of theirs.
