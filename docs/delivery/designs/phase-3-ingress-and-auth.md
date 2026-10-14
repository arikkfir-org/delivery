# Phase 3: Ingress and authentication

**Superseded for sign-in** by [Keycloak](../../hub/designs/keycloak.md): since 2 October 2026, Keycloak's realm `hub` signs everyone in,
and Descope is retired. The ingress design and the interceptor below still hold; read the Descope parts as history.

**Goal**: expose cluster applications through Traefik on L4 (passthrough network) load balancers, and make OpenID
authentication of a closed set of users the default for everything, so an internal application can't be exposed
unauthenticated by forgetting a setting. Hosts, IPs and names: [reference](../../hub/reference.md#ingress).

## Design

```mermaid
flowchart LR
  U((Browser)) -- "argocd, tekton, grafana, traefik,<br/>nui, docs .dev.kfirs.com" --> P[L4 LB<br/>ingress-protected]
  G((GitHub)) -- octomaton.dev/github/hooks --> Q[L4 LB<br/>ingress-public]
  U -- auth.kfirs.com/oauth2 --> Q
  subgraph traefik[Traefik]
    WS[entry point websecure<br/>middlewares: strip-auth-headers, oidc]
    PW[entry point public-websecure<br/>middleware: strip-auth-headers]
  end
  P --> WS
  Q --> PW
  WS -- ForwardAuth --> O[oauth2-proxy<br/>auth namespace]
  WS --> APPS[Argo CD, Tekton Dashboard,<br/>Grafana, Traefik dashboard, NUI]
  PW --> O
  PW --> SB[Octomaton webhook]
  O -- OIDC --> D[Descope]
  D -- social login --> GO[Google]
```

One Traefik deployment serves two Gateways, each on its own entry points and its own load balancer IP:

| Gateway | Entry point | Load balancer | Interceptor | Routes allowed from |
| --- | --- | --- | --- | --- |
| `protected` | `websecure` (8443 → 443) | `ingress-protected` | every request authenticated | any namespace |
| `public` | `public-websecure` (9443 → 443) | `ingress-public` | none | namespaces labelled `kfirs.com/public-ingress=true` |

The interceptor is attached to the **entry point**, not to routes: every route on the protected gateway is
authenticated, including routes added later, and there is no per-route switch to forget. Going public requires two
deliberate acts in `delivery`: labelling the namespace and attaching to the `public` gateway. Only `auth` (the login
callback) and `octomaton` (HMAC-verified webhooks) are public.

Both gateways terminate TLS with a wildcard certificate for `*.kfirs.com` and `*.dev.kfirs.com` (cert-manager, Let's
Encrypt, DNS-01), and redirect HTTP to HTTPS.

## Login

```mermaid
sequenceDiagram
  autonumber
  participant B as Browser
  participant T as Traefik (protected)
  participant O as oauth2-proxy
  participant D as Descope
  participant G as Google
  B->>T: GET https://grafana.dev.kfirs.com/
  T->>O: ForwardAuth (X-Forwarded-Host, X-Forwarded-Uri)
  O-->>T: 302 to Descope authorize
  T-->>B: 302
  B->>D: authorize (sign-in-only flow)
  D->>G: Google sign-in
  G-->>D: identity
  D-->>B: 302 https://auth.kfirs.com/oauth2/callback?code=...
  B->>O: callback (via public gateway)
  O->>D: exchange code, validate ID token
  O-->>B: session cookie on .kfirs.com, 302 back to grafana
  B->>T: GET with cookie
  T->>O: ForwardAuth
  O-->>T: 202 + X-Auth-Request-Email
  T->>B: Grafana (signed in as that email)
```

## Who can sign in

Descope's user list is the only gate: every user of the Descope project can sign in to every hub application, and
nobody else can. oauth2-proxy admits every user Descope authenticates. Two independent Descope settings keep the list
closed:

1. The flow is sign-in only (template "Sign in, allow social login when sign-ups are not allowed"), so only existing
   users can finish it; Google is the login method.
2. The project blocks self-registration (Project Settings → "Block self-registration sign up"), so users can't
   register themselves through any flow, including Descope's default sign-up-or-in.

A mistake in either one (for example the OIDC application's login page reverting to sign-up-or-in) does not open the
hub. The project must have no SSO tenant or tenant self-provisioning domain: either would admit users by domain.

Granting access means creating the user in Descope (Descope calls it inviting; sending the invitation is optional).
Revoking it means disabling or deleting the user there. oauth2-proxy refreshes sessions older than 5 minutes; once
Descope refuses a refresh, the session ends, at the latest when its current Descope token expires.

## Applications behind the interceptor

| Application | Application-level login |
| --- | --- |
| Grafana | Trusts `X-Auth-Request-Email` (auth proxy mode); users are created on first visit |
| Argo CD | Signed in from the Descope session: its route's `descope-token` middleware passes oauth2-proxy's `Authorization: Bearer <ID token>`, which Argo CD verifies against the same Descope client; every authenticated user is admin. Its own Descope login remains the fallback |
| Tekton Dashboard, NUI, Traefik dashboard | None; the interceptor is the only gate |

Header safety: `strip-auth-headers` removes `X-Auth-Request-*` headers sent by clients before ForwardAuth runs, and
ForwardAuth copies the verified values from oauth2-proxy's response. NetworkPolicies let protected backends accept
traffic only from the `traefik` namespace (Argo CD's server also admits its own namespace and Octomaton's webhook
relay), so the interceptor can't be bypassed from inside the cluster.

## Decisions

| Decision | Why | Rejected |
| --- | --- | --- |
| Traefik behind L4 load balancers | Simple, portable, fast to change; TLS and routing stay in the cluster | GKE Gateway / L7 load balancers (unreliable for this use, slow to converge) |
| Gateway API resources | Standard, portable routing API; Traefik implements it | Traefik-only `IngressRoute`s (still used for the dashboard, which is internal to Traefik) |
| Two load balancers, interceptor on the entry point | Authentication by default, no per-route opt-in | One load balancer with a per-route auth filter (easy to forget) |
| Descope as identity provider | Users are managed individually, not by email domain; Google login included | Google OAuth directly (domain-oriented, no user management) |
| Default Descope OIDC application | Available on the free plan; Argo CD and oauth2-proxy share it | Separate applications per client (paid feature) |
| Descope alone decides who signs in | One user list, managed in Descope's console; two independent Descope settings keep sign-up closed | An email allowlist in oauth2-proxy as well (a second list to keep in step, edited in Secret Manager) |
| One `.kfirs.com` session cookie | One login covers every hub application | Per-application logins |

## Manual setup

Descope (company `KFIRS`, project `development`, `P3JyPV2qsSrMLUpVPTGcBNRHlSkv`; used only by the hub). Already
configured:

- Flow `hub-sign-in` ("Hub sign in (Google, pre-created users)"): Google sign-in that only succeeds for existing
  users. The first Google login of a pre-created user sends a one-time code to their email and links the Google identity
  to that user.
- The default OIDC application's login page uses `hub-sign-in` (was `sign-up-or-in`).
- User `arikkfir@gmail.com` exists.

Still manual: turn on Project Settings → "Block self-registration sign up", and create an access key (Access keys →
create); store it as Secret Manager secret `oidc-client-secret`. Recommended: restrict the OIDC application's approved
redirect URLs to `https://auth.kfirs.com/oauth2/callback` and `https://argocd.dev.kfirs.com/auth/callback`. To admit
someone else, create their user in Descope with their Google email as the login ID.

Secret Manager: `oauth2-proxy-cookie-secret` (`openssl rand -base64 32 | tr -- '+/' '-_'`).

## Open questions

- Short-lived access for non-browser clients (the Argo CD CLI uses `--port-forward` today).
