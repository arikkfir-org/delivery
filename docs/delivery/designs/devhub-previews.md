# DevHub's previews

**Decision**: every open pull request that a member of [arikkfir-org/devhub](https://github.com/arikkfir-org/devhub) opens gets a DevHub of its own, a preview, and no fork's pull request does: namespace `devhub-pr-<number>`, at `https://pr-<number>.devhub.dev.kfirs.com`, behind the hub's sign-in and Middleware `admins`, as the [demo](devhub.md) is. Argo CD installs DevHub's chart from the pull request's head commit, with that commit's images and its demo data (`seed.enabled`), on node pool `ci`; closing or merging the pull request deletes it, database and all. A pull request's code decides what runs in its namespace, so an AppProject admits only the kinds a preview needs and admission policies hold what each may say. Linear: [ENG-208](https://linear.app/arikkfir/issue/ENG-208). DevHub's side, the seeds and the preview pipeline, is the [Helm chart design](https://claude.ai/artifact/LyMHXgSoNQNgHtHNfEjvA8#previews)'s.

## Why

A reviewer of a DevHub pull request had to build both images and install the chart to try it. A preview shows the change within minutes of a push, seeded, with nothing to register or set up. Fin's pull requests have had this since its [environments](../../fin/designs/environments.md); DevHub's follow the same shape, with the differences below.

## Design

```mermaid
flowchart LR
  subgraph devhubrepo["arikkfir-org/devhub, a pull request"]
    Chart["chart/devhub at the head commit"]
    Preview["pipeline preview: devhub and devhub-console,<br/>tagged with the commit's short SHA"]
  end
  subgraph delivery["delivery"]
    Set["ApplicationSet devhub-pull-requests<br/>(platform/devhub/manifests)"]
    Extras["platform/devhub/pull-request: Namespace, quota,<br/>password, HTTPRoute, Middleware admins, NetworkPolicy"]
    Project["AppProject devhub-pull-requests<br/>and policies devhub-*"]
    GW["Gateway and Certificate<br/>traefik/devhub-pull-requests"]
  end
  Preview -- "pushes as ci-devhub-preview" --> Reg[("Artifact Registry<br/>devhub-previews")]
  Set -- "an Application per pull request" --> App["Application devhub-pr-&lt;number&gt;"]
  App -- "source 1: Helm values" --> Chart
  App -- "source 2: kustomize" --> Extras
  App --> NS["namespace devhub-pr-&lt;number&gt; on pool ci:<br/>Console, servers, migrate Job and seeds, PostgreSQL"]
  Reg -- "pulled by the nodes" --> NS
  Project -. "admits and holds" .-> NS
  GW --> NS
```

What `infra` provides, repository `devhub-previews`, `ci-devhub-preview`'s grant on it and the record `*.devhub.dev`, is documented in its pages: [Artifact Registry](../../infra/terraform/gcp.md#artifact-registry), [IAM](../../infra/terraform/gcp.md#iam) and [DNS](../../infra/terraform/gcp.md#dns).

### A push to a pull request

```mermaid
sequenceDiagram
  autonumber
  participant Dev as Author
  participant GH as GitHub
  participant P as devhub pipeline preview
  participant AS as ApplicationSet devhub-pull-requests
  participant A as Application devhub-pr-n
  participant K as namespace devhub-pr-n
  Dev->>GH: push to a branch with an open pull request
  GH->>P: pull_request synchronize (Octomaton)
  P->>P: build both images, push :sha7 to devhub-previews
  AS->>GH: list open pull requests, keep those members opened (every minute, Argo CD's GitHub App)
  AS->>A: head SHA changed: new revision and tag
  A->>K: wave -1: Namespace, quota, password, Middleware
  A->>K: wave 0: PostgreSQL
  A->>K: wave 1: migrate Job (waits for its image): schema, then seeds
  A->>K: wave 2: servers and Console, ready once the schema is theirs
  Dev->>K: https://pr-n.devhub.dev.kfirs.com (sign-in, admins)
```

A sync can start before pipeline `preview` has pushed the commit's images: the migrate Job waits for its image within `migrate.activeDeadlineSeconds` (1800 seconds), and the servers and the Console wait for the Job. The seeds keep a version table of their own, so a preview upgraded in place runs only the new ones.

### When the pull request closes

```mermaid
stateDiagram-v2
  [*] --> Open: a member opens a pull request
  Open --> Open: push: new head, new images, sync
  Open --> Gone: closed or merged
  Gone --> [*]: resources finalizer deletes everything, namespace, volume and database included
```

The generator stops listing a closed pull request, the ApplicationSet deletes its Application, and the resources finalizer deletes what it made, the Namespace with it. A reopened pull request starts again from an empty database.

### What holds a preview

```mermaid
flowchart TB
  subgraph code["What a pull request's chart may render"]
    K1["Deployments, StatefulSet, Job, Services,<br/>ServiceAccount, budgets, NetworkPolicy"]
  end
  subgraph hub["What delivery adds"]
    K2["Namespace, ResourceQuota, Password and ExternalSecret,<br/>HTTPRoute, Middleware admins, NetworkPolicy"]
  end
  code --> Proj{"AppProject devhub-pull-requests:<br/>those kinds, namespaces devhub-pr-* only"}
  hub --> Proj
  Proj --> Pol{"Admission policies, matched by namespace name"}
  Pol --> P1["devhub-namespaces: restricted, labelled<br/>kfirs.com/devhub-pull-request only"]
  Pol --> P2["devhub-http-routes: own host, own Gateway,<br/>admins first, then Cookie removed"]
  Pol --> P3["devhub-middlewares: the admins ForwardAuth only"]
  Pol --> P4["devhub-external-secrets: generators only"]
  Pol --> P5["devhub-cluster-ip-services"]
  Pol --> P6["devhub-node-pool: tolerates ci only, no nodeName"]
  Pol --> P7["devhub-disruption-budgets: never block a drain"]
```

| Holds | How |
| --- | --- |
| No cloud role | No grant in `infra` names a `devhub-pr-*` namespace, and no Workload Identity pool trusts one. The bucket is a `file://` directory on each server's emptyDir |
| No Secret but its own | AppProject admits no Secret; the database's password comes from a Password generator; ClusterSecretStore `gcp-secret-manager` refuses namespaces labelled `kfirs.com/devhub-pull-request`, and policy `devhub-external-secrets` admits only generators |
| No reach beyond its host | Services are ClusterIP; routes attach only to `traefik/devhub-pull-requests`, with the namespace's own host; NetworkPolicy `devhub` admits only Traefik to the servers and the Console, the chart's own only the servers and the Job to PostgreSQL |
| No hub session | Every rule asks Middleware `admins` first, which reads the hub's session cookie, then removes `Cookie`, then may only rewrite the URL: browsers send that cookie (domain `.kfirs.com`) to previews too, and Traefik runs filters in order, so a redirect or mirror before `admins` would answer any hub user |
| No room beyond its share | ResourceQuota `devhub`: 2 CPUs and 4Gi requested, 8Gi of memory limits, 10 pods, one 2Gi volume |
| No other pool | Policy `devhub-node-pool`: pods tolerate only `kfirs.com/pool=ci` and name no node; budgets let every pod go, so a preview never keeps a CI node up |

## Decisions

| Decision | Why | Rejected |
| --- | --- | --- |
| Node pool `ci` | devhub's pull requests' code already runs there, in CI; it scales from zero and costs nothing new (owner, 2026-10-30) | `system`, beside Argo CD, Traefik and Keycloak; `fin`, Fin's own; a fourth pool to pay for |
| Repository `devhub-previews` and ServiceAccount `ci-devhub-preview`, from any branch | `devhub` is public and its pull requests' CI runs Dependabot's code: it must not be able to replace Fin's preview images in `previews`, nor `devhub`'s `main` and release tags | `previews`, shared with Fin; `ci-devhub-release`, `main` and `v*` only |
| Host `pr-<number>.devhub.dev.kfirs.com`, beside the demo | DevHub's hosts on the hub are temporary: its own installation will have a domain of its own. Previews remove every cookie, so none the demo sets reaches a pull request's code (owner, 2026-10-30) | `pr-<number>.devhub-previews.dev.kfirs.com`, off the demo's domain |
| Label `kfirs.com/devhub-pull-request` | Fin's `kfirs.com/pull-request` also admits a namespace to NATS, which takes no credentials, and to Fin's Gateway | Reusing Fin's label |
| The route, Middleware, quota and password from delivery, as a second source | A pull request's code then decides no host, Gateway or gate; the chart stays the product, with nothing of the hub in it | The chart's own HTTPRoute (`httpRoute.enabled`) |
| Pull requests that `devhub`'s members open: its owner, whose sessions open them as the owner, and Dependabot | `devhub` is public: GitHub lists forks' pull requests among `devhub`'s and serves their head commits from `devhub`, and Argo CD's generator drops the repository a pull request comes from, so a fork's chart could run anything on pool `ci`. Its post-selector on the author keeps every member's pull request automatic and every stranger's out; a new collaborator is added to it (owner, 2026-10-30) | A label `preview` that members add by hand; matching `devhub`'s branch list, which still previews a fork named like a `devhub` branch at its commit |
| Pull requests only, no merge queue entries | A preview is for a reviewer; DevHub's CI tests the chart on kind for every merge group | Fin's per-entry environments, which its end-to-end suite needs |

## Security and failure modes

- A preview runs a pull request's code on pool `ci`, beside other repositories' CI runs, as devhub's CI already does there. Only a pull request that `devhub`'s owner or Dependabot opens gets one: a fork's pull request runs nothing here, as Octomaton runs nothing for it in CI. A collaborator who isn't in the ApplicationSet's list gets no previews until added.
- A pull request whose chart predates devhub's `seed.enabled` value fails to render: the chart's values schema refuses unknown keys. Rebasing it on `main` fixes it; until then its Application shows the error and runs nothing.
- Removing `Cookie` removes every cookie: once DevHub signs people in itself ([ENG-197](https://linear.app/arikkfir/issue/ENG-197)), its own session cookie needs another way through, and this design changes with it. Previews share the demo's domain, and a preview can set a cookie for `devhub.dev.kfirs.com` that the demo receives, so the demo's session cookie then takes the `__Host-` prefix, which no preview can set.
- A commit whose migrate Job fails keeps failing on every retry (the Job is named by a hash of its spec); the next push recovers.
- Argo CD's GitHub App lists the pull requests: the owner installs it on `devhub` as well as `fin`. Without it the ApplicationSet lists nothing and no preview appears.

## Rollout

1. `infra`: repository `devhub-previews`, its grants and the record `*.devhub.dev`, applied on merge.
2. `delivery`: this design, ServiceAccount `ci-devhub-preview`, the secret store's condition, the Gateway and Certificate, AppProject, policies and ApplicationSet. The owner adds `devhub` to Argo CD's GitHub App installation.
3. `devhub`: `db/seeds/`, `seed.enabled` and pipeline `preview`. Its own pull request is the first preview that renders; the others open before it fail to render until rebased on it.
