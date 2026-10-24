# delivery

Argo CD GitOps repository for the hub cluster. See README.md for layout, sync waves and conventions.

## Rules

- Git is the source of truth. Never `kubectl apply`, `edit`, `patch`, `delete` or `helm install` against the cluster;
  change files here and let Argo CD sync `main`. Read-only `kubectl get`/`describe`/`logs` is fine.
- A name, address, identity or permission is documented by the repository that creates it, in its pages under
  `docs/<repository>/`; a repository that uses one links that page rather than repeat it. This repository creates what
  runs in the cluster (namespaces, ServiceAccounts, hosts' routes, versions): document it in `docs/delivery/platform.md`
  and its designs, in the same pull request. GCP names come from `infra`'s pages, and Octomaton's and Fin's deployments
  from their own. A change to a value starts in the repository that creates it, and those that use it follow in the
  same unit of work. If a change needs a new or different value from another repository, say so; do not diverge
  silently.
- Pin everything: chart `targetRevision`, image tags, remote manifest URLs. Never `latest`, never a floating branch.
  The exceptions run the image of the commit they sync: Applications `octomaton` and `octomaton-logs`
  (`platform/octomaton/manifests`) follow `main` of `arikkfir-org/octomaton` (its `deploy/` and `deploy/logs/`), and
  Fin's environments (`platform/fin/manifests`) follow `main` of
  `arikkfir-org/fin` (production), each pull request's head commit (its own environment) and each merge queue entry's
  merge group commit (its own).
- Fin's `deploy/` comes from pull requests and holds its own Namespace, Gateway, routes, certificate, ExternalSecrets,
  NATS resources, autoscaling, ID-token Middleware, and the Role and RoleBinding that let its workloads read Job
  migrate; a pull request's deployment drops the Gateway and certificate, and
  its routes attach to the shared `traefik/fin-pull-requests`, whose one wildcard certificate covers every pull request.
  Overrides go in the `kustomize` options of Application `fin` and ApplicationSet `fin-pull-requests`, and the template
  uses only the environment and commit its generators name, from a pull request's number and head SHA or a merge queue
  entry's branch (`gh-readonly-queue/main/pr-<number>-<SHA>`) and SHA, from which it names the environment
  `pr-<number>-merge`; what differs inside a pull request's environment and grants nothing
  is fin's `components/pull-request`. Admit a new kind to AppProjects `fin` and `fin-pull-requests` only with an
  admission policy that holds what it may say, as `platform/fin/manifests` does for namespaces, Services, Gateways,
  routes, certificates, ExternalSecrets, NACK's resources, KEDA's kinds, Middlewares, and Roles and RoleBindings
  (Gateways and certificates in `fin` only; policies `fin-roles` and `fin-role-bindings` hold Roles to reading Jobs and
  RoleBindings to the namespace's own Roles and ServiceAccounts); never ServiceAccounts (production's come from
  Application `fin-identities`), cluster-wide RBAC, Secrets, secret stores or other generators, Issuers, ReferenceGrants
  or ClusterTriggerAuthentications. A pull request's namespace must keep its `kfirs.com/pull-request` label: it keeps
  `gcp-secret-manager` out of its reach, and lets the namespace
  reach NATS. NATS takes no credentials, so NetworkPolicy `nats/nats` admits only namespace `nats` and Fin's
  namespaces; a new client's namespace goes there first.
- Octomaton's `deploy/` and `deploy/logs/` come from its `main` only; `deploy/` holds its own Namespace and RBAC.
  Overrides (the images' tag, the namespace's `kfirs.com/public-ingress` label, the node pool) go in the `kustomize`
  options of Application `octomaton` for `deploy/` and of Application `octomaton-logs` for `deploy/logs/`. AppProject
  `octomaton` admits a kind, or a cluster-scoped object by name, only once Octomaton's `deploy/` or `deploy/logs/` needs
  it; merge that here before Octomaton's change.
- Every hub service's pods select node pool `system` (`kfirs.com/pool: system`) and tolerate its taint,
  `components.gke.io/gke-managed-components=true:NoSchedule`, GKE's own for its managed components: a new component's
  too, or it waits for a node (`docs/delivery/designs/node-pools.md`). TaskRun pods go to `ci` through Tekton's default
  pod template, Fin's to `fin` through its `deploy/`, and policy `fin-node-pool` refuses a Fin pod that tolerates any
  other taint or names its node.
- Every hub container requests the CPU and memory it uses and limits its memory above its peak, with no CPU limit
  (`docs/delivery/designs/resource-requests.md`): a pod without requests is the first evicted.
- Secrets never go in Git: use an `ExternalSecret` on `ClusterSecretStore` `gcp-secret-manager`, or, for a credential
  only the cluster uses, on an ESO generator (a `Password` with `refreshPolicy: CreatedOnce`).
- Every hub service's Deployments and StatefulSets, single replicas included, have a PodDisruptionBudget with
  `maxUnavailable: 1` (never `minAvailable`, which blocks drains of a single replica), selecting exactly its workload's
  pods: an eviction refuses a pod under two budgets. A workload that can run one replica gets
  `unhealthyPodEvictionPolicy: AlwaysAllow` too: by default its budget refuses to evict an unready pod, holding the
  drain. Every Deployment rolls out by surging (`maxSurge: 1`,
  `maxUnavailable: 0`), so the new pod is ready before the old one stops (`docs/delivery/designs/disruption-budgets.md`).
- Services others depend on (ingress, sign-in, sites, Octomaton, NATS, KEDA) run at least two replicas, spread over
  nodes with `whenUnsatisfiable: ScheduleAnyway`: a drain still evicts a single replica.
- New UIs go on the `protected` gateway, with a NetworkPolicy admitting only the `traefik` namespace to their pods,
  and Middleware `admins` on their route: every hub user, Fin's test users included, passes the sign-in alone
  (`docs/delivery/designs/admins-only.md`). Select only those pods: namespaces with admission webhooks or aggregated
  APIs must never get a default-deny policy.
- CI tenants: never give Tekton's default ServiceAccount `pipeline` a GCP role; any branch's run can use it. A pipeline
  that needs one gets its own ServiceAccount in `platform/ci-tenants/manifests/tenants/<repository>/`
  (`automountServiceAccountToken: false`), annotated `octomaton.dev/branches: main` when it publishes or applies.
- Tekton files stay short and composed (https://docs.dev.kfirs.com/CONTRIBUTING.md, "Continuous integration"): a
  PipelineRun references its Pipeline or Tasks by name, each in a file beside it (`<name>.pipeline.yaml`,
  `<name>.task.yaml`), steps that Tasks share are StepActions (`<name>.step.yaml`), and a step names its command or
  runs a script file of this repository rather than an inline script of more than a few lines. A change to a long,
  inlined file splits what it touches.
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
- Large tasks run as Linear projects (https://docs.dev.kfirs.com/CONTRIBUTING.md, "Projects"): suggest one to your
  person and create it once they agree; one issue per slice, however many pull requests it takes; slices preferably
  self-contained and deployable on their own; keep the project's status current, with an update at each milestone or
  significant change.

## Docs

- This repository's pages are in `docs/delivery/`: `platform.md`, what runs in the cluster (components and versions,
  NATS, ingress and hosts, CI tenants, labels), and the designs under `designs/`. A change keeps those it touches true,
  in the same pull request. What `infra` provisions (the cluster, its node pools, buckets, grants, DNS) is described in
  its pages under `https://docs.dev.kfirs.com/infra/terraform/`: list what a change relies on and link them, rather
  than repeat them.
- Pages at `https://docs.dev.kfirs.com/<path>` (every repository's `docs/`) are behind the hub's sign-in. Read one with
  `curl -fsS https://storage.googleapis.com/arikkfir-docs/.layers/<repository>/<path>`, where `<repository>` is the
  path's first segment when it names a repository (`fin/designs/environments.md` is `fin`'s) and `docs` otherwise
  (`CONTRIBUTING.md`). Don't clone a repository to read its docs.

## Validate before committing

```bash
yamllint --strict .
for k in $(find platform -name kustomization.yaml); do kubectl kustomize "$(dirname "$k")" >/dev/null || echo "FAIL $k"; done
helm template <release> <chart> --repo <repo> --version <version> -n <namespace> -f platform/<component>/values.yaml
kubeconform -strict -summary -ignore-missing-schemas -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  apps <rendered kustomize output>
```
