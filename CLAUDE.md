# delivery

Argo CD GitOps repository for the hub cluster. See README.md for layout, sync waves and conventions.

## Rules

- Git is the source of truth. Never `kubectl apply`, `edit`, `patch`, `delete` or `helm install` against the cluster;
  change files here and let Argo CD sync `main`. Read-only `kubectl get`/`describe`/`logs` is fine.
- `docs/hub/reference.md` (arikkfir-org/docs) is the contract. Names, namespaces, hosts, versions and identities must
  match it; if one has to change, change the reference first.
- Pin everything: chart `targetRevision`, image tags, remote manifest URLs. Never `latest`, never a floating branch.
  The exceptions run the image of the commit they sync: Application `octomaton` (`platform/octomaton/manifests`)
  follows `main` of `arikkfir-org/octomaton` (its `deploy/`), and Fin's environments (`platform/fin/manifests`) follow `main` of
  `arikkfir-org/fin` (production), each pull request's head commit (its own environment) and each merge queue entry's
  merge group commit (its own).
- Fin's `deploy/` comes from pull requests and holds its own Namespace, Gateway, routes, certificate, ExternalSecrets,
  NATS resources, autoscaling and ID-token Middleware; a pull request's deployment drops the Gateway and certificate, and
  its routes attach to the shared `traefik/fin-pull-requests`, whose one wildcard certificate covers every pull request.
  Overrides go in the `kustomize` options of Application `fin` and ApplicationSet `fin-pull-requests`, and the template
  uses only the environment and commit its generators name, from a pull request's number and head SHA or a merge queue
  entry's branch (`gh-readonly-queue/main/pr-<number>-<SHA>`) and SHA, from which it names the environment
  `pr-<number>-merge`; what differs inside a pull request's environment and grants nothing
  is fin's `components/pull-request`. Admit a new kind to AppProjects `fin` and `fin-pull-requests` only with an
  admission policy that holds what it may say, as `platform/fin/manifests` does for namespaces, Services, Gateways,
  routes, certificates, ExternalSecrets, NACK's resources, KEDA's kinds and Middlewares (Gateways and certificates in
  `fin` only); never RBAC, ServiceAccounts (production's come from Application `fin-identities`), Secrets, secret
  stores or other generators, Issuers, ReferenceGrants or ClusterTriggerAuthentications. A pull request's namespace
  must keep its `kfirs.com/pull-request` label: it keeps `gcp-secret-manager` out of its reach, and lets the namespace
  reach NATS. NATS takes no credentials, so NetworkPolicy `nats/nats` admits only namespace `nats` and Fin's
  namespaces; a new client's namespace goes there first.
- Octomaton's `deploy/` comes from its `main` only and holds its own Namespace and RBAC. Overrides (the image tag, the
  namespace's `kfirs.com/public-ingress` label) go in the `kustomize` options of Application `octomaton`. AppProject
  `octomaton` admits a kind, or a cluster-scoped object by name, only once Octomaton's `deploy/` needs it; merge that
  here before Octomaton's change.
- Secrets never go in Git: use an `ExternalSecret` on `ClusterSecretStore` `gcp-secret-manager`, or, for a credential
  only the cluster uses, on an ESO generator (a `Password` with `refreshPolicy: CreatedOnce`).
- Services others depend on (ingress, sign-in, sites, Octomaton, NATS, KEDA) run at least two replicas, spread over
  nodes with `whenUnsatisfiable: ScheduleAnyway`, and a PodDisruptionBudget with `maxUnavailable: 1`. Never give a
  single replica a PodDisruptionBudget: it either blocks node drains or protects nothing.
- New UIs go on the `protected` gateway, with a NetworkPolicy admitting only the `traefik` namespace to their pods,
  and Middleware `admins` on their route: every hub user, Fin's test users included, passes the sign-in alone
  (`docs/delivery/designs/admins-only.md`). Select only those pods: namespaces with admission webhooks or aggregated
  APIs must never get a default-deny policy.
- CI tenants: never give Tekton's default ServiceAccount `pipeline` a GCP role; any branch's run can use it. A pipeline
  that needs one gets its own ServiceAccount in `platform/ci-tenants/manifests/tenants/<repository>/`
  (`automountServiceAccountToken: false`), annotated `octomaton.dev/branches: main` when it publishes or applies.
- `public` gateway routes need the namespace label `kfirs.com/public-ingress: "true"` and a deliberate reason.
- Keep the Application conventions: multi-source for charts, sync waves by dependency, `automated` prune + self-heal,
  retry, `CreateNamespace=true`, `ServerSideApply=true` for large CRDs (plus the compare option `ServerSideDiff=true`
  when the Application also holds resources whose atomic lists get defaults, such as HTTPRoutes),
  `SkipDryRunOnMissingResource=true` for CRs whose CRDs come from another Application. No resources finalizer on
  `argocd` (or any CRD owner).
- `TektonConfig`: check field names against the operator's Go types (`tektoncd/operator/pkg/apis/operator/v1alpha1`)
  for the pinned version, and validate it against the CRD schema in the operator's release manifest (CI cannot: the
  CRDs catalog has no schema for it).
- Verify every chart value key against the chart's `values.yaml`/`values.schema.json` for the pinned version.

## Validate before committing

```bash
yamllint --strict .
for k in $(find platform -name kustomization.yaml); do kubectl kustomize "$(dirname "$k")" >/dev/null || echo "FAIL $k"; done
helm template <release> <chart> --repo <repo> --version <version> -n <namespace> -f platform/<component>/values.yaml
kubeconform -strict -summary -ignore-missing-schemas -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  apps <rendered kustomize output>
```
