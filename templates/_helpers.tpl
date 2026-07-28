{{/*
Copyright (c) 2025 Metaform Systems, Inc.
SPDX-License-Identifier: Apache-2.0
*/}}

{{/* -------------------------------------------------------------------------
     Naming / namespace
     ------------------------------------------------------------------------- */}}

{{- define "cpd.namespace" -}}
{{- .Values.global.namespace | default .Release.Namespace -}}
{{- end -}}

{{/* Release-name-prefixed resource name for in-chart infra (postgres, vault, nats,
     telemetry stack). The "<release>-<component>" convention keeps the historical
     <release>-postgresql / <release>-vault service names and stops resources colliding
     across releases sharing a namespace. Call as: (dict "name" "nats" "ctx" $). */}}
{{- define "cpd.fullname" -}}
{{- printf "%s-%s" .ctx.Release.Name .name -}}
{{- end -}}

{{- define "cpd.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* -------------------------------------------------------------------------
     In-cluster FQDN builder.
     Usage: {{ include "cpd.fqdn" (dict "svc" "jwtlet" "ctx" $) }}
     ------------------------------------------------------------------------- */}}
{{- define "cpd.fqdn" -}}
{{- printf "%s.%s.%s" .svc (include "cpd.namespace" .ctx) .ctx.Values.global.clusterDomain -}}
{{- end -}}

{{/* -------------------------------------------------------------------------
     Infra service hosts. `connection.host` wins; otherwise derive the in-chart
     service name (<release>-postgresql / -vault / -nats).
     ------------------------------------------------------------------------- */}}
{{- define "cpd.pgHost" -}}
{{- $c := .Values.postgresql.connection -}}
{{- if $c.host -}}{{ $c.host -}}
{{- else -}}{{ printf "%s-postgresql.%s.%s" .Release.Name (include "cpd.namespace" .) .Values.global.clusterDomain -}}{{- end -}}
{{- end -}}

{{- define "cpd.vaultHost" -}}
{{- $c := .Values.vault.connection -}}
{{- if $c.host -}}{{ $c.host -}}
{{- else -}}{{ printf "%s-vault.%s.%s" .Release.Name (include "cpd.namespace" .) .Values.global.clusterDomain -}}{{- end -}}
{{- end -}}

{{- define "cpd.natsHost" -}}
{{- $c := .Values.nats.connection -}}
{{- if $c.host -}}{{ $c.host -}}
{{- else -}}{{ printf "%s-nats.%s.%s" .Release.Name (include "cpd.namespace" .) .Values.global.clusterDomain -}}{{- end -}}
{{- end -}}

{{/* Convenience URL builders reused across configs and hook scripts. */}}
{{- define "cpd.vaultUrl" -}}
{{- printf "%s://%s:%v" .Values.vault.connection.scheme (include "cpd.vaultHost" .) .Values.vault.connection.port -}}
{{- end -}}

{{- define "cpd.natsUrl" -}}
{{- printf "nats://%s:%v" (include "cpd.natsHost" .) .Values.nats.connection.port -}}
{{- end -}}

{{/* Name of the secret holding the postgres admin password (in-chart postgresql template). */}}
{{- define "cpd.pgAdminSecret" -}}
{{- .Values.postgresql.connection.adminPasswordSecret.name | default (printf "%s-postgresql" .Release.Name) -}}
{{- end -}}

{{/* -------------------------------------------------------------------------
     Image reference.
     Usage: {{ include "cpd.image" (dict "img" .Values.edc.controlplane.image "ctx" $) }}
     A repo that already contains a registry host (has a dot or colon before the
     first slash) is used verbatim; otherwise global.imageRegistry is prepended.
     ------------------------------------------------------------------------- */}}
{{- define "cpd.image" -}}
{{- $repo := .img.repo -}}
{{- $tag := .img.tag | default "latest" -}}
{{- $first := splitList "/" $repo | first -}}
{{- if or (contains "." $first) (contains ":" $first) -}}
{{- printf "%s:%s" $repo $tag -}}
{{- else -}}
{{- printf "%s/%s:%s" .ctx.Values.imageRegistry $repo $tag -}}
{{- end -}}
{{- end -}}

{{/* -------------------------------------------------------------------------
     Effective imagePullPolicy: the per-component override when set, otherwise
     the global default.
     Usage: {{ include "cpd.pullPolicy" (dict "policy" $c.imagePullPolicy "ctx" $) }}
     ------------------------------------------------------------------------- */}}
{{- define "cpd.pullPolicy" -}}
{{- .policy | default .ctx.Values.global.imagePullPolicy -}}
{{- end -}}

{{/* -------------------------------------------------------------------------
     Labels
     ------------------------------------------------------------------------- */}}
{{- define "cpd.labels" -}}
helm.sh/chart: {{ include "cpd.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
platform: edcv
{{- end -}}

{{/* -------------------------------------------------------------------------
     External (outside-the-cluster) address of the Gateway.

     The DSP and DCP endpoints are the only ones a *counterparty* talks to, so the
     URLs the platform advertises about itself (DSP callback address, credential
     service endpoint, issuance service endpoint, did:web identifiers) must be
     resolvable from outside. These helpers build that address from `global.external`.

     NOTE: did:web identifiers are resolved by the connector runtimes too, i.e. from
     INSIDE the cluster. `global.external.host` must therefore resolve to the
     Gateway from both sides (see README, "External exposure").
     ------------------------------------------------------------------------- */}}
{{- define "cpd.externalHost" -}}
{{- .Values.global.external.host | default .Values.global.host -}}
{{- end -}}

{{/* "host" or "host:port" for an arbitrary hostname served by the Gateway — the
     port is omitted when it is the scheme default.
     Usage: {{ include "cpd.authorityFor" (dict "host" "issuer.example.com" "ctx" $) }} */}}
{{- define "cpd.authorityFor" -}}
{{- $e := .ctx.Values.global.external -}}
{{- $port := $e.port | int -}}
{{- if or (and (eq $e.scheme "http") (eq $port 80)) (and (eq $e.scheme "https") (eq $port 443)) -}}
{{- .host -}}
{{- else -}}
{{- printf "%s:%d" .host $port -}}
{{- end -}}
{{- end -}}

{{- define "cpd.externalAuthority" -}}
{{- include "cpd.authorityFor" (dict "host" (include "cpd.externalHost" .) "ctx" .) -}}
{{- end -}}

{{- define "cpd.externalBaseUrl" -}}
{{- printf "%s://%s" .Values.global.external.scheme (include "cpd.externalAuthority" .) -}}
{{- end -}}

{{/* -------------------------------------------------------------------------
     did:web hostnames.

     The two DID endpoints each get their own hostname rather than a path prefix on
     `global.host`. EDC's DidWebController derives the DID from the request URL
     (authority + path) and looks it up by exact match, so a shared host would force
     a routing prefix into every DID; a dedicated host keeps the DID's path segments
     free for the participant context id alone:
       did:web:<didHost>:<participantContextId>
         <-> GET <scheme>://<didHost>/<participantContextId>/did.json
     Both hostnames must therefore point at the Gateway, from inside the cluster as
     well as outside (see README, "External exposure").
     ------------------------------------------------------------------------- */}}
{{- define "cpd.identityhubDidHost" -}}
{{- .Values.edc.identityhub.did.host | default (printf "identity.%s" (include "cpd.externalHost" .)) -}}
{{- end -}}

{{/* Hostname the issuer's DID document is served on.

     Normally derived from `did.host` (or `issuer.<externalHost>`), with the DID generated to
     match. When `did.id` pins the DID outright that direction inverts — the DID then dictates the
     hostname, per the did:web spec, so it is parsed back out here rather than configured
     separately. Either way there is exactly one input, and the route and the DID cannot drift.

     did:web:<authority>[:<segment>...], where a non-default port is percent-encoded into the
     authority. HTTPRoute hostnames carry no port, so it is dropped after decoding. */}}
{{- define "cpd.issuerserviceDidHost" -}}
{{- $d := .Values.edc.issuerservice.did -}}
{{- if and $d.id $d.host -}}
{{- fail "edc.issuerservice.did: set either `id` (explicit DID; the route hostname is derived from it) or `host` (hostname; the DID is derived from it) — not both" -}}
{{- end -}}
{{- if $d.id -}}
{{- $authority := $d.id | trimPrefix "did:web:" | splitList ":" | first | replace "%3A" ":" -}}
{{- splitList ":" $authority | first -}}
{{- else -}}
{{- $d.host | default (printf "issuer.%s" (include "cpd.externalHost" .)) -}}
{{- end -}}
{{- end -}}

{{/* did:web authority segment. EDC's DidWebParser URL-encodes URI.getAuthority(),
     so a non-default port appears percent-encoded: did:web:host%3A8080:foo. */}}
{{- define "cpd.didWebAuthorityFor" -}}
{{- include "cpd.authorityFor" . | replace ":" "%3A" -}}
{{- end -}}

{{/* -------------------------------------------------------------------------
     Trusted-issuer DID: did:web:<issuer did host>:issuer, served by IssuerService at
     GET <scheme>://<issuer did host>/issuer/did.json. The trailing segment is the
     issuer's participantContextId ("issuer", as created by the issuerservice-seed job).

     `edc.issuerservice.did.id` overrides it — for a DID that is not ours to choose (assigned by
     a dataspace registry, or one that must stay stable while the infrastructure under it moves,
     since credentials already issued reference it). The route hostname then follows from the
     DID; see cpd.issuerserviceDidHost.
     ------------------------------------------------------------------------- */}}
{{- define "cpd.issuerDid" -}}
{{- .Values.edc.issuerservice.did.id | default (printf "did:web:%s:issuer" (include "cpd.didWebAuthorityFor" (dict "host" (include "cpd.issuerserviceDidHost" .) "ctx" .))) -}}
{{- end -}}

{{/* -------------------------------------------------------------------------
     Prefix every IdentityHub participant DID must carry — i.e. everything up to the
     participant context id:
       <base>:<participantContextId>
         <-> GET <scheme>://<ih did host>/<participantContextId>/did.json
     Participant DIDs are minted OUTSIDE this chart (ih-agent / participant
     profiles) — this value is surfaced in NOTES.txt so they can be built to match.
     ------------------------------------------------------------------------- */}}
{{- define "cpd.identityhubDidBase" -}}
{{- printf "did:web:%s" (include "cpd.didWebAuthorityFor" (dict "host" (include "cpd.identityhubDidHost" .) "ctx" .)) -}}
{{- end -}}

{{/* -------------------------------------------------------------------------
     Advertised base URLs for the three counterparty-facing HTTP APIs. These are
     served on the Gateway's port under the same path the app itself uses (no
     URLRewrite), so the external URL is just <externalBase><path>.
     ------------------------------------------------------------------------- */}}
{{- define "cpd.dspBaseUrl" -}}
{{- printf "%s%s" (include "cpd.externalBaseUrl" .) .Values.edc.controlplane.protocol.path -}}
{{- end -}}

{{- define "cpd.credentialsBaseUrl" -}}
{{- printf "%s%s" (include "cpd.externalBaseUrl" .) .Values.edc.identityhub.credentials.path -}}
{{- end -}}

{{- define "cpd.issuanceBaseUrl" -}}
{{- printf "%s%s" (include "cpd.externalBaseUrl" .) .Values.edc.issuerservice.issuance.path -}}
{{- end -}}

{{/* -------------------------------------------------------------------------
     Projected jwtlet subject-token volume + matching mount.
     Placed under `volumes:` / `volumeMounts:` respectively.
     ------------------------------------------------------------------------- */}}
{{- define "cpd.jwtletSubjectTokenVolume" -}}
- name: jwtlet-subject-token
  projected:
    sources:
      - serviceAccountToken:
          path: token
          audience: {{ .Values.global.jwtSubjectTokenAudience | quote }}
          expirationSeconds: {{ .Values.global.jwtSubjectTokenExpirationSeconds }}
{{- end -}}

{{- define "cpd.jwtletSubjectTokenMount" -}}
- name: jwtlet-subject-token
  mountPath: /var/run/secrets/jwtlet
  readOnly: true
{{- end -}}

{{/* -------------------------------------------------------------------------
     NATS NKey credential delivery (see docs/nats-authentication.md).
     Init container that logs into Vault via the kubernetes auth method using the
     pod's own SA token, reads the component's NKey seed and drops it on the
     pod-private in-memory volume. Retries until the vault-bootstrap job has
     created the auth role and the nats-auth-bootstrap job has stored the seed
     (all bootstrap jobs run concurrently with the workloads).
     Usage: {{ include "cpd.natsNkeyInitContainer" (dict "component" "controlplane" "ctx" $) | nindent 8 }}
     ------------------------------------------------------------------------- */}}
{{- define "cpd.natsNkeyInitContainer" -}}
{{- $role := printf "nats-%s" (trimPrefix "nats-" .component) -}}
- name: fetch-nats-nkey
  image: {{ .ctx.Values.seedJobs.images.vault }}
  command: [ "sh", "-ec" ]
  args:
    - |
      export VAULT_ADDR={{ include "cpd.vaultUrl" .ctx | quote }}
      echo "Fetching the NATS NKey seed for '{{ .component }}' (Vault role {{ $role }})..."
      until VAULT_TOKEN=$(vault write -field=token auth/kubernetes/login \
          role={{ $role }} \
          jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token 2>/dev/null); do
        echo "Vault login failed (Vault or its bootstrap not ready yet), retrying in 2 seconds..."
        sleep 2
      done
      export VAULT_TOKEN
      until vault kv get -field=seed secret/nats/{{ .component }} > /vault/secrets/nats.nk 2>/dev/null; do
        echo "Seed not in Vault yet (nats-auth-bootstrap still running?), retrying in 2 seconds..."
        sleep 2
      done
      # 0444 rather than 0400: init and app container may run as different UIDs;
      # the volume is pod-private tmpfs either way.
      chmod 0444 /vault/secrets/nats.nk
      echo "NKey seed for '{{ .component }}' written to /vault/secrets/nats.nk"
  volumeMounts:
    - name: nats-nkey
      mountPath: /vault/secrets
{{- end -}}

{{/* App-container mount for the fetched NKey seed. */}}
{{- define "cpd.natsNkeyMount" -}}
- name: nats-nkey
  mountPath: /vault/secrets
  readOnly: true
{{- end -}}

{{/* Pod-private in-memory volume the seed is delivered on (never hits disk). */}}
{{- define "cpd.natsNkeyVolume" -}}
- name: nats-nkey
  emptyDir:
    medium: Memory
{{- end -}}

{{/* -------------------------------------------------------------------------
     initContainer that blocks until the given Postgres database is connectable
     with the given credentials. Because it authenticates against the specific
     database, a success also proves the postgres-init Job has created that
     database/role. The CFM (Go) components create their tables once at startup
     and do NOT retry, so they must not start before the DB is ready.
     Usage: {{ include "cpd.waitForPostgres" (dict "db" "cfm" "user" "cfm" "password" "cfm" "ctx" $) | nindent 8 }}
     ------------------------------------------------------------------------- */}}
{{- define "cpd.waitForPostgres" -}}
- name: wait-for-postgres
  image: {{ .ctx.Values.seedJobs.images.postgres }}
  command:
    - sh
    - -c
    - |
      until PGPASSWORD='{{ .password }}' psql -h '{{ include "cpd.pgHost" .ctx }}' -p '{{ .ctx.Values.postgresql.connection.port }}' -U '{{ .user }}' -d '{{ .db }}' -c 'SELECT 1' >/dev/null 2>&1; do
        echo "Waiting for Postgres database '{{ .db }}' to be ready..."
        sleep 2
      done
      echo "Postgres database '{{ .db }}' is ready"
{{- end -}}

{{/* -------------------------------------------------------------------------
     envFrom for a standard app: its own config ConfigMap + telemetry-config.
     Usage: {{ include "cpd.appEnvFrom" (dict "config" "controlplane-config" "ctx" $) | nindent 12 }}
     ------------------------------------------------------------------------- */}}
{{- define "cpd.appEnvFrom" -}}
- configMapRef:
    name: {{ .config }}
{{- if .ctx.Values.telemetry.configMapEnabled }}
- configMapRef:
    name: telemetry-config
{{- end -}}
{{- end -}}
