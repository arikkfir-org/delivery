# delivery

Argo CD GitOps repository for the `arikkfir-org` development hub: everything that runs inside the GKE cluster `hub` is
declared here, and Argo CD applies it from `main`. Octomaton's own manifests are the exception (below). Names, versions,
hosts and identities follow the hub reference (`docs/hub/reference.md` in
[arikkfir-org/docs](https://github.com/arikkfir-org/docs)), which is the contract between this repository, `infra` and
`octomaton`.

## Layout

```text
apps/<component>.yaml                One Argo CD Application per component (synced by the root Application)
platform/<component>/values.yaml     Helm values, for chart-based components
platform/<component>/manifests/      Plain manifests with a kustomization.yaml, where needed
.octomaton.yaml, .tekton/ci.yaml   CI for this repository (run by Octomaton on Tekton)
```

## How it syncs

Terraform (`infra`, `terraform/argocd`) installs Argo CD and one Application, `root`, which syncs `apps/` from `main`.
Each file there is an Application in namespace `argocd`, project `default`:

- A chart-based component has three sources: the pinned chart (with `helm.releaseName` and
  `valueFiles: [$values/platform/<component>/values.yaml]`), this repository as `ref: values`, and
  `platform/<component>/manifests` when it has extra manifests. A manifest-only component has one source, that path.
- `octomaton-environment` is the exception: Octomaton's manifests live with its code. `deploy/` of
  `arikkfir-org/octomaton` (Kustomize) is the hub's deployment as written, its Namespace included, and Application
  `octomaton` (`platform/octomaton/manifests`) deploys it from that repository's `main`, overriding in its `kustomize`
  options what this repository decides: the image tag, `${ARGOCD_APP_REVISION_SHORT}` (the short SHA of the synced
  commit, which Octomaton's `release` publishes on every push), and the namespace's label
  `kfirs.com/public-ingress: "true"`. A merge there deploys itself. AppProject `octomaton` admits only namespace
  `octomaton`, Octomaton's own ClusterRoles and ClusterRoleBinding, and the namespaced kinds `deploy/` holds. Only
  reviewed commits on `main` deploy, so no admission policies hold what they say, unlike Fin's pull requests.
- `fin-environments` deploys Fin the same way
  ([design](https://github.com/arikkfir-org/fin/blob/main/docs/fin/designs/environments.md)). `deploy/` of
  `arikkfir-org/fin` (Kustomize) is production as written: Application `fin` deploys it from that repository's `main`
  into namespace `fin`, and ApplicationSet `fin-pull-requests` deploys each open pull request's head commit into
  `fin-pr-<number>`, overriding what differs in its `kustomize` options (images, namespace, replicas, patches such as
  the host names, and the components that reset the database and hold what else differs inside a pull request's
  environment). Fin's code holds its own Namespace, routes, ExternalSecrets, NATS resources (NACK), autoscaling (KEDA)
  and the Middleware that copies the hub's ID token, and production's its Gateway and certificate too, so AppProjects
  `fin` and `fin-pull-requests` admit only its kinds, admission policies hold what they may say, and
  `gcp-secret-manager` serves no pull request (all in `platform/fin/manifests` but the store's conditions).
  Production's ServiceAccounts `api`, `worker` and `scraper` come from Application `fin-identities`
  (`platform/fin/identities`), since Fin's code makes none; a pull request's pods run as `default` and reach Google
  through infra's pool `fin-pull-requests`. Pull requests share Gateway `traefik/fin-pull-requests` and its
  one wildcard certificate, so a pull request issues no certificate. Argo CD reads `fin`, an internal repository, and
  lists its pull requests with its own GitHub App (Secret `argocd/github-app`).
- Every Application syncs automatically with prune and self-heal, retries with backoff (`refresh: true`, so a retry
  picks up a newer commit), and creates its namespace, except those whose `deploy/` holds it (Octomaton's and Fin's).
  Namespace labels come from `managedNamespaceMetadata`
  (for example `kfirs.com/public-ingress: "true"` on `auth`, `docs`, `keycloak` and `go-import`). `ServerSideApply=true` is set where CRDs
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
| 4 | `auth`, `grafana`, `nack`, `nui`, `tekton`, `octomaton-environment`, `docs`, `ci-tenants`, `keycloak`, `fin-environments`, `go-import` |

Within an Application, waves order dependent resources as well: ClusterIssuers and the ClusterSecretStore wait for their
operators' webhooks; in `traefik` the Certificates (the wildcard and `octomaton-dev`) are issued before the Gateways
that reference their Secrets, and so is `fin-pull-requests`'s in `fin-environments`.

Secrets never live in Git: each one is an `ExternalSecret` reading Secret Manager through the `ClusterSecretStore`
`gcp-secret-manager`. A credential only the cluster uses is generated instead, by an ESO `Password` generator with
`refreshPolicy: CreatedOnce` (Grafana's database password). Every UI is served on the `protected` gateway, behind the
oauth2-proxy interceptor; only `auth.kfirs.com/oauth2`, `octomaton.dev` (Octomaton's webhook and Go import page),
`legal.kfirs.com` (the docs site's privacy policy and terms of service, exact paths only), `id.kfirs.com` (Keycloak's
realm `hub`, and realm `master` behind the interceptor) and `fin.kfirs.com` (Fin's Go import page, `go-import`) use the
`public` gateway. Fin's host names need certificates of their own, so production's environment has a Gateway of its
own, and pull requests' share `fin-pull-requests`, both on the protected gateway's entry point, behind the same
interceptor.

Removing a file from `apps/` deletes the Application but not its resources (no cascading finalizer). Delete the
resources deliberately, or cascade-delete the Application before removing its file.

## Add a component

1. Add `apps/<component>.yaml`, copying an existing Application of the same shape. Pick the wave by dependency: a
   component must come after the components whose CRDs, webhooks or Gateways it uses.
2. Add `platform/<component>/values.yaml` (pin the chart version in the Application) and/or
   `platform/<component>/manifests/` with a `kustomization.yaml`. Pin every image tag.
3. A UI gets an `HTTPRoute` on the `protected` gateway (`traefik` namespace) and a NetworkPolicy that admits only the
   `traefik` namespace to its pods. Select only those pods, never the whole namespace.
4. Validate (below), then open a pull request. Add the names to the hub reference first if they are new.

## Add a CI tenant

A repository runs its CI in namespace `ci-<repository>` (`.github` has no CI):

1. Copy a directory under `platform/ci-tenants/manifests/tenants/`, set its `namespace`, and list it in
   `platform/ci-tenants/manifests/kustomization.yaml`. This creates the namespace, the `pipeline` ServiceAccount and the
   RoleBinding that lets Octomaton run pipelines there.
2. If its pipelines need Google Cloud access, grant it to the Workload Identity principal of `ci-<repository>/pipeline`
   in `infra`.
3. Add `.octomaton.yaml` and a PipelineRun file to the repository.

## Validate

```bash
yamllint --strict .
for k in $(find platform -name kustomization.yaml); do kubectl kustomize "$(dirname "$k")" >/dev/null; done
helm template traefik traefik --repo https://traefik.github.io/charts --version 41.6.0 -n traefik \
  -f platform/traefik/values.yaml >/dev/null   # likewise for every chart-based component
```

CI (`.tekton/ci.yaml`) runs yamllint, renders every kustomization, and validates `apps/` and the rendered manifests
with kubeconform against the [CRDs-catalog](https://github.com/datreeio/CRDs-catalog) schemas. `fin`'s own CI renders
its `deploy/` with the `kustomize` options of this repository's `main`, as Argo CD does.
