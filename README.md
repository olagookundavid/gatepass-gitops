# gatepass-gitops

Everything Argo CD syncs into the Gatepass cluster: the desired state, in Git. Part of the Gatepass capstone (three repositories: `gatepass-app` for code, `gatepass-infra` for Terraform, this one for what runs inside the cluster).

**The rule of this repository:** the cluster is changed by merging a pull request here, never by running `kubectl apply`. Argo CD compares this repository with the cluster every 3 minutes and fixes any difference (`selfHeal`); something removed from here is removed from the cluster (`prune`).

## Layout

| Path | What it holds | Applied by |
|---|---|---|
| `bootstrap/` | The child applications of the **root** application (the root itself is created once by Terraform, `gatepass-infra/25-gitops-bootstrap`). Adding a file here adds an application. | root app |
| `projects/` | `AppProject` objects: the fences (`platform`: wide, `apps`: narrow) saying which repositories an application may read and where it may write | `projects` app |
| `platform/argocd/values.yaml` | The full configuration of Argo CD itself (SSO, notifications, timeouts) | `platform-argocd` app (Argo CD manages itself) |
| `platform/<add-on>/values.yaml` | The values of each platform controller's Helm chart (load balancer controller, Karpenter, metrics-server, External Secrets, KEDA) | the add-on's own app in `bootstrap/` |
| `platform/cluster-config/` | Cluster-wide objects that are not a controller: namespaces, Karpenter node class and pools, the `alb` IngressClass, StorageClass, secret store (quotas and network policies later) | `cluster-config` app |
| `examples/` | Inert on purpose (nothing reads it): throwaway applications the walkthroughs activate by moving one file into `bootstrap/` | nobody, until moved |
| `hack/render-charts.rb` | The chart render check, the same as CI runs | you / CI |

Planned, in later phases: more `platform/<add-on>/` folders, `charts/gatepass-service/` (the one generic chart), `apps/<service>/` (values per service per environment), `environments/`, `policies/`, `observability/`.

```
Terraform (once per cluster) ──installs──> Argo CD ──reads──> bootstrap/ (root app)
                                                        ├── projects/            AppProjects
                                                        ├── platform/argocd/     Argo CD configures itself
                                                        └── platform/cluster-config/   namespaces ...
```

## Working rules

- **Pull requests only.** `main` is protected by a ruleset (pull request required, no bypass) and three checks must pass: `manifests-validate`, `argocd-values`, `gitleaks`.
- **No secrets here, ever.** The repository is public. Secrets live in AWS Secrets Manager and reach the cluster through Terraform (now) or External Secrets (Phase 3). A value that must be referenced is written as `$secret-name:key`.
- **Everything pinned.** Chart versions are exact; actions are pinned by commit SHA.
- **Every file starts with a comment** saying why it exists and how it relates to the others.

## Upgrading Argo CD

The chart version appears in two places that must stay equal: `targetRevision` in `bootstrap/platform-argocd.yaml` and `var.argocd_chart_version` in `gatepass-infra/25-gitops-bootstrap/variables.tf` (so that tomorrow's rebuild installs the same version the cluster runs today). Read the chart's release notes, change both in pull requests, merge this one first.

## Local checks (the same as CI)

```
ruby hack/render-charts.rb          # every chart renders with its pinned version and our values
kubeconform -strict -summary -ignore-filename-pattern 'values\.yaml$' bootstrap projects platform examples   # needs the CRD schema location, see .github/workflows/ci.yaml
```
