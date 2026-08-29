# Publishing & consuming chamber from private ECR

This fork publishes its container image to a **private Amazon ECR** repository instead of Docker Hub.
CI pushes automatically on release tags using GitHub OIDC (no long-lived AWS keys); you can also push
manually with the `publish-ecr` Make target.

- ECR repo: `vendored/chamber` (the `vendored/` namespace signals an externally-derived image).
- Image tags per release: `<version>-<fork-suffix>`, `<major.minor.patch>`, `<major.minor>`,
  `<major>`, and `latest`. The leading `v` is stripped, so git tag `v3.1.0-reevo.1` →
  image tag `3.1.0-reevo.1`.
- The `-reevo.N` suffix denotes our Nth build on top of that upstream version.

## One-time setup

### 1. Create the ECR repository

```
aws ecr create-repository \
  --repository-name vendored/chamber \
  --region <region> \
  --image-scanning-configuration scanOnPush=true
```

### 2. Create the GitHub OIDC provider + IAM role

If the account doesn't already have it, add `token.actions.githubusercontent.com` as an IAM OIDC
identity provider. Then create a role whose **trust policy** restricts to this repo's tags:

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
    "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:ReevoAI/chamber:ref:refs/tags/*" }
  }
}
```

Attach a **permissions policy** granting ECR push:

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
        "ecr:PutImage"
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
| `FORK_SUFFIX` | `reevo.1` | Optional fork build marker. |

## Releasing (CI)

Push a tag; the `Release` workflow builds multi-arch (`linux/amd64,linux/arm64`) and pushes to ECR:

```
git tag v3.1.0-reevo.1
git push origin v3.1.0-reevo.1
```

## Publishing manually (local)

Requires Docker (with buildx) and AWS credentials for an identity allowed to push:

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
