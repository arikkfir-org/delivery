# Cobranch's website, delivered by Cobranch

**Decision**: Cobranch's website is repository `website` of organization `cobranch` on `cobranch.app`, and Cobranch's own delivery deploys it to the hub: target `production` of its `main` applies, through a kubeconfig the organization keeps as a secret, into namespace `cobranch-website`, as ServiceAccount `cobranch-delivery`, which may change only the kinds the website needs, there alone. This repository makes the namespace and the account; Cobranch delivers everything that runs in it. Linear: [ENG-270](https://linear.app/arikkfir/issue/ENG-270), dogfooding Cobranch with its own website.

## Why

The owner wants Cobranch to build and ship Cobranch's own things, starting with its website, so its delivery is used as a real organization uses it (owner, 2026-11-25). `cobranch.app` doesn't deliver into its own cluster: `delivery.inCluster.enabled` is off, since it would let every organization make namespaces in the hub. The owner chose instead a namespace for organization `cobranch` alone (decision card, 2026-11-27), which Cobranch reaches as it reaches any other cluster: through a kubeconfig ([Cobranch's delivery, other clusters](../../cobranch/designs/delivery.md#other-clusters)).

## Design

```mermaid
flowchart LR
  subgraph app["namespace cobranch-app"]
    CTRL["Cobranch's controller"]
  end
  subgraph cb["cobranch.app, organization cobranch"]
    REPO["repository website<br/>/cobranch.yaml: target production, branch main"]
    SEC[("organization secret<br/>the kubeconfig")]
  end
  REPO -->|"a push to main queues a delivery"| CTRL
  SEC -.->|"opened for target production"| CTRL
  CTRL -->|"https://kubernetes.default.svc (10.30.0.1)<br/>as cobranch-website/cobranch-delivery"| API["hub's API server"]
  API --> NS
  subgraph NS["namespace cobranch-website (Argo CD: cobranch-website)"]
    SA["ServiceAccount cobranch-delivery<br/>Secret cobranch-delivery-token"]
    OBJ["what the website delivers:<br/>Deployment, Service, ConfigMaps,<br/>PodDisruptionBudget, NetworkPolicy, HTTPRoute"]
  end
  WEB(("https://cobranch.dev")) -->|"Gateway traefik/public,<br/>listener cobranch-dev"| OBJ
```

| Piece | Value |
| --- | --- |
| Application | `cobranch-website`, `platform/cobranch-website/manifests`, project `default` |
| Namespace | `cobranch-website`, labelled `pod-security.kubernetes.io/enforce: restricted` and `kfirs.com/public-ingress: "true"` by the Application: the website is `cobranch.dev` |
| ServiceAccount | `cobranch-delivery`, no token mounted anywhere; its token in Secret `cobranch-delivery-token`, which Kubernetes fills and keeps until the Secret is deleted |
| Role `cobranch-delivery` | Every verb on ConfigMaps, Services, Deployments, PodDisruptionBudgets, NetworkPolicies and HTTPRoutes, in `cobranch-website` |
| Policy `cobranch-website-cluster-ip-services` | Every Service in `cobranch-website` is of type `ClusterIP`, with no external IPs |
| Policy `cobranch-website-http-routes` | Every HTTPRoute in `cobranch-website` attaches to listener `cobranch-dev` of Gateway `traefik/public` alone |
| Listener `cobranch-dev` of `traefik/public` | `cobranch.dev`, from namespace `cobranch-website` alone, while it carries `kfirs.com/public-ingress: "true"`: the website's route `website`, which sends everything to Service `website` |
| ClusterRole `cobranch-website-namespace` | `get` on namespace `cobranch-website` alone: Cobranch reads an environment's namespace first, uses one that exists, and tries to make one it may not read |
| `cobranch.app`'s `delivery.clusters.allowedCIDRs` | `10.30.0.1/32`, Service `default/kubernetes`: the one private address a target's kubeconfig may name. The controller refuses every other address in `jobs.egress.except` |

The website's own repository holds what runs here, rendered by Cobranch from its `main`: the Caddy that serves its pages, two replicas on node pool `system` ([node pools](node-pools.md)), with a PodDisruptionBudget ([disruption budgets](disruption-budgets.md)), requests ([resource requests](resource-requests.md)) and a NetworkPolicy that admits only Traefik.

### The kubeconfig

The owner builds it once, from the token Secret, and adds it as an organization secret in the Console (organization `cobranch`, Settings, Secrets); the website's `/cobranch.yaml` names that secret's ID as target `production`'s `cluster`, and the target's principal gets the Secret reader role on it. Cobranch accepts only an `https` server, the CA inline and a token inline:

```sh
ns=cobranch-website
kubectl -n "$ns" get secret cobranch-delivery-token -o json | jq -r --arg ns "$ns" '
  "apiVersion: v1\nkind: Config\nclusters:\n- name: hub\n  cluster:\n    server: https://kubernetes.default.svc.cluster.local\n    certificate-authority-data: \(.data["ca.crt"])\nusers:\n- name: cobranch-delivery\n  user:\n    token: \(.data.token | @base64d)\ncontexts:\n- name: hub\n  context:\n    cluster: hub\n    user: cobranch-delivery\n    namespace: \($ns)\ncurrent-context: hub"'
```

## Decisions

| Decision | Why | Rejected |
| --- | --- | --- |
| A namespace and an account for organization `cobranch` alone | Dogfoods delivery now, without opening the hub to every organization of `cobranch.app` (owner, 2026-11-27) | `delivery.inCluster.enabled` on `cobranch.app`: every organization could make namespaces in the hub |
| Reach the API server at its in-cluster address | The controller runs in the hub, so its calls stay inside the cluster; the control plane's only other endpoint is GKE's DNS-based one, which the hub reaches with Google credentials ([the cluster](../../infra/terraform/gcp.md)) | The DNS-based endpoint, whose Google credentials need an exec plugin, which Cobranch refuses, or a key, which the hub never issues |
| Admit `10.30.0.1/32` alone | Any organization's kubeconfig may name the address, but reaches nothing without a token the API server takes; every other private address stays refused | Admitting `10.30.0.0/20`, every Service of the hub |
| A token Secret, not a short-lived token | Cobranch keeps a kubeconfig as a secret and never refreshes it; deleting the Secret revokes it | `kubectl create token`, which expires within a day by default |
| Admission policies on the Services and HTTPRoutes it delivers | What the website's `main` delivers isn't reviewed here, and the Role may change those kinds; as for [cobranch.app](cobranch-app.md), the policies hold them inside the cluster | Leaving HTTPRoutes out of the Role until the cutover: the cutover would then change the Role too, and Services would still need a policy |
| The namespace from Argo CD, read-only to Cobranch | Cobranch uses a namespace that exists and never deletes one it didn't make, so a teardown leaves the account in place | Letting Cobranch make it: the account would need to make namespaces, cluster-wide |

## Security and failure modes

- **The account's reach** is the Role's kinds in one namespace: it can't read Secrets, make pods directly, bind roles or touch another namespace. Pod Security `restricted` holds whatever its Deployments run.
- **A leaked kubeconfig** gives that much and no more, under the same policies. Revoke it by deleting Secret `cobranch-delivery-token` (Argo CD makes it again, with a new token), then replace the organization's secret.
- **Public exposure** is `cobranch.dev` alone. Policy `cobranch-website-http-routes` holds every HTTPRoute to listener `cobranch-dev` of `traefik/public`, never `traefik/protected`, whose listener takes routes from every namespace for any `*.kfirs.com` host, nor another listener of `public`: `public-websecure` admits routes for `*.kfirs.com` from every namespace labelled `kfirs.com/public-ingress`, this one included, so the policy, not the label, is what keeps the website off it. So the website's `main` decides what `cobranch.dev` serves, and nothing else: whoever may push to it may change Cobranch's public face, which is why its branch rules and reviews matter. Policy `cobranch-website-cluster-ip-services` refuses a Service of another type or with external IPs, which would face beyond the cluster without any Gateway.
- **Cobranch's delivery fails** (a render error, the API server unreachable): the environment shows it, and what runs stays as it was.

## Rollout

1. Merge this: Argo CD makes the policies, the namespace and the account, and `cobranch.app` admits the address.
2. The owner builds the kubeconfig (above) and adds it as an organization secret of `cobranch`.
3. The website's `/cobranch.yaml` names target `production`; its principal gets Secret reader on that secret; its first push to `main` delivers.
4. The cutover (owner, 2026-11-27), once the website serves the Go import page too and delivers its route `website` for `cobranch.dev`: listener `cobranch-dev` admits `cobranch-website` instead of `cobranch-site`, the namespace gets `kfirs.com/public-ingress`, and Application `cobranch-site` gets the resources finalizer. Rolling it back is reverting it: `cobranch-site` still runs, and its route attaches again.
5. Then, in a pull request of its own, `cobranch-site` goes: removing its Application deletes what it made, and its namespace goes by hand.

Rolling back: reverting this deletes Application `cobranch-website` but not what it made, since Application `cobranch-website` carries no resources finalizer, so the token still authenticates. Revoke it by deleting Secret `cobranch-website/cobranch-delivery-token`, or the whole namespace, after the revert; the cluster-scoped ClusterRole, ClusterRoleBinding and policies go by hand too.

## Open questions

- Previews of the website's branches would need a namespace each; this design gives `main` one.
