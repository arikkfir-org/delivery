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
| `external-secrets` | External Secrets Operator (`external-secrets`), with ClusterSecretStore `gcp-secret-manager`: Secret Manager of project `arikkfir`, for every namespace labelled neither `kfirs.com/pull-request` nor `kfirs.com/cobranch-pull-request` | Chart `external-secrets`, `https://charts.external-secrets.io` | `2.13.0` | 1 |
| `argocd` | Argo CD (`argocd`), self-managed after Terraform's bootstrap ([infra's argocd root](../infra/terraform/argocd.md)) | Chart `argo-cd`, `https://argoproj.github.io/argo-helm` | `10.10.5` (Argo CD v3.5.5) | 2 |
| `traefik` | Traefik (`traefik`): GatewayClass `traefik`, Gateways `protected` and `public`, two replicas ([ingress](#ingress)) | Chart `traefik`, `https://traefik.github.io/charts` | `42.0.0` (Traefik v3.7.15, pinned in its values: the chart's is v3.7.14) | 3 |
| `tekton-operator` | Tekton Operator (`tekton-operator`), which installs no default TektonConfig (`AUTOINSTALL_COMPONENTS: "false"`) | `tektoncd/operator` release manifest, from `infra.tekton.dev` | `v0.81.1` | 3 |
| `keda` | KEDA (`keda`) | Chart `keda`, `https://kedacore.github.io/charts` | `2.21.0` | 3 |
| `reloader` | Stakater Reloader (`reloader`) | Chart `reloader`, `https://stakater.github.io/stakater-charts` | `2.2.17` (Reloader v1.4.22) | 3 |
| `nats` | NATS with JetStream (`nats`): three clustered servers, a 50Gi volume each, and nats-box ([NATS](#nats)) | Chart `nats`, `https://nats-io.github.io/k8s/helm/charts` | `2.15.1` | 3 |
| `keycloak` | Keycloak Operator (`keycloak-operator`), watching namespace `keycloak` only | `keycloak/keycloak-k8s-resources` release kustomization (`kubernetes/`) | `26.8.1` | 3 |
| `auth` | oauth2-proxy (`auth`), the hub's sign-in, two replicas ([phase 3](designs/phase-3-ingress-and-auth.md)) | Chart `oauth2-proxy`, `https://oauth2-proxy.github.io/manifests` | `10.7.1` (oauth2-proxy 7.15.5) | 4 |
| `grafana` | Grafana (`grafana`), two replicas, reading Cloud Monitoring | Chart `grafana`, `https://grafana-community.github.io/helm-charts` | `14.0.0` (Grafana 13.2.4) | 4 |
| `grafana` | PostgreSQL for Grafana: StatefulSet `postgres` ([Grafana](#grafana)) | `docker.io/library/postgres`, in `platform/grafana/manifests` | `18.6-trixie` | 4 |
| `nats` | NACK, the JetStream controller (`nack`) | Chart `nack`, `https://nats-io.github.io/k8s/helm/charts` | `0.35.0` (NACK 0.24.0) | 4 |
| `nats` | NUI (`nui`) | Chart `nui`, `https://nats-nui.github.io/k8s/helm/charts` | `0.1.6` (image `0.9.3`, pinned in its values: the chart's is `latest`) | 4 |
| `tekton-pipelines` | Pipelines, Triggers and the Dashboard (`tekton`), through TektonConfig `config` (profile `all`), with Results, Chains, Pipelines-as-Code and the operator's NetworkPolicies off. Default ServiceAccount `pipeline`; TaskRun pods on node pool `ci`; 30 PipelineRuns kept per namespace. The Dashboard reads the logs of steps whose pods are gone from `http://octomaton-logs.octomaton.svc.cluster.local/logs` | `platform/tekton/manifests`, installed by the operator | Those of operator `v0.81.1` | 4 |
| `octomaton` | Octomaton and `octomaton-logs` (`octomaton-environment`): Applications `octomaton` and `octomaton-logs`, AppProject `octomaton`, and the hub's side of Octomaton's host contract: ConfigMaps `octomaton` and `octomaton-logs`, ExternalSecret `octomaton-github`, HTTPRoute `octomaton`, NetworkPolicies `octomaton` and `octomaton-logs` ([hosting Octomaton](designs/octomaton.md)) | `deploy/` and `deploy/logs/` of `arikkfir-org/octomaton` at the version's tag; the host objects in `platform/octomaton/manifests` | `v0.5.0` ([versioned releases](../octomaton/designs/releases.md)) | 4 |
| `docs` | Docs site (`docs`): Caddy, two replicas ([design](designs/docs-and-tests-servers.md)) | `docker.io/library/caddy`, in `platform/docs/manifests` | `2.11.7-alpine` | 4 |
| `tests` | Tests site (`tests`): Caddy, two replicas ([design](designs/docs-and-tests-servers.md)) | `docker.io/library/caddy`, in `platform/tests/manifests` | `2.11.7-alpine` | 4 |
| `go-import` | Go import pages (`go-import`): Caddy, two replicas ([design](designs/go-import-pages.md)) | `docker.io/library/caddy`, in `platform/go-import/manifests` | `2.11.7-alpine` | 4 |
| `cobranch-site` | Cobranch's site at `cobranch.dev` (`cobranch-site`): a static "Coming soon" page and the domain's Go import page, from Caddy, two replicas ([design](designs/cobranch-site.md)) | `docker.io/library/caddy`, in `platform/cobranch-site/manifests` | `2.11.7-alpine` | 4 |
| `ci-<repository>` | CI tenants (`ci-tenants`) ([CI tenants](#ci-tenants)) | `platform/ci-tenants/manifests` | n/a | 4 |
| `keycloak` | Keycloak (`keycloak`): resource `keycloak`, two instances, Service `keycloak-service` on 8080 ([design](designs/keycloak.md)) | `quay.io/keycloak/keycloak`, in `platform/keycloak/manifests` | `26.8.1` | 4 |
| `keycloak` | PostgreSQL for Keycloak: StatefulSet `postgres` ([design](designs/keycloak.md#in-the-cluster)) | `docker.io/library/postgres`, in `platform/keycloak/manifests` | `18.6-trixie` | 4 |
| `cobranch-app` | `cobranch.app`, Cobranch's hosted service (`cobranch-app-environment`): Namespace `cobranch-app`, AppProject `cobranch-app`, Application `cobranch-app` (the chart's Console, Back-office, REST, GraphQL, Auth, Admin and Git servers, push worker, migrate Job, maintenance CronJob, PostgreSQL and HTTPRoutes), ExternalSecrets `cobranch-postgresql-password`, `cobranch-secrets-key` and `cobranch-google`, NetworkPolicies `cobranch` and `cobranch-git-internal`, admission policies `cobranch-app-http-routes` and `cobranch-app-cluster-ip-services`, and Gateway `traefik/cobranch-app` ([hosting cobranch.app](designs/cobranch-app.md)) | `chart/cobranch` of `arikkfir-org/cobranch` at `main`; the host objects in `platform/cobranch-app/manifests` | The synced commit's images | 4 |
| `cobranch-pr-<number>` | Cobranch's pull requests' previews (`cobranch-environment`): ApplicationSet `cobranch-pull-requests`, AppProject `cobranch-pull-requests`, admission policies `cobranch-*`, and Gateway `traefik/cobranch-pull-requests` ([Cobranch's previews](designs/cobranch-previews.md)) | `chart/cobranch` of `arikkfir-org/cobranch` at the head commit of each pull request its members open; the host objects in `platform/cobranch/pull-request`, and, for each head commit, Job `cobranch-recreate-database-<sha7>` in `platform/cobranch/pull-request-commit`, which empties the database | The head commit's images | 4 |
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
| `traefik/public` | `public-web` 9080→80 (redirects to HTTPS), `public-websecure` 9443→443; Service `traefik-public` | `ingress-public` | `strip-auth-headers` only | Namespaces labelled `kfirs.com/public-ingress: "true"`; listener `octomaton-dev` only `octomaton` and `go-import` among them, and `cobranch-dev` only `cobranch-site` |

The middlewares and the sign-in: [phase 3](designs/phase-3-ingress-and-auth.md). The hub's tools add Middleware
`admins` on their routes ([admins only](designs/admins-only.md)).

### Certificates

cert-manager issues them from Let's Encrypt through ClusterIssuer `letsencrypt`, solving DNS-01 in Cloud DNS: zone
`octomaton-dev` for `octomaton.dev`, zone `cobranch-dev` for `cobranch.dev`, zone `cobranch-app` for `cobranch.app` and
`git.cobranch.app`, zone `kfirs-com` for every other name.

| Listener | Hostname | Certificate / Secret |
| --- | --- | --- |
| `protected/websecure`, `public/public-websecure` | `*.kfirs.com`, which also matches deeper names | `wildcard-kfirs-com` (`*.kfirs.com`, `*.dev.kfirs.com`, `admin.id.kfirs.com`) / `traefik/wildcard-kfirs-com-tls`, also Traefik's default certificate |
| `public/octomaton-dev` (9443) | `octomaton.dev` | `octomaton-dev` / `traefik/octomaton-dev-tls` |
| `public/cobranch-dev` (9443) | `cobranch.dev` | `cobranch-dev` / `traefik/cobranch-dev-tls` |
| `fin-pull-requests/app` (8443) | `*.app.dev.fin.kfirs.com` | `fin-pull-requests` / `traefik/fin-pull-requests-tls` |
| `cobranch-pull-requests/previews` (8443) | `*.cobranch.dev.kfirs.com` | `cobranch-pull-requests` / `traefik/cobranch-pull-requests-tls` |
| `cobranch-git/previews` (9443) | `*.git.cobranch.dev.kfirs.com` | `cobranch-git` / `traefik/cobranch-git-tls` |
| `cobranch-app/app`, `cobranch-app/git` (9443) | `cobranch.app`, `git.cobranch.app` | `cobranch-app` (both names) / `traefik/cobranch-app-tls` |

Listener `octomaton-dev` admits routes only from namespaces `octomaton` (the webhook) and `go-import` (the Go import
page), and only while they carry `kfirs.com/public-ingress: "true"`. Listener `cobranch-dev` admits routes only from
`cobranch-site`, on the same condition. Gateway `cobranch-git` is on the public entry point without that label: its one listener, `previews`, admits routes only from namespaces labelled `kfirs.com/cobranch-pull-request: "true"`, which policy `cobranch-http-routes` holds to Service `cobranch-git-server` ([Cobranch's previews](designs/cobranch-previews.md)). Gateway `cobranch-app` is on the public entry point too, without the label: both its listeners admit routes only from namespace `cobranch-app`, whose routes policy `cobranch-app-http-routes` holds to this Gateway, and whose Services policy `cobranch-app-cluster-ip-services` holds to `ClusterIP` ([hosting cobranch.app](designs/cobranch-app.md)).

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
| `pr-<number>.cobranch.dev.kfirs.com` | `cobranch-pull-requests` | `cobranch-pr-<number>/cobranch-rest-server:80`; `…/cobranch-graphql-server:80`; `…/cobranch-auth-server:80`; `…/cobranch-admin-server:80`; `…/cobranch-back-office:80`; `…/cobranch-console:80` | `/api`, `/graphql`, `/auth`, `/admin` and `/back-office`, each prefix rewritten to `/`; everything else | `admins` |
| `pr-<number>.git.cobranch.dev.kfirs.com` | `cobranch-git`, listener `previews` (public) | `cobranch-pr-<number>/cobranch-git-server:80` | All | None |
| `admin.id.kfirs.com` | protected | `keycloak/keycloak-service:8080` | Exact `/` (Keycloak redirects it to the console), `/admin`, `/realms/master`, `/resources` | `admins` |
| `auth.kfirs.com` | public | `auth/oauth2-proxy:80` | `/oauth2` | None |
| `id.kfirs.com` | public | `keycloak/keycloak-service:8080` | `/realms/hub`, `/resources`; POSTs under `/realms/hub/login-actions`; `/realms/master` | None; `sign-in-attempts`; `oidc`, `admins` |
| `legal.kfirs.com` | public | `docs/docs:80` | Exact `/privacy.html`, `/privacy.md.html`, `/tos.html`, `/tos.md.html` | None |
| `fin.kfirs.com` | public | `go-import/go-import:80` | All | None |
| `octomaton.dev` | public, listener `octomaton-dev` | `octomaton/octomaton:80` (HTTPRoute `octomaton`, [hosting Octomaton](designs/octomaton.md)); `go-import/go-import:80` | Exact `/github/hooks`; everything else | None |
| `cobranch.app` | `cobranch-app`, listener `app` (public) | `cobranch-app/cobranch-rest-server:80`; `…/cobranch-graphql-server:80`; `…/cobranch-auth-server:80`; `…/cobranch-admin-server:80`; `…/cobranch-back-office:80`; `…/cobranch-console:80` (the chart's HTTPRoutes) | `/api`, `/graphql`, `/auth`, `/admin` and `/back-office`, each prefix rewritten to `/`; everything else | None: Cobranch signs people in itself |
| `git.cobranch.app` | `cobranch-app`, listener `git` (public) | `cobranch-app/cobranch-git-server:80` (the chart's HTTPRoute) | All | None: the Git server signs requests in with personal tokens |
| `cobranch.dev` | public, listener `cobranch-dev` | `cobranch-site/cobranch-site:80` (Cobranch's site and Go import page, [design](designs/cobranch-site.md)) | Everything | None |

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

Cobranch's previews have the same shape in `platform/cobranch/manifests`: Certificate and Gateway `traefik/cobranch-pull-requests`
for `*.cobranch.dev.kfirs.com`, listener `previews`, taking routes only from namespaces labelled
`kfirs.com/cobranch-pull-request: "true"`, each held by policy `cobranch-http-routes` to its own host
([Cobranch's previews](designs/cobranch-previews.md)). Their Git servers share Gateway `traefik/cobranch-git`, on the public entry point ([above](#certificates)).

DNS records and the two IPs are `infra`'s: [DNS](../infra/terraform/gcp.md#dns),
[network](../infra/terraform/gcp.md#network).

## CI tenants

Application `ci-tenants` creates namespace `ci-<repository>` for every repository but `.github`, which has no CI:
`ci-infra`, `ci-delivery`, `ci-octomaton`, `ci-tooling`, `ci-docs`, `ci-fin` and `ci-cobranch`. Octomaton
runs each repository's pipelines in its tenant, which it names after the repository.

Every tenant gets the base (`platform/ci-tenants/manifests/base`):

| Object | Spec |
| --- | --- |
| ServiceAccount `pipeline` | Tekton's default, for every PipelineRun that names no other. Any branch's run can use it, so it never holds a Google Cloud role; no `octomaton.dev/branches` |
| ServiceAccount `docs-reader` | The organization pipeline `docs` (check `Docs`), on pull requests and merge groups. No token mounted; no `octomaton.dev/branches` |
| ServiceAccount `docs-publisher` | The organization pipeline `docs-publish`, on pushes to `main`, writing the repository's layer. No token mounted; `octomaton.dev/branches: main` |
| RoleBinding `octomaton` | ClusterRole `octomaton-tenant` to ServiceAccount `octomaton/octomaton`. Octomaton's `deploy/` defines the role ([hosting Octomaton](designs/octomaton.md)) |
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

| Tenant | ServiceAccount | Refs (`octomaton.dev/branches`, `octomaton.dev/tags`) | Pipeline |
| --- | --- | --- | --- |
| `ci-infra` | `ci-infra-plan` | None | `ci`: plans on pull requests and in the merge queue |
| `ci-infra` | `ci-infra-apply` | `main` | `apply`: applies merges to `main` |
| `ci-octomaton` | `ci-octomaton-release` | branch `main`, tags `v*` | `main`: pushes Octomaton's images of every commit on `main`; `tag`: adds a version's tag to them ([versioned releases](../octomaton/designs/releases.md)) |
| `ci-octomaton` | `ci-octomaton-ci` | None | `ci`: restores `main`'s or its pull request's Go caches, saves its pull request's |
| `ci-cobranch` | `ci-cobranch-release` | branch `main`, tags `v*` | `main`: pushes Cobranch's images of `main`'s newest commit, which `cobranch.app` runs ([hosting cobranch.app](designs/cobranch-app.md)); `tag`: adds a version's tag to them and publishes the chart at that version ([the Cobranch repository](../cobranch/designs/repository.md)) |
| `ci-cobranch` | `ci-cobranch-preview` | None | `preview`: pushes each pull request's head commit's images to `cobranch-previews`, which only previews pull ([Cobranch's previews](designs/cobranch-previews.md)) |
| `ci-tooling` | `ci-tooling-publish` | `main` | `publish`: writes bucket `arikkfir-claude`; `reviewer-image`: pushes the reviewer image |
| `ci-fin` | `ci-fin-release` | `main` | `release`: production's images; saves the CI cache |
| `ci-fin` | `ci-fin-preview` | None | `preview`: pull requests' images |
| `ci-fin` | `ci-fin-ci` | None | `ci` and `e2e`: restore the CI cache, upload end-to-end reports |

`ci-delivery` and `ci-docs` have the base only. Their Google Cloud roles:
[infra's IAM](../infra/terraform/gcp.md#iam).

## Labels

Hub-wide labels share the prefix `kfirs.com/`.

| Label | On | Means | Set by |
| --- | --- | --- | --- |
| `kfirs.com/public-ingress: "true"` | Namespace | May attach routes to Gateway `public`, which has no sign-in | The Applications' `managedNamespaceMetadata` (`auth`, `docs`, `keycloak`, `go-import`, `cobranch-site`) and Application `octomaton`'s `kustomize` options (`octomaton`). Policy `fin-namespaces` refuses it on Fin's namespaces |
| `kfirs.com/pull-request: "true"` | Namespace | A Fin pull request's or merge queue entry's environment: `gcp-secret-manager` serves it nothing, it reaches NATS on 4222, and its routes may attach to `traefik/fin-pull-requests` | ApplicationSet `fin-pull-requests`; policy `fin-namespaces` requires it on `fin-pr-*` |
| `kfirs.com/cobranch-pull-request: "true"` | Namespace | A Cobranch pull request's preview: `gcp-secret-manager` serves it nothing, and its routes may attach to `traefik/cobranch-pull-requests` and to listener `previews` of `traefik/cobranch-git`. Not `kfirs.com/pull-request`, which would admit it to NATS and Fin's Gateway | `platform/cobranch/pull-request`; policy `cobranch-namespaces` requires it on `cobranch-pr-*`, and refuses every other `kfirs.com/` label there |
| `kfirs.com/pool: <pool>` | Node | Node pool `system`, `ci` or `fin`, which pods select; `ci` and `fin` are also tainted `kfirs.com/pool=<pool>:NoSchedule` | `infra` ([node pools](../infra/terraform/gcp.md#node-pools)); pods select it ([node pools](designs/node-pools.md)) |
| `kfirs.com/sandbox: "true"` | Pod | A pull request reviewer's or check `Linear`'s pod, which NetworkPolicy `sandbox` holds | `tooling`'s reviewer and `linear` PipelineRuns |

Octomaton writes its bookkeeping labels and annotations under `octomaton.dev/` on the objects it creates
([Octomaton's README](https://github.com/arikkfir-org/octomaton#deployment)). It reads three on tenants'
ServiceAccounts: `octomaton.dev/branches`, `octomaton.dev/tags` and `octomaton.dev/organization-pipelines`
([organization pipelines on restricted ServiceAccounts](../octomaton/designs/organization-pipeline-accounts.md)). Only the
first two are set here ([CI tenants](#ci-tenants)); no tenant's ServiceAccount carries the third.
