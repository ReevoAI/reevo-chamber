# Publishing & consuming chamber from private ECR

This fork publishes its container image to a **private Amazon ECR** repository instead of Docker Hub.
CI pushes when you run the `Release` workflow (see below); you can also push manually with the
`publish-ecr` Make target.

- ECR repo: `vendored/chamber` (the `vendored/` namespace signals an externally-derived image).
- Image tag per release: a **single, fully-specific tag** `<major.minor.patch>-reevo.N`. The base
  `<major.minor.patch>` is read from the repo's [`VERSION`](../VERSION) file (a leading `v` is
  stripped), so `VERSION=3.1.0` → image tag `3.1.0-reevo.1`. No floating tags (`latest`, `<major>`,
  `<major.minor>`, `<major.minor.patch>`) are pushed, so the repository can enforce an **immutable
  tag policy** — every push is a unique name and never collides.
- The `-reevo.N` suffix denotes our Nth build on top of that upstream version. `N` is **computed
  automatically** at release time: CI lists the existing `<version>-reevo.*` tags in ECR, takes the
  highest `N`, and adds 1. When you bump `VERSION`, no tags match the new prefix, so `N` resets to
  `1`.

## One-time setup

### 1. Create the ECR repository

```
aws ecr create-repository \
  --repository-name vendored/chamber \
  --region <region> \
  --image-tag-mutability IMMUTABLE \
  --image-scanning-configuration scanOnPush=true
```

The `IMMUTABLE` policy is safe here because each release pushes exactly one unique
`<version>-reevo.N` tag (no floating tags). To flip an existing repository:

```
aws ecr put-image-tag-mutability \
  --repository-name vendored/chamber \
  --image-tag-mutability IMMUTABLE \
  --region <region>
```

### 2. Create the GitHub OIDC provider + IAM role

If the account doesn't already have it, add `token.actions.githubusercontent.com` as an IAM OIDC
identity provider. Then create a role whose **trust policy** restricts to this repo's release branch:

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
    "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:ReevoAI/chamber:ref:refs/heads/main" }
  }
}
```

> The `Release` workflow runs from a branch (normally `main`), not a tag, so the OIDC `sub` is
> `repo:ReevoAI/chamber:ref:refs/heads/main`. The workflow's **Print OIDC sub claim** step logs the
> exact subject, so you can widen or adjust this condition (e.g. to run releases from another branch).

Attach a **permissions policy** granting ECR push and image listing (the release workflow lists
existing tags to compute the next `-reevo.N`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage",
        "ecr:ListImages"
      ],
      "Resource": "arn:aws:ecr:<region>:<account-id>:repository/vendored/chamber"
    }
  ]
}
```

### 3. Set GitHub Actions repository variables

Settings → Secrets and variables → Actions → **Variables**:

| Variable | Example | Notes |
| --- | --- | --- |
| `ECR_ROLE_ARN` | `arn:aws:iam::123456789012:role/github-chamber-ecr` | Role from step 2. |
| `AWS_REGION` | `us-east-1` | |
| `ECR_REGISTRY` | `123456789012.dkr.ecr.us-east-1.amazonaws.com` | Registry host. |
| `ECR_REPO` | `vendored/chamber` | Optional; defaults to `vendored/chamber`. |

> Neither the base version nor the `-reevo.N` suffix is a repo variable: the base comes from the
> [`VERSION`](../VERSION) file, and `-reevo.N` is computed automatically from the tags already in ECR.
> The Make target still honors a `FORK_SUFFIX` env var for local use.

## Releasing

The base version lives in the [`VERSION`](../VERSION) file (e.g. `3.1.0`) — the only thing you bump by
hand. The `-reevo.N` build number is automatic, and there is no version or tag input to fill in.

1. To move to a new upstream base, edit `VERSION` and merge it (normal PR). To cut another build on
   the current base, skip this step.
2. GitHub → **Actions** → **Release** → **Run workflow** (from `main`). With no inputs it reads
   `VERSION`, computes the next `-reevo.N` from ECR, builds for `linux/arm64`, and pushes the single
   immutable tag `<version>-reevo.N`. No GitHub release is created.

CLI equivalent:

```
gh workflow run Release --ref main
```

Re-running without bumping `VERSION` just produces the next `-reevo.N` on the same base
(`3.1.0-reevo.1`, `3.1.0-reevo.2`, …).

## Publishing manually (local)

Requires Docker (with buildx) and AWS credentials for an identity allowed to push. Locally you pass
`VERSION` and `FORK_SUFFIX` explicitly (CI derives them from the `VERSION` file and ECR):

```
aws ecr get-login-password --region <region> \
  | docker login --username AWS --password-stdin <account-id>.dkr.ecr.<region>.amazonaws.com

make -f Makefile.release publish-ecr \
  VERSION=v3.1.0 \
  ECR_REGISTRY=<account-id>.dkr.ecr.<region>.amazonaws.com \
  ECR_REPO=vendored/chamber \
  FORK_SUFFIX=reevo.1
```

## Pulling from ECR (instead of the public image)

```
aws ecr get-login-password --region <region> \
  | docker login --username AWS --password-stdin <account-id>.dkr.ecr.<region>.amazonaws.com

docker pull <account-id>.dkr.ecr.<region>.amazonaws.com/vendored/chamber:3.1.0-reevo.1
docker run --rm <account-id>.dkr.ecr.<region>.amazonaws.com/vendored/chamber:3.1.0-reevo.1 version
```

On ECS/EKS/CI runners with an ECR-pull IAM role, `docker login` is unnecessary — pulls are
authorized by the instance/task role.

Anywhere an image previously referenced the public image — e.g.
`COPY --from=segment/chamber:<tag> /chamber /usr/local/bin/chamber` — repoint `--from` to the ECR
image URI above.
