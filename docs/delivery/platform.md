# The hub platform

What this repository runs in the cluster `hub`: its components and their versions, NATS, Grafana's database, ingress,
CI tenants and labels, as `apps/` and `platform/` declare them.

## Components

Each component is an Application in `apps/` (named in parentheses), in namespace `argocd`, synced by Application `root`.
Replicas, budgets and rollouts: [disruption budgets](designs/disruption-budgets.md); placement:
[node pools](designs/node-pools.md); requests: [resource requests](designs/resource-requests.md).

| Namespace | Component | Source | Version | Wave |
| --- | --- | --- | --- | --- |
| cluster-scoped | Gateway API CRDs, standard channel (`gateway-api`) | `kubernetes-sigs/gateway-api` release manifest `standard-install.yaml` | `v1.6.2` | 1 |
| `cert-manager` | cert-manager (`cert-manager`), with ClusterIssuers `letsencrypt` and `letsencrypt-staging` ([certificates](#certificates)) | Chart `cert-manager`, `https://charts.jetstack.io` | `v1.21.2` | 1 |
| `external-secrets` | External Secrets Operator (`external-secrets`), with ClusterSecretStore `gcp-secret-manager`: Secret Manager of project `arikkfir`, for every namespace not labelled `kfirs.com/pull-request` | Chart `external-secrets`, `https://charts.external-secrets.io` | `2.13.0` | 1 |
| `argocd` | Argo CD (`argocd`), self-managed after Terraform's bootstrap ([infra's argocd root](../infra/terraform/argocd.md)) | Chart `argo-cd`, `https://argoproj.github.io/argo-helm` | `10.10.5` (Argo CD v3.5.5) | 2 |
| `traefik` | Traefik (`traefik`): GatewayClass `traefik`, Gateways `protected` and `public`, two replicas ([ingress](#ingress)) | Chart `traefik`, `https://traefik.github.io/charts` | `41.6.0` (Traefik v3.7.13) | 3 |
| `tekton-operator` | Tekton Operator (`tekton-operator`), which installs no default TektonConfig (`AUTOINSTALL_COMPONENTS: "false"`) | `tektoncd/operator` release manifest, from `infra.tekton.dev` | `v0.81.1` | 3 |
| `keda` | KEDA (`keda`) | Chart `keda`, `https://kedacore.github.io/charts` | `2.21.0` | 3 |
| `reloader` | Stakater Reloader (`reloader`) | Chart `reloader`, `https://stakater.github.io/stakater-charts` | `2.2.17` (Reloader v1.4.22) | 3 |
| `nats` | NATS with JetStream (`nats`): three clustered servers, a 50Gi volume each, and nats-box ([NATS](#nats)) | Chart `nats`, `https://nats-io.github.io/k8s/helm/charts` | `2.15.0` | 3 |
| `keycloak` | Keycloak Operator (`keycloak-operator`), watching namespace `keycloak` only | `keycloak/keycloak-k8s-resources` release kustomization (`kubernetes/`) | `26.8.1` | 3 |
| `auth` | oauth2-proxy (`auth`), the hub's sign-in, two replicas ([phase 3](designs/phase-3-ingress-and-auth.md)) | Chart `oauth2-proxy`, `https://oauth2-proxy.github.io/manifests` | `10.7.0` (oauth2-proxy 7.15.3) | 4 |
| `grafana` | Grafana (`grafana`), two replicas, reading Cloud Monitoring | Chart `grafana`, `https://grafana-community.github.io/helm-charts` | `13.2.7` (Grafana 13.2.3) | 4 |
| `grafana` | PostgreSQL for Grafana: StatefulSet `postgres` ([Grafana](#grafana)) | `docker.io/library/postgres`, in `platform/grafana/manifests` | `18.6-trixie` | 4 |
| `nats` | NACK, the JetStream controller (`nack`) | Chart `nack`, `https://nats-io.github.io/k8s/helm/charts` | `0.35.0` (NACK 0.24.0) | 4 |
| `nats` | NUI (`nui`) | Chart `nui`, `https://nats-nui.github.io/k8s/helm/charts` | `0.1.6` (image `0.9.3`, pinned in its values: the chart's is `latest`) | 4 |
| `tekton-pipelines` | Pipelines, Triggers and the Dashboard (`tekton`), through TektonConfig `config` (profile `all`), with Results, Chains, Pipelines-as-Code and the operator's NetworkPolicies off. Default ServiceAccount `pipeline`; TaskRun pods on node pool `ci`; 30 PipelineRuns kept per namespace. The Dashboard reads the logs of steps whose pods are gone from `http://octomaton-logs.octomaton.svc.cluster.local/logs` | `platform/tekton/manifests`, installed by the operator | Those of operator `v0.81.1` | 4 |
| `octomaton` | Octomaton and `octomaton-logs` (`octomaton-environment`): Application `octomaton`, AppProject `octomaton` ([deployment](../octomaton/designs/deployment.md)) | `deploy/` of `arikkfir-org/octomaton` at `main` | The synced commit's short SHA | 4 |
| `docs` | Docs site (`docs`): Caddy, two replicas ([design](designs/docs-and-tests-servers.md)) | `docker.io/library/caddy`, in `platform/docs/manifests` | `2.11.7-alpine` | 4 |
| `tests` | Tests site (`tests`): Caddy, two replicas ([design](designs/docs-and-tests-servers.md)) | `docker.io/library/caddy`, in `platform/tests/manifests` | `2.11.7-alpine` | 4 |
| `go-import` | Go import pages (`go-import`): Caddy, two replicas ([design](designs/go-import-pages.md)) | `docker.io/library/caddy`, in `platform/go-import/manifests` | `2.11.7-alpine` | 4 |
| `ci-<repository>` | CI tenants (`ci-tenants`) ([CI tenants](#ci-tenants)) | `platform/ci-tenants/manifests` | n/a | 4 |
| `keycloak` | Keycloak (`keycloak`): resource `keycloak`, two instances, Service `keycloak-service` on 8080 ([design](designs/keycloak.md)) | `quay.io/keycloak/keycloak`, in `platform/keycloak/manifests` | `26.8.1` | 4 |
| `keycloak` | PostgreSQL for Keycloak: StatefulSet `postgres` ([design](designs/keycloak.md#in-the-cluster)) | `docker.io/library/postgres`, in `platform/keycloak/manifests` | `18.6-trixie` | 4 |
| `fin`, `fin-pr-<number>`, `fin-pr-<number>-merge` | Fin (`fin-environments`): Application `fin` (production), ApplicationSet `fin-pull-requests`, Application `fin-identities`, AppProjects `fin` and `fin-pull-requests`, admission policies, and Gateway `traefik/fin-pull-requests` ([environments](../fin/designs/environments.md)) | `deploy/` of `arikkfir-org/fin`: `main`, each pull request's head commit and each merge queue entry's commit | The deployed commit's images | 4 |

## NATS

| Item | Value |
| --- | --- |
| Address | `nats://nats.nats.svc.cluster.local:4222`, for every client, NACK included |
| Servers | Three, clustered, JetStream on a file store with a 50Gi volume each, so a stream may keep up to three replicas |
| Spread | Over the system pool's nodes when it has several (`whenUnsatisfiable: ScheduleAnyway`): they never make the pool grow |
| NACK | Control-loop mode (`jetstream.controlLoop: true`), which applies key-value buckets as well as streams and consumers |
| Credentials | None |
| NetworkPolicy `nats` | On the servers: anything in namespace `nats` (the servers' own routes, NACK, NUI, nats-box), and on port 4222 only namespace `fin` and every namespace labelled `kfirs.com/pull-request: "true"`. No other namespace, CI tenants included |

## Grafana

| Item | Value |
| --- | --- |
| Database | `grafana`, owned by role `grafana`, on StatefulSet `postgres` (one replica, a 10Gi volume) at `postgres.grafana.svc.cluster.local:5432`, without TLS |
| NetworkPolicy `postgres` | Admits only Grafana's pods, on 5432 |
| Role `grafana`'s password | Generated in the cluster by an ESO `Password` generator, `refreshPolicy: CreatedOnce`: Secret `grafana/grafana-db`, key `password`. Deleting the Secret makes a new one, which Reloader rolls out to `postgres` and Grafana |
| People | Sign in as the superuser `postgres` through `kubectl port-forward -n grafana svc/postgres 5432`, with the password from Secret Manager `grafana-postgres-admin-password` |
| Authentication | Every TCP connection needs a password, localhost included; only the local socket is trusted |
| Replicas | PostgreSQL one. Grafana two, sharing alert state through Service `grafana-headless` on port 9094 |

## Ingress

One Traefik runs two entry-point pairs, each exposed by its own regional external passthrough network load balancer: a
`LoadBalancer` Service with `loadBalancerClass: networking.gke.io/l4-regional-external` that binds a reserved IP by
name through the annotation `networking.gke.io/load-balancer-ip-addresses`, with `externalTrafficPolicy: Local`, so
backends see client addresses. The cluster has no HTTP load-balancing add-on, so these need GKE 1.36 or later. The class
and the annotation are read only when a Service is created: changing either means recreating it.

| Gateway | Entry points (container → exposed) | Load balancer IP | Interceptor | Who may attach routes |
| --- | --- | --- | --- | --- |
| `traefik/protected` | `web` 8000→80 (redirects to HTTPS), `websecure` 8443→443; Service `traefik` | `ingress-protected` | Entry-point middlewares `strip-auth-headers` and `oidc` on `websecure`, before every route | Any namespace |
| `traefik/public` | `public-web` 9080→80 (redirects to HTTPS), `public-websecure` 9443→443; Service `traefik-public` | `ingress-public` | `strip-auth-headers` only | Namespaces labelled `kfirs.com/public-ingress: "true"`; listener `octomaton-dev` only `octomaton` and `go-import` among them |

The middlewares and the sign-in: [phase 3](designs/phase-3-ingress-and-auth.md). The hub's tools add Middleware
`admins` on their routes ([admins only](designs/admins-only.md)).

### Certificates

cert-manager issues them from Let's Encrypt through ClusterIssuer `letsencrypt`, solving DNS-01 in Cloud DNS: zone
`octomaton-dev` for `octomaton.dev`, zone `kfirs-com` for every other name.

| Listener | Hostname | Certificate / Secret |
| --- | --- | --- |
| `protected/websecure`, `public/public-websecure` | `*.kfirs.com`, which also matches deeper names | `wildcard-kfirs-com` (`*.kfirs.com`, `*.dev.kfirs.com`, `admin.id.kfirs.com`) / `traefik/wildcard-kfirs-com-tls`, also Traefik's default certificate |
| `public/octomaton-dev` (9443) | `octomaton.dev` | `octomaton-dev` / `traefik/octomaton-dev-tls` |
| `fin-pull-requests/app` (8443) | `*.app.dev.fin.kfirs.com` | `fin-pull-requests` / `traefik/fin-pull-requests-tls` |

Listener `octomaton-dev` admits routes only from namespaces `octomaton` (the webhook) and `go-import` (the Go import
page), and only while they carry `kfirs.com/public-ingress: "true"`.

### Hosts

Each route's Middlewares are in its own namespace.

| Host | Gateway | Backend | Paths | Middlewares |
| --- | --- | --- | --- | --- |
| `argocd.dev.kfirs.com` | protected | `argocd/argocd-server:80` | All; Exact `/auth/logout` redirects to oauth2-proxy's sign-out | `admins`, `id-token`; on `/auth/logout`, `admins`, `logout` |
| `tekton.dev.kfirs.com` | protected | `tekton-pipelines/tekton-dashboard:9097` | All | `admins` |
| `grafana.dev.kfirs.com` | protected | `grafana/grafana:80` | All | `admins` |
| `traefik.dev.kfirs.com` | protected (IngressRoute on `websecure`) | Traefik's dashboard, `api@internal` | All | `admins` |
| `nui.dev.kfirs.com` | protected | `nats/nui:31311` | All | `admins`, `strip-cookies` |
| `docs.dev.kfirs.com` | protected | `docs/docs:80` | All | `admins` |
| `tests.dev.kfirs.com` | protected | `tests/tests:80` | All | `admins` |
| `admin.id.kfirs.com` | protected | `keycloak/keycloak-service:8080` | Exact `/` (Keycloak redirects it to the console), `/admin`, `/realms/master`, `/resources` | `admins` |
| `auth.kfirs.com` | public | `auth/oauth2-proxy:80` | `/oauth2` | None |
| `id.kfirs.com` | public | `keycloak/keycloak-service:8080` | `/realms/hub`, `/resources`; POSTs under `/realms/hub/login-actions`; `/realms/master` | None; `sign-in-attempts`; `oidc`, `admins` |
| `legal.kfirs.com` | public | `docs/docs:80` | Exact `/privacy.html`, `/privacy.md.html`, `/tos.html`, `/tos.md.html` | None |
| `fin.kfirs.com` | public | `go-import/go-import:80` | All | None |
| `octomaton.dev` | public, listener `octomaton-dev` | `octomaton/octomaton:80` (Octomaton's `deploy/`); `go-import/go-import:80` | Exact `/github/hooks`; everything else | None |

### Fin's gateways

Fin's hosts need certificates of their own, so they have Gateways of their own on the protected entry point, behind the
same sign-in: production's `fin/fin`, from Fin's `deploy/`, and `traefik/fin-pull-requests`, which every pull request's
and merge queue entry's environment shares ([environments](../fin/designs/environments.md)).

`traefik/fin-pull-requests` is this repository's (`platform/fin/manifests`): Certificate `fin-pull-requests` (wave 0)
for `*.app.dev.fin.kfirs.com`, and the Gateway (wave 1) with one listener, `app`, HTTPS on 8443 with that hostname,
taking routes only from namespaces labelled `kfirs.com/pull-request: "true"`; policy `fin-http-routes` holds each such
namespace to its own host, `pr-<number>.app.dev.fin.kfirs.com` or `pr-<number>-merge.app.dev.fin.kfirs.com`. One
certificate serves every pull request, so none issues its own against Let's Encrypt's 50 a week for `kfirs.com`, and
in `traefik` its private key is out of every pull request's reach.

DNS records and the two IPs are `infra`'s: [DNS](../infra/terraform/gcp.md#dns),
[network](../infra/terraform/gcp.md#network).

## CI tenants

Application `ci-tenants` creates namespace `ci-<repository>` for every repository but `.github`, which has no CI:
`ci-infra`, `ci-delivery`, `ci-octomaton`, `ci-tooling`, `ci-docs` and `ci-fin`. Octomaton runs each repository's
pipelines in its tenant.

Every tenant gets the base (`platform/ci-tenants/manifests/base`):

| Object | Spec |
| --- | --- |
| ServiceAccount `pipeline` | Tekton's default, for every PipelineRun that names no other. Any branch's run can use it, so it never holds a Google Cloud role; no `octomaton.dev/branches` |
| ServiceAccount `docs-reader` | The organization pipeline `docs` (check `Docs`), on pull requests and merge groups. No token mounted; no `octomaton.dev/branches` |
| ServiceAccount `docs-publisher` | The organization pipeline `docs-publish`, on pushes to `main`, writing the repository's layer. No token mounted; `octomaton.dev/branches: main` |
| RoleBinding `octomaton` | ClusterRole `octomaton-tenant` to ServiceAccount `octomaton/octomaton`. Octomaton's `deploy/` defines the role ([deployment](../octomaton/designs/deployment.md)) |
| ServiceAccount `reviewer` | The pull request reviewer's tasks. No token mounted, no RoleBinding, no Google Cloud role |
| NetworkPolicy `sandbox` | Pods labelled `kfirs.com/sandbox: "true"`: no ingress; egress only to `0.0.0.0/0` except `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10` and `169.254.0.0/16` (pods, Services, nodes, the metadata server, cluster DNS) |
| ExternalSecret `reviewer-deepseek-api-key` | Secret `reviewer-deepseek-api-key`, key `api-key`, from Secret Manager `reviewer-deepseek-api-key` |
| ExternalSecret `reviewer-github-pat` | Secret `reviewer-github-pat`, key `token`, from Secret Manager `reviewer-github-pat` |
| ExternalSecret `linear-api-key` | Secret `linear-api-key`, key `api-key`, from Secret Manager `linear-api-key`: check `Linear`'s read-only Linear API key |

The docs pipelines: [docs site composition](../hub/designs/docs-site-composition.md). The reviewer:
[design](../tooling/designs/pr-reviewer.md). Check `Linear`, tooling's organization pipeline `linear`:
[Linear](../CONTRIBUTING.md#linear).

A pipeline that needs Google Cloud names a ServiceAccount of its own, from `tenants/<repository>/`, without a mounted
token:

| Tenant | ServiceAccount | `octomaton.dev/branches` | Pipeline |
| --- | --- | --- | --- |
| `ci-infra` | `ci-infra-plan` | None | `ci`: plans on pull requests and in the merge queue |
| `ci-infra` | `ci-infra-apply` | `main` | `apply`: applies merges to `main` |
| `ci-octomaton` | `ci-octomaton-release` | `main` | `release` and `reviewer-image`: push images |
| `ci-tooling` | `ci-tooling-publish` | `main` | `publish`: writes bucket `arikkfir-claude` |
| `ci-fin` | `ci-fin-release` | `main` | `release`: production's images; saves the CI cache |
| `ci-fin` | `ci-fin-preview` | None | `preview`: pull requests' images |
| `ci-fin` | `ci-fin-ci` | None | `ci` and `e2e`: restore the CI cache, upload end-to-end reports |

`ci-delivery` and `ci-docs` have the base only. Their Google Cloud roles: [infra's IAM](../infra/terraform/gcp.md#iam).

## Labels

Hub-wide labels share the prefix `kfirs.com/`.

| Label | On | Means | Set by |
| --- | --- | --- | --- |
| `kfirs.com/public-ingress: "true"` | Namespace | May attach routes to Gateway `public`, which has no sign-in | The Applications' `managedNamespaceMetadata` (`auth`, `docs`, `keycloak`, `go-import`) and Application `octomaton`'s `kustomize` options (`octomaton`). Policy `fin-namespaces` refuses it on Fin's namespaces |
| `kfirs.com/pull-request: "true"` | Namespace | A Fin pull request's or merge queue entry's environment: `gcp-secret-manager` serves it nothing, it reaches NATS on 4222, and its routes may attach to `traefik/fin-pull-requests` | ApplicationSet `fin-pull-requests`; policy `fin-namespaces` requires it on `fin-pr-*` |
| `kfirs.com/pool: <pool>` | Node | Node pool `system`, `ci` or `fin`, which pods select; `ci` and `fin` are also tainted `kfirs.com/pool=<pool>:NoSchedule` | `infra` ([node pools](../infra/terraform/gcp.md#node-pools)); pods select it ([node pools](designs/node-pools.md)) |
| `kfirs.com/sandbox: "true"` | Pod | A pull request reviewer's or check `Linear`'s pod, which NetworkPolicy `sandbox` holds | `tooling`'s reviewer and `linear` PipelineRuns |

Octomaton writes its bookkeeping labels and annotations under `octomaton.dev/` on the objects it creates
([Octomaton's README](https://github.com/arikkfir-org/octomaton#deployment)); the one it reads,
`octomaton.dev/branches`, is set here on tenants' ServiceAccounts ([CI tenants](#ci-tenants)).
