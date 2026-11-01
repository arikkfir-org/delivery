# delivery

Argo CD GitOps repository for the `arikkfir-org` development hub: everything that runs inside the GKE cluster `hub` is
declared here, and Argo CD applies it from `main`. Octomaton's own manifests are the exception (below). The names,
versions, hosts and identities this repository creates are documented in
[the hub platform](https://docs.dev.kfirs.com/delivery/platform.md) and the designs under `docs/delivery/`, and change
with the code there; other repositories link those pages rather than repeat them, and follow a change in the same unit
of work. What `infra` provisions for the cluster is described in its
[Terraform roots](https://docs.dev.kfirs.com/infra/terraform/gcp.md), and Octomaton's and Fin's deployments in their own
pages, which this repository links. A change that needs a new or different value from another repository says so.

## Layout

```text
apps/<component>.yaml                One Argo CD Application per component (synced by the root Application)
platform/<component>/values.yaml     Helm values, for chart-based components
platform/<component>/manifests/      Plain manifests with a kustomization.yaml, where needed
.octomaton.yaml, .tekton/          CI for this repository (run by Octomaton on Tekton)
```

## How it syncs

Terraform (`infra`, `terraform/argocd`) installs Argo CD and one Application, `root`, which syncs `apps/` from `main`.
Each file there is an Application in namespace `argocd`, project `default`:

- A chart-based component has three sources: the pinned chart (with `helm.releaseName` and
  `valueFiles: [$values/platform/<component>/values.yaml]`), this repository as `ref: values`, and
  `platform/<component>/manifests` when it has extra manifests. A manifest-only component has one source, that path.
- `octomaton-environment` is the exception: Octomaton's manifests live with its code. `deploy/` of
  `arikkfir-org/octomaton` (Kustomize) is what every installation of Octomaton applies as written, its Namespace
  included, and `deploy/logs/` its step logs server, which a host applies or not. Applications `octomaton` and
  `octomaton-logs` (`platform/octomaton/manifests`) deploy them from a version of that repository (its tag, such as
  `v0.5.0`), overriding in their `kustomize` options what this repository decides: the tag of the images, `octomaton`
  and `octomaton-logs`, the same version (which Octomaton's `tag` pipeline adds to the images its `main` published for
  that commit), the namespace's label `kfirs.com/public-ingress: "true"`, and the system node pool for the
  Deployments. A new version deploys through a pull request here that bumps it in both Applications. What the hub decides around it lives beside the Application: the servers'
  ConfigMaps, the GitHub App's ExternalSecret, the webhook's HTTPRoute and the NetworkPolicies
  ([hosting Octomaton](docs/delivery/designs/octomaton.md)), and `ci` renders each the way its Application deploys
  it (`.tekton/octomaton-manifests.sh`). AppProject `octomaton` admits only namespace `octomaton`, Octomaton's own
  ClusterRoles and ClusterRoleBinding, and the namespaced kinds `deploy/` and `deploy/logs/` hold. Only versions, tags of reviewed commits on `main`,
  deploy, so no admission policies hold what they say, unlike Fin's pull requests.
- `fin-environments` deploys Fin the same way
  ([design](https://docs.dev.kfirs.com/fin/designs/environments.md)). `deploy/` of
  `arikkfir-org/fin` (Kustomize) is production as written: Application `fin` deploys it from that repository's `main`
  into namespace `fin`, and ApplicationSet `fin-pull-requests` deploys each open pull request's head commit into
  `fin-pr-<number>`, and each merge queue entry's merge group commit into `fin-pr-<number>-merge`,
  overriding what differs in its `kustomize` options (images, namespace, replicas, patches such as
  the host names, and the components that reset the database and hold what else differs inside a pull request's
  environment). Fin's code holds its own Namespace, routes, ExternalSecrets, NATS resources (NACK), autoscaling (KEDA)
  and the Middleware that copies the hub's ID token, and production's its Gateway and certificate too, so AppProjects
  `fin` and `fin-pull-requests` admit only its kinds, admission policies hold what they may say, and
  `gcp-secret-manager` serves no pull request (all in `platform/fin/manifests` but the store's conditions).
  Production's ServiceAccounts `api`, `worker` and `scraper` come from Application `fin-identities`
  (`platform/fin/identities`), since Fin's code makes none; a pull request's pods run as `default` and reach Google
  through infra's pool `fin-pull-requests`. NATS takes no credentials, so NetworkPolicy `nats/nats`
  (`platform/nats/manifests`) admits only namespace `nats` and, on the client port, Fin's namespaces: `fin` and those
  labelled `kfirs.com/pull-request: "true"`. Pull requests share Gateway `traefik/fin-pull-requests` and its
  one wildcard certificate, so a pull request issues no certificate. Argo CD reads `fin`, an internal repository, and
  lists its pull requests with its own GitHub App (Secret `argocd/github-app`).
- `cobranch-environment` deploys Cobranch's demo ([hosting Cobranch's demo](docs/delivery/designs/cobranch.md)):
  Application `cobranch` installs `chart/cobranch` of `arikkfir-org/cobranch` from its `main` into namespace `cobranch`,
  with the images of the synced commit, which cobranch's pipeline `main` publishes, and the values this repository
  decides. Its namespace, AppProject `cobranch`, the database's generated password, the route behind Middleware `admins`
  and the NetworkPolicy live beside it in `platform/cobranch/manifests`. It also previews every open pull request
  cobranch's members open ([Cobranch's previews](docs/delivery/designs/cobranch-previews.md)): ApplicationSet
  `cobranch-pull-requests` installs the chart from each head commit into `cobranch-pr-<number>`, beside
  `platform/cobranch/pull-request`, under AppProject `cobranch-pull-requests` and admission policies `cobranch-*`.
- `cobranch-app-environment` deploys `cobranch.app`, Cobranch's hosted service
  ([hosting cobranch.app](docs/delivery/designs/cobranch-app.md)): Application `cobranch-app` installs `chart/cobranch`
  of `arikkfir-org/cobranch` from its `main` into namespace `cobranch-app`, upgrading it in place, with the chart's own
  routes on Gateway `traefik/cobranch-app`, Google sign-in and a nightly database dump, in `platform/cobranch-app/manifests`.
- Every Application syncs automatically with prune and self-heal, retries with backoff (`refresh: true`, so a retry
  picks up a newer commit; ten times, but twice for Fin's pull requests, whose syncs can wait 20 minutes a try for
  images that never come), and creates its namespace, except those whose `deploy/` holds it (Octomaton's and Fin's)
  and `octomaton-logs`, which syncs a wave after `octomaton`, whose `deploy/` holds the namespace it shares.
  Namespace labels come from `managedNamespaceMetadata`
  (for example `kfirs.com/public-ingress: "true"` on `auth`, `docs`, `keycloak`, `go-import` and `cobranch-site`). `ServerSideApply=true` is set where CRDs
  are too large for client-side apply; `SkipDryRunOnMissingResource=true` where resources use CRDs of another component.
  Such an Application diffs by structured merge, which can't add CRD defaults, so one that also holds resources whose
  atomic lists get defaults (`argocd`, for its HTTPRoute) diffs server-side:
  `argocd.argoproj.io/compare-options: ServerSideDiff=true`.
- `argocd` manages Argo CD itself with the chart and release name Terraform bootstrapped. Its `argocd-cm` restores the
  health check for `argoproj.io/Application`, so the root Application's sync waves wait for each wave to be healthy:

| Wave | Applications |
| --- | --- |
| 1 | `gateway-api`, `cert-manager`, `external-secrets` |
| 2 | `argocd` |
| 3 | `traefik`, `tekton-operator`, `keda`, `reloader`, `nats`, `keycloak-operator` |
| 4 | `auth`, `grafana`, `nack`, `nui`, `tekton`, `octomaton-environment`, `docs`, `tests`, `ci-tenants`, `keycloak`, `fin-environments`, `go-import`, `cobranch-site`, `cobranch-environment`, `cobranch-app-environment` |

Within an Application, waves order dependent resources as well: ClusterIssuers and the ClusterSecretStore wait for their
operators' webhooks; in `traefik` the Certificates (the wildcard, `octomaton-dev` and `cobranch-dev`) are issued before
the Gateways that reference their Secrets, and so is `fin-pull-requests`'s in `fin-environments`.

Secrets never live in Git: each one is an `ExternalSecret` reading Secret Manager through the `ClusterSecretStore`
`gcp-secret-manager`. A credential only the cluster uses is generated instead, by an ESO `Password` generator with
`refreshPolicy: CreatedOnce` (Grafana's database password). Every UI is served on the `protected` gateway, behind the
oauth2-proxy interceptor ([design](docs/delivery/designs/phase-3-ingress-and-auth.md)); only `auth.kfirs.com/oauth2`, `octomaton.dev` (Octomaton's webhook, and its Go import page from `go-import`), `cobranch.dev` (Cobranch's site and Go import page, `cobranch-site`),
`legal.kfirs.com` (the docs site's privacy policy and terms of service, exact paths only), `id.kfirs.com` (Keycloak's
realm `hub`, and realm `master` behind the interceptor) and `fin.kfirs.com` (Fin's Go import page, `go-import`, [design](docs/delivery/designs/go-import-pages.md)) use the
`public` gateway. Fin's host names need certificates of their own, so production's environment has a Gateway of its
own, and pull requests' share `fin-pull-requests`, both on the protected gateway's entry point, behind the same
interceptor. Every UI but Fin's then admits only group `admins` (Middleware `admins`, [design](docs/delivery/designs/admins-only.md)).

Every hub service runs on node pool `system`, whose GKE taint for managed components
(`components.gke.io/gke-managed-components=true:NoSchedule`) only GKE's components and the hub's services tolerate:
each one's pods select `kfirs.com/pool: system` and tolerate that taint, through its chart's values, its manifests, a
patch on a release manifest, TektonConfig's `spec.config` (whatever the Tekton operator installs) or the `kustomize`
options of Applications `octomaton` and `octomaton-logs`, each placing its own Deployments. TaskRun pods go to pool `ci` through Tekton's default pod template, and Fin's to pool
`fin` through Fin's `deploy/`; policy `fin-node-pool` refuses a pod in a Fin namespace that tolerates any other taint or
names its node ([design](docs/delivery/designs/node-pools.md)). The Tekton Dashboard reads the log of a step whose pod is
gone from `octomaton-logs`, which reads Cloud Logging.

Removing a file from `apps/` deletes the Application but not its resources (no cascading finalizer). Delete the
resources deliberately, or cascade-delete the Application before removing its file.

## Add a component

1. Add `apps/<component>.yaml`, copying an existing Application of the same shape. Pick the wave by dependency: a
   component must come after the components whose CRDs, webhooks or Gateways it uses.
2. Add `platform/<component>/values.yaml` (pin the chart version in the Application) and/or
   `platform/<component>/manifests/` with a `kustomization.yaml`. Pin every image tag. Put its pods on node pool `system`: a node
   selector `kfirs.com/pool: system` and a toleration of `components.gke.io/gke-managed-components=true:NoSchedule`
   ([design](docs/delivery/designs/node-pools.md)); without them it waits for a node once the pool is tainted. Give
   each container CPU and memory requests from what it uses and a memory limit above its peak, with no CPU limit
   ([design](docs/delivery/designs/resource-requests.md)); without requests it is evicted first. Give each Deployment
   and StatefulSet a PodDisruptionBudget of `maxUnavailable: 1` (and `unhealthyPodEvictionPolicy: AlwaysAllow` on a
   single replica's), and each Deployment the strategy `maxSurge: 1`, `maxUnavailable: 0`
   ([design](docs/delivery/designs/disruption-budgets.md)).
3. A UI gets an `HTTPRoute` on the `protected` gateway (`traefik` namespace) with Middleware `admins` in its own
   namespace (only group `admins` passes; [design](docs/delivery/designs/admins-only.md)), and a NetworkPolicy that
   admits only the `traefik` namespace to its pods. Select only those pods, never the whole namespace.
4. Validate (below), then open a pull request. Document new names, hosts and versions in the same pull request, in
   [the hub platform](docs/delivery/platform.md) or the component's design.

## Add a CI tenant

A repository runs its CI in namespace `ci-<repository>` (`.github` has no CI):

1. Copy a directory under `platform/ci-tenants/manifests/tenants/`, set its `namespace`, and list it in
   `platform/ci-tenants/manifests/kustomization.yaml`. The base creates the namespace, the ServiceAccounts `pipeline`,
   `docs-reader` and `docs-publisher`, the RoleBinding that lets Octomaton run pipelines there, the pull request
   reviewer's objects and check `Linear`'s Secret ([the hub platform](docs/delivery/platform.md#ci-tenants)).
2. If a pipeline needs Google Cloud access, give it a ServiceAccount of its own in `tenants/<repository>/`
   (`automountServiceAccountToken: false`, annotated `octomaton.dev/branches: main` when it publishes or applies), and
   have `infra` grant that ServiceAccount's Workload Identity principal. Never grant `pipeline`: any branch's run can
   use it.
3. Add `.octomaton.yaml` and a PipelineRun file to the repository.

## Validate

```bash
yamllint --strict .
for k in $(find platform -name kustomization.yaml); do kubectl kustomize "$(dirname "$k")" >/dev/null; done
helm template traefik traefik --repo https://traefik.github.io/charts --version 42.0.0 -n traefik \
  -f platform/traefik/values.yaml >/dev/null   # likewise for every chart-based component
```

CI (`.tekton/ci.yaml`) runs yamllint, renders every kustomization, and validates `apps/` and the rendered manifests
with kubeconform against the [CRDs-catalog](https://github.com/datreeio/CRDs-catalog) schemas. `fin`'s own CI renders
its `deploy/` with the `kustomize` options of this repository's `main`, as Argo CD does.
