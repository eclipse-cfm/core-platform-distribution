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
| **Infrastructure** (in-chart)   | PostgreSQL, Vault (dev mode), NATS                                                                                       |
| **Observability** (in-chart)    | Jaeger, Prometheus, Loki, Grafana, wired via OTLP                                                                        |
| **Bootstrap**                   | Postgres DB/user init, NATS stream, Vault seed, and app seed jobs (Helm hooks)                                           |

All infrastructure and the observability stack are deployed as in-chart templates (under
`templates/infra-glue/` and `templates/telemetry/`) rather than community sub-charts, so the
chart has no external dependencies and the Service names match the OTLP endpoints in the
telemetry config.

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
helm upgrade --install core-platform . \
  --namespace edc-v --create-namespace --wait --timeout 15m
```

> The chart has no community sub-chart dependencies — all infrastructure ships as in-chart
> manifests — so there is no `helm dependency build` step.

## Configuration

All configuration lives in [`values.yaml`](values.yaml), which is heavily commented. The most
useful knobs:

| Key                                                            | Purpose                                                                             |
|----------------------------------------------------------------|-------------------------------------------------------------------------------------|
| `imageRegistry`                                                | Default registry prefixed to first-party images without a host (default `ghcr.io`). |
| `global.namespace`                                             | Target namespace / DNS segment (default `edc-v`).                                   |
| `global.host`, `global.gatewayName`, `global.gatewayClassName` | Gateway/HTTPRoute exposure.                                                         |
| `global.external.*`                                            | Externally reachable Gateway address; see [External exposure](#external-exposure-dsp--dcp). |
| `global.imagePullPolicy`                                       | Default pull policy; each component can override via its own `imagePullPolicy`.     |
| `global.debug.enabled`                                         | Emit a JDWP agent (port 1044) for the JVM-based EDC apps. **Dev only.**             |
| `postgresql` / `vault` / `nats`                                | Enable/disable and configure the in-chart infra services.                           |
| `telemetry.*`                                                  | Toggle and configure the observability backends and OTLP endpoints.                 |
| `security.*`                                                   | Gateway, jwtlet, clearglass, and forward-auth middlewares.                          |
| `edc.*` / `cfm.*`                                              | Per-component image, replicas, pull policy, and resources.                          |
| `seedJobs.*`                                                   | Bootstrap/seed hook jobs and their images.                                          |

Each `edc.*` / `cfm.*` / `security.*` component exposes `enabled`, `image.{repo,tag}`,
`replicas`, `imagePullPolicy` (empty = inherit `global`), and `resources`.

> **Defaults are dev-oriented.** Vault runs in dev mode with a `root` token, Postgres
> persistence is disabled, credentials are placeholders, and debug agents are on. Review and
> harden every one of these before any non-local use.

## External exposure (DSP / DCP)

Most APIs in this chart are operator-facing and sit behind the clearglass forward-auth
middleware (`jwt-auth`), which requires a jwtlet-issued token. The DSP and DCP endpoints are
different: they are talked to by *counterparties*, who hold no jwtlet token and are instead
authenticated in-app — DSP validates DCP credentials, the credential service validates the
caller's self-issued token, and DID documents are public. They are therefore routed
**without** the `jwt-auth` middleware, and their paths are forwarded **unrewritten**:

| External URL                                                                  | Backend                | `web.http.*` context |
|-------------------------------------------------------------------------------|------------------------|----------------------|
| `<host>/api/dsp/<participantContextId>/http-dsp-profile-2025-1`                | `controlplane:8082`    | `protocol`           |
| `<host>/api/credentials/v1/participants/<participantContextId>`               | `identityhub:7082`     | `credentials`        |
| `<host>/api/issuance/v1/participants/issuer`                              | `issuerservice:10012`  | `issuance`           |
| `identity.<host>/<participantContextId>/did.json`                             | `identityhub:7083`     | `did`                |
| `issuer.<host>/issuer/did.json`                                               | `issuerservice:10016`  | `did`                |

Each is toggleable (`edc.<component>.<endpoint>.exposed`). The three path-based ones are
configurable via `.path`, which must stay in sync with the matching `web.http.<context>.path`
because there is no `URLRewrite` in between. The two DID endpoints get their **own hostname**
(`edc.<component>.did.host`, defaulting to `identity.`/`issuer.` + the external host) and their
own HTTPRoute matching `/` — see below.

### Advertised URLs

Routing traffic *in* is only half the job: the URLs the platform publishes about itself must
also be externally resolvable. `global.external` drives all of them — the DSP callback address
(`edc.dsp.callback.address`), the `CredentialService` and `IssuerService` endpoints written
into DID documents, and the `did:web` identifiers themselves.

The issuer DID is derived from its route hostname, so the DID and the HTTPRoute serving it
cannot disagree — `IssuerService` reconstructs the DID from the incoming request and looks it up
by exact match, so a mismatch returns an empty document rather than an error. Set
`edc.issuerservice.did.id` to pin the DID instead when it is not yours to choose (assigned by a
registry, or one that must survive an infrastructure move); the route hostname is then parsed
back out of the DID, and setting both `id` and `host` is rejected.

### `did:web` and the DNS requirement

`did:web` identifiers encode the URL their document is served from, and EDC reconstructs the
DID from the *incoming request* (authority + path) to look it up. Two consequences:

1. **The DID routes cannot be rewritten**, and the DID's authority is whatever `Host` the
   backend sees. Each DID endpoint therefore gets a dedicated hostname, which leaves the path
   segments free for the participant context id alone:
   `did:web:identity.cpd.localhost:alice` ⇄ `GET http://identity.cpd.localhost/alice/did.json`.
   Participant DIDs are minted outside this chart (ih-agent / participant profiles) —
   `helm status` prints the exact prefix to build them from.
2. **DIDs are resolved from inside the cluster too** (e.g. the control plane resolving the issuer
   DID), so the DID hostnames must resolve to the Gateway from *both* sides. On a plain
   KinD/Minikube cluster a `*.localhost` name resolves to the pod's own loopback and resolution
   fails. Verify from a pod:

```bash
kubectl -n edc-v run didcheck --rm -it --restart=Never --image=debian:stable-slim -- getent hosts issuer.cpd.localhost
```

It must return the Traefik Service's ClusterIP. **Use a glibc image, and not `curl`** — musl
(Alpine, hence `curlimages/curl`) and `curl` itself each resolve `*.localhost` to loopback
internally without querying DNS, so either fails here whether or not the setup is correct. The
JVM runtimes that actually resolve these DIDs do neither.

If it fails, point the names at the Traefik gateway Service in CoreDNS — add `rewrite` lines
inside the `.:53` block of the `coredns` ConfigMap in `kube-system`:

```
rewrite name identity.cpd.localhost traefik.traefik.svc.cluster.local
rewrite name issuer.cpd.localhost   traefik.traefik.svc.cluster.local
```

Both halves of the target are deployment-specific and getting either wrong fails **silently**,
with the rewritten name simply falling through to the upstream resolver:

- the Service name and namespace — read them off your controller:
  ```bash
  kubectl -n kube-system get svc -A -l app.kubernetes.io/name=traefik
  ```
- the trailing DNS domain, which must be the cluster's own — i.e. `global.clusterDomain` minus
  its `svc.` prefix, **not** `cluster.local` unless that is what the cluster actually uses. A
  cluster built with a custom `dnsDomain` (kubeadm `networking.dnsDomain`) serves only that zone,
  so `…svc.cluster.local` NXDOMAINs there. Confirm with:
  ```bash
  kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep kubernetes
  ```

The same applies to `global.host` itself if counterparty connectors run in this cluster and
call each other's DSP endpoints.

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
Chart.yaml            chart metadata (no sub-chart dependencies)
values.yaml           all configuration (commented)
templates/
  edc/                EDC connector apps + their configs
  cfm/                CFM agents and managers + their configs
  security/           jwtlet, clearglass, middlewares, RBAC, service accounts
  telemetry/          Jaeger, Prometheus, Loki, Grafana
  infra-glue/         Postgres, Vault, NATS, namespace, Gateway/GatewayClass, telemetry config
  hooks/              Postgres/NATS/Vault bootstrap + app seed jobs
  NOTES.txt           post-install notes
```
