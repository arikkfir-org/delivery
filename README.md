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
platform/<component>/<chart>/        A chart of this repository's own, where Applications deploy one thing many times
.octomaton.yaml, .tekton/ci.yaml   CI for this repository (run by Octomaton on Tekton)
```

## How it syncs

Terraform (`infra`, `terraform/argocd`) installs Argo CD and one Application, `root`, which syncs `apps/` from `main`.
Each file there is an Application in namespace `argocd`, project `default`:

- A chart-based component has three sources: the pinned chart (with `helm.releaseName` and
  `valueFiles: [$values/platform/<component>/values.yaml]`), this repository as `ref: values`, and
  `platform/<component>/manifests` when it has extra manifests. A manifest-only component has one source, that path.
- `octomaton` is the exception: its manifests live with its code, in `deploy/` of `arikkfir-org/octomaton`. Its
  Application follows that repository's `main` and sets the image tag to `${ARGOCD_APP_REVISION_SHORT}`, the short SHA
  of the synced commit, which Octomaton's `release` publishes on every push. A merge there deploys itself.
- `fin` deploys Fin's environments the same way
  ([design](https://github.com/arikkfir-org/fin/blob/main/docs/fin/designs/environments.md)): production from
  `arikkfir-org/fin`'s `main`, and a preview of every open pull request from its head commit, through two
  ApplicationSets. Each environment is two Applications in namespace `fin-<environment>`: Fin's own chart
  (`deploy/chart` there), in AppProject `fin` or `fin-previews`, which allow only the workloads' kinds, and the edge
  (`platform/fin/edge`, from `main` here), which holds the namespace, its quota, the certificate, Gateway and routes,
  and the database's passwords. Argo CD reads `fin`, an internal repository, and lists its pull requests with its own
  GitHub App (Secret `argocd/github-app`).
- Every Application syncs automatically with prune and self-heal, retries with backoff (`refresh: true`, so a retry
  picks up a newer commit), and creates its namespace. Namespace labels come from `managedNamespaceMetadata`
  (for example `kfirs.com/public-ingress: "true"` on `auth`, `octomaton`, `docs` and `keycloak`). `ServerSideApply=true` is set where CRDs
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
| 4 | `auth`, `grafana`, `nack`, `nui`, `tekton`, `octomaton`, `docs`, `ci-tenants`, `keycloak`, `fin` |

Within an Application, waves order dependent resources as well: ClusterIssuers and the ClusterSecretStore wait for their
operators' webhooks; in `traefik` the Certificates (the wildcard and `octomaton-dev`) are issued before the Gateways
that reference their Secrets.

Secrets never live in Git: each one is an `ExternalSecret` reading Secret Manager through the `ClusterSecretStore`
`gcp-secret-manager`. A credential only the cluster uses is generated instead, by an ESO `Password` generator with
`refreshPolicy: CreatedOnce` (Grafana's database password). Every UI is served on the `protected` gateway, behind the
oauth2-proxy interceptor; only `auth.kfirs.com/oauth2`, `octomaton.dev` (Octomaton's webhook and Go import page),
`legal.kfirs.com` (the docs site's privacy policy and terms of service, exact paths only) and `id.kfirs.com` (Keycloak's
realm `hub`, and realm `master` behind the interceptor) use the `public` gateway. Fin's environments, whose host names
need certificates of their own, each have a Gateway on the protected gateway's entry point, behind the same interceptor.

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
helm template fin-edge platform/fin/edge -n fin-pr-1 --set environment=pr-1 \
  --set hosts.app=app.pr-1.fin.dev.kfirs.com,hosts.api=api.pr-1.fin.dev.kfirs.com >/dev/null   # charts of this repo
```

CI (`.tekton/ci.yaml`) runs yamllint, renders every kustomization and this repository's charts, and validates `apps/`
and the rendered manifests with kubeconform against the [CRDs-catalog](https://github.com/datreeio/CRDs-catalog)
schemas.
