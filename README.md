# Monk Capsule Actions

GitHub Actions for provisioning and managing [Monk Capsules](https://monk.io) — fully isolated, prod-like preview environments for every branch.

This repository publishes a suite of composable actions used by the [Monk VS Code extension](https://github.com/monk-io/vscode-monk) and consumable directly from any GitHub workflow.

## Actions

| Action | Purpose |
|--------|---------|
| `monk-io/monk-actions/provision@v1` | Provision (or reuse) a Monk cluster for a capsule environment |
| `monk-io/monk-actions/fetch-metadata@v1` | Fetch capsule monkcode, JIT tokens, and registry credentials |
| `monk-io/monk-actions/build-images@v1` | Build and push all images declared in `MANIFEST` to a Monk registry |
| `monk-io/monk-actions/deploy@v1` | Deploy a workload to a Monk cluster (capsule or static) |
| `monk-io/monk-actions/cleanup@v1` | Tear down a capsule on branch close/delete |

`provision`, `fetch-metadata`, `deploy`, and `cleanup` are Docker container actions bundling the [Monk CLI](https://docs.monk.io). `build-images` is a composite action that runs on the host runner so podman/docker can build natively.

`build-images` and `deploy` serve two flows:
- **Capsule flow** (per-branch preview environments): credentials come from `fetch-metadata` outputs (double-base64'd to survive masking across jobs).
- **Static CI/CD flow** (plain deploy to a fixed cluster on push to main): credentials come straight from repo secrets via the plain `monkcode`/`service-token`/`registry-password` inputs, with `capsule-mode: static`.

## Quick start

The Monk VS Code extension generates a ready-to-commit `.github/workflows/dynenv.yml` calling these actions — that is the easiest way to get started.

For hand-written workflows, a minimal example:

```yaml
jobs:
  provision:
    runs-on: ubuntu-latest
    environment: monk-capsules
    steps:
      - uses: monk-io/monk-actions/provision@v1
        with:
          monk-token: ${{ secrets.MONK_CAPSULE_TOKEN }}
          environment-name: my-feature-branch
          capsule-mode: cloud
          cloud-provider: ${{ vars.CLOUD_PROVIDER }}
          cloud-region: ${{ vars.CLOUD_REGION }}
          cloud-instance-type: ${{ vars.CLOUD_INSTANCE_TYPE }}
          cloud-instance-count: ${{ vars.CLOUD_INSTANCE_COUNT }}
          cloud-credentials: |
            DO_API_TOKEN=${{ secrets.DO_API_TOKEN }}
          workload-secrets: |
            DATABASE_URL=${{ secrets.DATABASE_URL }}
            STRIPE_KEY=${{ secrets.STRIPE_KEY }}
        env:
          MONK_SUBSCRIPTION_API_BASE: ${{ vars.MONK_SUBSCRIPTION_API_BASE }}
          MONK_AUTH_SERVICE_URL: ${{ vars.MONK_AUTH_SERVICE_URL }}
          MONK_API_PREFIX: ${{ vars.MONK_API_PREFIX }}
          MONK_PROJECT_SLUG: ${{ vars.MONK_PROJECT_SLUG }}
          MONK_ORG_SLUG: ${{ vars.MONK_ORG_SLUG }}
```

Routing on a host. A template can take the host of its web service from an `ingress-host` variable,
so the same template serves a real domain in production or dev and a generated one for each branch:

```yaml
stack:
  defines: group
  variables:
    ingress-host:
      type: string
      value: ""          # or the real domain, for a deploy that doesn't set it
```

```yaml
ingress-routes:
  web:
    host: <- $ingress-host
    path-prefix: /
```

On a shared cluster (`capsule-mode: cluster`) every branch deploys to the same cluster, so a web
service's route has to differ per branch. When a template the MANIFEST loads mentions `ingress-host`, `deploy` sets it to
`<environment>.<domain of the pool node that sorts first by domain>`, and the preview URL is that
host. Everywhere else (a production or dev deploy, a cloud-mode capsule) the variable keeps the value
the template, or the deploy, gives it.

The host is the same on every deploy while the pool stays as it is. Growing the pool with a node whose
domain sorts earlier moves every branch to a host under that node on its next deploy, and the old
URLs stop answering. A node created before the platform answered for subdomains of node domains has
no such record, so a pool that mixes old and new nodes can pick one that doesn't resolve.

Keep the `path-prefix`. With the variable empty the route is just `PathPrefix(/)` and matches every
host, as it did before; a route with only an empty host has no rule at all and is dropped.

A generated name must resolve (the platform answers for any subdomain of a node domain) and, for
`https`, be covered by the node domain's certificate. Until both are true the preview URL doesn't
answer, which the deploy's preview check reports; with `health-check-path` set, that fails the run.
The variable is only passed when a template loaded by the MANIFEST (`LOAD`, or a `DIRS` sub-MANIFEST) declares `ingress-host:`, so existing projects are
unaffected until they add it.

Static CI/CD deploy (no capsule environments):

```yaml
jobs:
  build-images:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: monk-io/monk-actions/build-images@v1
        with:
          registry-address: ${{ secrets.REGISTRY_ADDRESS }}
          registry-username: ${{ secrets.REGISTRY_USERNAME }}
          registry-password: ${{ secrets.REGISTRY_PASSWORD }}
          registry-tls-verify: ${{ secrets.REGISTRY_TLS_VERIFY }}
  deploy:
    needs: build-images
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: monk-io/monk-actions/deploy@v1
        with:
          monkcode: ${{ secrets.MONKCODE }}
          service-token: ${{ secrets.MONK_SERVICE_TOKEN }}
          workload: "myapp/stack"
          branch-tag: "default"
          capsule-mode: static
```

See the [Monk VS Code extension](https://github.com/monk-io/vscode-monk) repo for a complete reference workflow including build, deploy, and cleanup stages.

## Secrets pattern

Fixed secrets (Monk token, cloud provider credentials) are declared as `inputs` in each `action.yml` and mapped to env vars via `runs.env`. This follows the convention used by `aws-actions/configure-aws-credentials`, `docker/login-action`, etc.

Workload secrets — whose names depend on the user's manifest — are passed as a single multiline `workload-secrets:` input, one `KEY=value` per line. Each value should be a `${{ secrets.X }}` interpolation so GitHub masks it independently. This matches the [`docker/build-push-action` `secrets:`](https://github.com/docker/build-push-action) convention.

## Versioning

- Immutable tags: `v1.2.3`, `v1.2.3-rc.1` — pin these in production for reproducibility.
- Floating major tag: `v1` — moves with each non-pre-release `vX.Y.Z` release.
- The bundled Monk CLI version is pinned via `MONK_CI_VERSION` and bumped automatically when monk releases a new `monk-ci` image.

## Proprietary components

These actions bundle the proprietary [Monk CLI](https://docs.monk.io) inside the action Docker image. Use of the action is subject to Monk's terms of service. The action source code (scripts, entrypoints, action.yml files) is licensed separately — see [LICENSE](LICENSE).
