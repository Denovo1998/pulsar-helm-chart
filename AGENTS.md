# Repository Guidelines

## Project Structure & Module Organization

- `charts/` – Helm charts. The main chart is `charts/pulsar`, with additional supporting charts under `charts/cert-manager` and `charts/kube-prometheus-stack`.
- `charts/pulsar/templates/` – Kubernetes manifests and shared templates (`_*.tpl`) for Pulsar components.
- `examples/` – Sample `values-*.yaml` files showing common deployment scenarios (TLS, JWT, local PV, no persistence, etc.).
- `scripts/` – Operational helper scripts (e.g., Pulsar token and release preparation tools).
- `hack/` – Development utilities (kind-based dev cluster, local tooling bootstrap).

## Build, Test, and Development Commands

- `go test ./...` – Runs Go tests, including `license_test.go` to verify license headers on `.go`, `.yaml`, and `.conf` files.
- `helm lint charts/pulsar` – Lints the main Pulsar chart.
- `helm template charts/pulsar -f examples/values-minikube.yaml` – Renders manifests for a concrete example; adjust values file as needed.
- `PULSAR_CHART_HOME=$(pwd) hack/kind-cluster-build.sh` – Creates a local kind cluster for development and manual testing.

## Coding Style & Naming Conventions

- YAML: 2-space indentation, follow existing key ordering and naming (lowercase, hyphen-separated keys where used).
- Helm: Prefer existing helper templates in `_helpers.tpl` and component-specific `_*.tpl` files; add new helpers rather than duplicating logic.
- Filenames: For new templates, follow the existing `<component>-<resource>.yaml` pattern (for example, `broker-service.yaml`).
- Licensing: All new `.go`, `.yaml`, and `.conf` files must include the standard ASF license header (see `license_test.go` for the expected text).

## Testing Guidelines

- Always run `go test ./...` and `helm lint charts/pulsar` before opening a PR.
- For nontrivial changes, render manifests for at least one relevant example values file under `examples/` using `helm template`.
- When possible, validate rendered manifests against a real cluster (for example, via a kind cluster created with `hack/kind-cluster-build.sh`).

## Commit & Pull Request Guidelines

- Commit messages: Use short, imperative summaries similar to existing history (for example, `Upgrade to Pulsar 4.0.7 (#640)` or `Fix broken link`).
- Chart changes that affect users should bump the chart `version` (and, when appropriate, `appVersion`) in `charts/pulsar/Chart.yaml`.
- PRs should include a clear description, mention breaking changes, and link related GitHub issues (for example, `Fixes #1234`) when applicable.
- For release work or version bumps intended for an official release, follow the detailed process in `RELEASE.md`.

## Security & Configuration Notes

- The default values are not production-secure. Contributors must avoid adding options that silently weaken security.
- Document any new security-sensitive configuration clearly in `README.md` and/or example values files.
