# Core Platform Distribution

A Helm chart that deploys all required components to run a multi-tenant dataspace based on EDC
connector components, the CFM agents and managers, and the security/gateway layer — together
with the infrastructure (PostgreSQL, Vault, NATS) and an in-chart observability stack. 

It is a one-click installation: one `helm install` brings up a complete, self-contained dataspace
platform suitable for local/dev clusters (KinD, Minikube, Docker Desktop) out of the box.

## What's in the box

| Layer                           | Components                                                                                                               |
|---------------------------------|--------------------------------------------------------------------------------------------------------------------------|
| **EDC runtimes**                | control plane, data plane, identity hub, issuer service, siglet                                                          |
| **CFM applications**            | agents (jwtlet, edcv, ih, registration, onboarding), key-management (lifecycle) agent, provision manager, tenant manager |
| **Security / gateway**          | jwtlet, clearglass, Traefik Gateway + GatewayClass, forward-auth middlewares                                             |
| **Infrastructure** (sub-charts) | PostgreSQL (Bitnami), Vault (HashiCorp), NATS                                                                            |
| **Observability** (in-chart)    | Jaeger, Prometheus, Loki, Grafana, wired via OTLP                                                                        |
| **Bootstrap**                   | Postgres DB/user init, NATS stream, Vault seed, and app seed jobs (Helm hooks)                                           |

The observability stack is deployed as in-chart templates (under `templates/telemetry/`) rather
than community sub-charts, so the Service names match the OTLP endpoints in the telemetry config.

## Prerequisites

- Kubernetes cluster with the **Gateway API** CRDs installed and a **Traefik** Gateway
  controller (the chart ships a `GatewayClass` keyed to `traefik`; disable it if your cluster
  already provides one — `security.gatewayClass.enabled=false`).
- Helm 3.8+ (OCI support).
- The chart pulls application images from `ghcr.io` by default (`imageRegistry`). Ensure the
  cluster can reach the registries or point the values at images you can pull.

## Installation

The chart is published as an OCI artifact to GitHub Container Registry:

```bash
helm upgrade --install core-platform \
  oci://ghcr.io/eclipse-cfm/charts/core-platform-distribution \
  # optional: --version <version> \
  --namespace edc-v --create-namespace \
  --wait --timeout 15m
```

Note: The published package is public, so no registry login is required to pull. If you hit a
`403 denied`, it is almost always a **stale `ghcr.io` credential** being sent instead of an
anonymous request — clear it with `helm registry logout ghcr.io` (and `docker logout ghcr.io`).

### From a local checkout

```bash
# fetch sub-chart dependencies (register the extra repos first)
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo add nats https://nats-io.github.io/k8s/helm/charts/
helm dependency build .

helm upgrade --install core-platform . \
  --namespace edc-v --create-namespace --wait --timeout 15m
```

> `charts/` is git-ignored; the sub-chart archives are fetched from `Chart.lock` via
> `helm dependency build`. Keep `Chart.lock` committed.

## Configuration

All configuration lives in [`values.yaml`](values.yaml), which is heavily commented. The most
useful knobs:

| Key                                                            | Purpose                                                                             |
|----------------------------------------------------------------|-------------------------------------------------------------------------------------|
| `imageRegistry`                                                | Default registry prefixed to first-party images without a host (default `ghcr.io`). |
| `global.namespace`                                             | Target namespace / DNS segment (default `edc-v`).                                   |
| `global.host`, `global.gatewayName`, `global.gatewayClassName` | Gateway/HTTPRoute exposure.                                                         |
| `global.imagePullPolicy`                                       | Default pull policy; each component can override via its own `imagePullPolicy`.     |
| `global.debug.enabled`                                         | Emit a JDWP agent (port 1044) for the JVM-based EDC apps. **Dev only.**             |
| `postgresql` / `vault` / `nats`                                | Enable/disable and configure the infra sub-charts.                                  |
| `telemetry.*`                                                  | Toggle and configure the observability backends and OTLP endpoints.                 |
| `security.*`                                                   | Gateway, jwtlet, clearglass, and forward-auth middlewares.                          |
| `edc.*` / `cfm.*`                                              | Per-component image, replicas, pull policy, and resources.                          |
| `seedJobs.*`                                                   | Bootstrap/seed hook jobs and their images.                                          |

Each `edc.*` / `cfm.*` / `security.*` component exposes `enabled`, `image.{repo,tag}`,
`replicas`, `imagePullPolicy` (empty = inherit `global`), and `resources`.

> **Defaults are dev-oriented.** Vault runs in dev mode with a `root` token, Postgres
> persistence is disabled, credentials are placeholders, and debug agents are on. Review and
> harden every one of these before any non-local use.

## Publishing

`.github/workflows/publish-chart.yaml` lints and templates the chart, then packages and pushes
it to `oci://ghcr.io/<owner>/charts` on version tags (`v1.2.3` / `1.2.3`) and creates a matching
GitHub release. The chart `version`/`appVersion` are taken from the tag (a leading `v` is
stripped); manual `workflow_dispatch` runs package the version already in `Chart.yaml`.

To cut a release:

```bash
git tag x.y.x
git push origin x.y.z
```

## Layout

```
Chart.yaml            umbrella chart metadata + sub-chart dependencies
Chart.lock            pinned sub-chart versions (committed; charts/ is generated)
values.yaml           all configuration (commented)
templates/
  edc/                EDC connector apps + their configs
  cfm/                CFM agents and managers + their configs
  security/           jwtlet, clearglass, middlewares, RBAC, service accounts
  telemetry/          Jaeger, Prometheus, Loki, Grafana
  infra-glue/         namespace, Gateway/GatewayClass, telemetry config
  hooks/              Postgres/NATS/Vault bootstrap + app seed jobs
  NOTES.txt           post-install notes
```
