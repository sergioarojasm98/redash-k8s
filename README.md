# Redash on Kubernetes

> **Archived.** I no longer run Redash. This repo stays public as a working reference; it is not maintained.

Plain Kubernetes manifests and a deploy script for [Redash](https://redash.io/), in two variants that share the same
web / worker / scheduler / Redis layout and differ in where Postgres lives and how you reach the UI.

| Variant | Postgres | Access | Extras |
|---------|----------|--------|--------|
| [`cloud/`](cloud/README.md) | External managed (Supabase pooler) | Cloudflare Tunnel, no open ports | Supabase keep-alive (CronJob + GitHub Actions + dead-man's switch), CD workflow for Rackspace Spot |
| [`local/`](local/README.md) | In-cluster StatefulSet with a 5 Gi PVC | NodePort `:30500` on your LAN | None: no cloud accounts needed |

Pick `cloud/` for an always-on instance on a cheap cluster, `local/` for a laptop or homelab cluster (Docker Desktop,
OrbStack, k3s, minikube, WSL2).

## Quick start

```bash
cd local            # or cloud
cp .env.example .env
# fill in .env (each variant's README lists every variable)
./deploy.sh deploy
./deploy.sh status
```

`deploy.sh` reads `.env`, renders `02-secrets.yaml`, applies the numbered manifests in order and runs the database
migration job. `./deploy.sh cleanup` removes everything (with `local/`, that includes the data).

## Layout

```text
cloud/   manifests 00-60, deploy.sh, .env.example, docs/keepalive-bootstrap.sql
local/   manifests 00-50 (15-postgres.yaml instead of the tunnel and keep-alive), deploy.sh, .env.example
.github/workflows/
  ci.yml         yamllint + shellcheck for both variants
  cd.yaml        manual deploy of cloud/ to Rackspace Spot (kubeconfig from the Spot API)
  keepalive.yml  backup heartbeat that keeps a free Supabase project from pausing
```

## License

[MIT](LICENSE)
