# NATS Authentication

NATS access is authenticated at the **component** level using
the [NKeys](https://docs.nats.io/running-a-nats-service/configuration/securing_nats/auth_intro/nkey_auth)
method, with the components' existing Kubernetes service accounts acting as the root of trust
for credential access. Individual users of the platform (participant contexts) are **not**
represented at the NATS layer — participant isolation remains an application/Vault concern.

## Overview

Each NATS-consuming workload (control plane, identity hub, issuer service, CFM agents, and the
stream-bootstrap job) is a NATS *user* identified by an ed25519 NKey pair:

- the **public key** is listed in the NATS server's `authorization` block, together with the
  user's publish/subscribe permissions;
- the **seed** (private key) is stored in Vault and is readable only by the matching
  Kubernetes service account, via Vault's `kubernetes` auth method.

Authentication is challenge–response: the server sends a nonce, the client signs it with the
seed, and the server verifies the signature against the configured public key. The seed never
travels over the network — neither to NATS nor anywhere else after its initial write to Vault.

```
Kubernetes ServiceAccount (existing: controlplane, identityhub, ...)
  └─ Vault kubernetes-auth role bound to that SA          (pod authentication)
      └─ Vault policy: read secret/nats/<component>       (seed authorization)
          └─ vault-agent init container writes seed file  (credential delivery)
              └─ app signs the NATS server nonce          (NATS authentication)
                  └─ per-user permissions in nats.conf    (NATS authorization)
```

The same service accounts already used for Vault token exchange are reused; no new identities
are introduced.

## Identity model

| NATS user       | Service account | Used by                                              |
|-----------------|-----------------|------------------------------------------------------|
| `controlplane`  | `controlplane`  | EDC control plane (events, cn/tp pub/sub)            |
| `identityhub`   | `identityhub`   | Identity Hub (event publishing)                      |
| `issuerservice` | `issuerservice` | Issuer Service (event publishing)                    |
| `cfm-agents`    | `cfm-agents`    | CFM agents and managers (`cfm-stream`, `cfm-bucket`) |
| `nats-admin`    | `seed-jobs`     | `nats-bootstrap` job (stream creation)               |

## Key generation: the `nats-auth-bootstrap` job

A plain, release-owned Job (same pattern as `vault-bootstrap` / `nats-bootstrap`: revision-
suffixed, runs concurrently with `helm install --wait`) performs the one-time key ceremony:

1. For each component: if `secret/nats/<component>` does not exist in Vault yet, generate a
   keypair with `nk -gen user` and write the seed there. Existing seeds are never overwritten,
   so keys are stable across upgrades.
2. Render the `users.conf` fragment (public keys + permissions) and apply it as the
   `<release>-nats-auth` Secret, owner-referenced to the NATS Deployment and followed by a
   checksum stamp on the Deployment's pod template (see Operations → Secret lifecycle). The
   job runs as the `seed-jobs` service account, which holds a Role allowing it to
   create/update that Secret and to patch the Deployment.

The NATS server mounts the Secret and includes it from `nats.conf`:

```
authorization {
    include "auth/users.conf"
}
```

Only public keys appear in the server configuration. The kubelet will not start the NATS
container before the Secret exists, which provides the required ordering without Helm hooks.

## Vault layout

Created by the Vault bootstrap job, per component:

- **Policy** `nats-<component>` — read-only on `secret/data/nats/<component>`.
- **Kubernetes auth role** `nats-<component>` — bound to the component's service account and
  namespace, attaching that policy (identical shape to the existing `siglet-role` /
  `jwtlet-role`).

A component can therefore obtain exactly its own seed and nothing else — including not the
seeds of its sibling components.

## Credential delivery

Every NATS-consuming pod gains a **vault-agent init container** (the same pattern used by
jwtlet/siglet, but init-only — NKey seeds are static, so no sidecar is needed):

1. Log in to Vault with the pod's projected service-account token against
   `auth/kubernetes/role/nats-<component>`.
2. Read the seed from `secret/nats/<component>`.
3. Write it to `/vault/secrets/nats.nk` (mode `0444` — init and app containers may run
   as different UIDs; the volume is pod-private tmpfs) on a shared
   `emptyDir: {medium: Memory}` volume and exit.

The application container only ever reads a local file. This keeps application code agnostic
of Vault, works identically for the Java EDC runtimes, the Go CFM agents and the nats-box
based job, and keeps Vault off the runtime path: after pod start, NATS reconnects require
nothing but NATS itself.

## Client configuration

The runtimes reference the seed file by path:

- **CFM agents/managers** — native support via `common/natsclient` (the same
  `AuthFromConfig` path is used by all launchers: the orchestration agents, kmagent,
  tenant manager and provision manager). Configured in each component's `.env` config:

  ```
  nats.auth.method: nkey
  nats.auth.nkeySeedFile: /vault/secrets/nats.nk
  ```

- **`nats-bootstrap` job** — the `nats` CLI's built-in `--nkey /vault/secrets/nats.nk` flag;
  no code involved.
- **EDC runtimes** — the runtimes' *NATS NKey Authentication Extension* reads
  `edc.nats.auth.nkey.seed.path` (set in each config ConfigMap) and signs the server nonce
  with the mounted seed. If the setting is absent, the runtime logs
  `'edc.nats.auth.nkey.seed.path' is not configured, NATS connections will not present
  credentials` at startup — with authentication enforced (no anonymous fallback), such a
  runtime cannot connect.

## Permissions

Permissions are defined per user in `users.conf`. They are intentionally coarse to start with
(JetStream consumers need the `$JS.API.>` request subjects and `_INBOX.>` for replies) and are
expected to be tightened once subject usage is confirmed:

| User            | Publish                                                 | Subscribe                                            |
|-----------------|---------------------------------------------------------|------------------------------------------------------|
| `controlplane`  | `events.>`, `$JS.API.>`, `$JS.ACK.>`                    | `events.>`, `_INBOX.>`                               |
| `identityhub`   | `events.>`, `$JS.API.>`                                 | `_INBOX.>`                                           |
| `issuerservice` | `events.>`, `$JS.API.>`                                 | `_INBOX.>`                                           |
| `cfm-agents`    | `event.>`, `$KV.cfm-bucket.>`, `$JS.API.>`, `$JS.ACK.>` | `event.>`, `events.>`, `$KV.cfm-bucket.>`, `_INBOX.>` |
| `nats-admin`    | `>`                                                     | `>`                                                  |

Note the singular `event.>` for the CFM components: `cfm-stream` carries `event.*` subjects
(the `CFMSubjectPrefix` in `common/natsclient/stream.go`). `events.>` (plural) is additionally
granted because the key-management agent consumes the shared `edc-events` stream.

All users live in the default (`$G`) account: the components deliberately share the
`edc-events` stream, so NATS accounts (which isolate subject spaces entirely) would only add
export/import friction here.

The monitoring port (`8222`, `/healthz`) remains unauthenticated by design — the bootstrap
jobs' readiness checks depend on it and it exposes no message data.

## Operations

**Rotating a component's key** — delete `secret/nats/<component>` in Vault, re-run the
`nats-auth-bootstrap` job (any `helm upgrade` does this), then restart the component's pods so
the init container fetches the new seed. The NATS server restart is automatic: the job stamps
the users.conf checksum onto the NATS Deployment's pod template, so any content change rolls
the server (an unchanged checksum is a no-op). Rotation remains an operational procedure, not
an automatic mechanism — an accepted trade-off of static NKeys in exchange for having no auth
service or Vault on the connect path.

**Secret lifecycle** — the users.conf Secret is job-created, so Helm does not track it.
The job therefore sets the (Helm-tracked) NATS Deployment as its ownerReference: on
`helm uninstall`, garbage collection removes the Secret together with the Deployment, and a
reinstall starts from a clean slate. Without this, the Secret would outlive the release while
the dev-mode Vault (and with it the seeds) does not, and the freshly installed server would
enforce the previous install's public keys. The checksum stamp covers the complementary case:
content changes while the server is already running.

**Adding a new component** — add it to the bootstrap job's component list (values), give its
pod the vault-agent init container, and bind a `nats-<component>` Vault role to its service
account. The next upgrade generates its key and extends `users.conf`.

**Troubleshooting**

- `Authorization Violation` in the client log — the user connected but published/subscribed
  outside its permission set; check the server debug log for the exact subject and extend the
  matrix if legitimate.
- `Authentication Failure` — the presented public key is not in `users.conf`; usually the pod
  fetched a seed that predates a rotation. Restart the pod (fresh init-container fetch).
- Init container hangs at Vault login — the `nats-<component>` role is missing or bound to
  the wrong SA/namespace; check the Vault bootstrap job logs.
- `Error Publishing: 503 No Responders Available For Request` — **not** an auth error (the
  client is connected): a JetStream publish for which no stream covers the subject. Compare
  `nats stream info <name>` against `nats.streams` in values.yaml — typically the stream was
  auto-recreated by a consumer with only its own subject filter after a NATS restart wiped
  the (deliberately ephemeral) JetStream state. A `helm upgrade` re-runs the
  `nats-bootstrap` job, which force-recreates the defined streams.

## Security considerations

- **Protected against:** unauthenticated access from anything that can reach the NATS Service
  (any pod in the cluster), cross-component impersonation (each SA can read only its own
  seed), and credential exposure in transit (challenge–response; the seed is never sent).
- **Not addressed here:** transport encryption (the client port is plaintext inside the
  cluster; enable TLS on port 4222 as a separate step if required) and per-participant
  isolation (out of scope by design — NATS sees components, not participant contexts).
- Seeds exist in three places only: Vault, the in-memory pod volume, and the bootstrap job's
  transient memory. They appear in no ConfigMap, values file, or server configuration.

## Future iterations

The biggest caveat with the solution proposed here is that NKeys are generated once upon pod init
and are not rotated. This means that if a key pair is compromised, the attacker can use the
NKey to impersonate the component and access the NATS Service. Rotating a key would mean
redeploying the component with a new seed, which would require a restart of the pod plus updating
the public key in NATS's `authorization` block.

Running NATS in "operator mode" using NKeys + JWT would be a natural evolution of this, where the
NATS server does not hold any credentials/secrets but instead relies on JWTs for authentication.

The general idea is outlined in
the [NATS documentation](https://docs.nats.io/running-a-nats-service/configuration/securing_nats/auth_callout).

In practice, every component pod (identityhub, controlplane, issuerservice) would receive a second SA token (
`aut: nats`) and sends it as the NATS connect token. A new, yet-to-be-implemented auth callout service, let's call it
"natslet", receives every connection attempt and validates the token using the Kubernetes TokenReview API. It then maps
the token to a set of permissions (stored in `ConfigMap`), returning it in JWT format as a signed, short-lived NATS user
JWT.

That way, Vault is not involved anymore, no need for init containers and key rotation is bound to Kubernetes' key
rotation mechanism.

Naturally, the already existing `jwtlet` could be repurposed to handle the NATS JWTs as well.