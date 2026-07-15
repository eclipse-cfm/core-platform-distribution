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
     Trusted-issuer DID (URL-encoded port, e.g. did:web:<host>%3A10016:issuer).
     ------------------------------------------------------------------------- */}}
{{- define "cpd.issuerDid" -}}
{{- printf "did:web:%s%%3A10016:issuer" (include "cpd.fqdn" (dict "svc" "issuerservice" "ctx" .)) -}}
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
