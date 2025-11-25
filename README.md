# Redash on Kubernetes (Rackspace Spot)

Deploy [Redash](https://redash.io/) on a cost-effective Kubernetes cluster using Rackspace Spot instances, with Cloudflare Tunnel for secure external access.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Cloudflare Edge                          │
│                    (DDoS protection, WAF)                       │
└──────────────────────────┬──────────────────────────────────────┘
                           │ Tunnel
┌──────────────────────────▼──────────────────────────────────────┐
│                    Kubernetes Cluster                           │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                   redash namespace                       │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │   │
│  │  │ redash-web  │  │redash-worker│  │ redash-scheduler│  │   │
│  │  │  (Gunicorn) │  │  (Celery)   │  │  (Celery Beat)  │  │   │
│  │  └──────┬──────┘  └──────┬──────┘  └────────┬────────┘  │   │
│  │         │                │                  │           │   │
│  │         └────────────────┼──────────────────┘           │   │
│  │                          │                              │   │
│  │                   ┌──────▼──────┐                       │   │
│  │                   │ redash-redis│                       │   │
│  │                   │   (cache)   │                       │   │
│  │                   └─────────────┘                       │   │
│  │                                                         │   │
│  │  ┌───────────────────┐                                  │   │
│  │  │ cloudflared-tunnel│ ←── External traffic             │   │
│  │  │    (2 replicas)   │                                  │   │
│  │  └───────────────────┘                                  │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                 kube-system namespace                    │   │
│  │  ┌─────────────┐                                        │   │
│  │  │  Headlamp   │ ←── Cluster management UI              │   │
│  │  └─────────────┘                                        │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                           │
                           ▼
                ┌─────────────────────┐
                │  Supabase Postgres  │
                │  (external managed) │
                └─────────────────────┘
```

## Components

| Component | Purpose | Replicas | Resources |
|-----------|---------|----------|-----------|
| **redash-web** | HTTP server (UI + API) | 1 | 500m-1500m CPU, 896Mi-1536Mi RAM |
| **redash-worker** | Async query execution | 1 | 250m-900m CPU, 448Mi-896Mi RAM |
| **redash-scheduler** | Scheduled queries | 1 | 80m-300m CPU, 192Mi-384Mi RAM |
| **redash-redis** | Cache + job queue | 1 | 120m-500m CPU, 384Mi-768Mi RAM |
| **cloudflared** | Secure tunnel | 2 | 50m-200m CPU, 128Mi-256Mi RAM |
| **headlamp** | K8s dashboard | 1 | 80m-300m CPU, 192Mi-384Mi RAM |

**Total**: ~1.1 CPU requests, ~2.2Gi RAM requests

## Prerequisites

- Kubernetes cluster (4 vCPU, 7.5GB RAM recommended)
- `kubectl` configured
- Cloudflare account with tunnel configured
- Supabase project (or any PostgreSQL)

## Quick Start

### 1. Configure Environment

```bash
# Copy template and edit with your values
cp .env.example .env
```

Required variables in `.env`:

```bash
# Redash security keys (generate random strings)
REDASH_COOKIE_SECRET=<random-32-char-string>
REDASH_SECRET_KEY=<random-32-char-string>

# Supabase PostgreSQL connection
REDASH_DATABASE_URL=postgresql://postgres:<password>@<host>:5432/postgres

# SMTP for email notifications (optional but recommended)
REDASH_MAIL_SERVER=smtp.gmail.com
REDASH_MAIL_PORT=587
REDASH_MAIL_USE_SSL=false
REDASH_MAIL_USE_TLS=true
REDASH_MAIL_USERNAME=your-email@gmail.com
REDASH_MAIL_PASSWORD=your-app-password
REDASH_MAIL_DEFAULT_SENDER=your-email@gmail.com

# Cloudflare Tunnel token
TUNNEL_TOKEN=eyJhIjoiNj...
```

### 2. Deploy

```bash
./deploy.sh deploy
```

### 3. Access

- **Redash**: https://redash.redsign98.net
- **Headlamp**: https://hl-redash.redsign98.net

Generate Headlamp token:
```bash
./deploy.sh generate-token
```

## File Structure

```
.
├── 00-namespace.yaml      # Creates 'redash' namespace
├── 02-secrets.yaml        # Secrets (populated from .env)
├── 05-config.yaml         # Redash configuration
├── 10-redis.yaml          # Redis cache/broker
├── 20-job-migrate.yaml    # Database migration job
├── 30-redash-core.yaml    # Web, Worker, Scheduler deployments
├── 40-cloudflared.yaml    # Cloudflare Tunnel
├── 50-guardrails.yaml     # PDBs, ResourceQuota, NetworkPolicy
├── 60-headlamp.yaml       # Kubernetes dashboard
├── deploy.sh              # Deployment automation
└── README.md
```

## Configuration Details

### Concurrency Settings (05-config.yaml)

Tuned for single-user with multiple browser tabs:

| Setting | Value | Purpose |
|---------|-------|---------|
| `REDASH_WEB_WORKERS` | 2 | Gunicorn workers for parallel requests |
| `REDASH_DATABASE_POOL_SIZE` | 3 | DB connections per worker |
| `REDASH_DATABASE_MAX_OVERFLOW` | 2 | Extra connections for spikes |

This allows ~6 concurrent database connections from web, staying well under Supabase limits.

### Resource Quota (50-guardrails.yaml)

Prevents resource exhaustion (matches cluster capacity):

```yaml
requests.cpu: "2"      # Guaranteed CPU
limits.cpu: "4"        # Max burst (= cluster total)
requests.memory: "4Gi"
limits.memory: "6Gi"
```

> **Note**: During `kubectl rollout restart`, K8s tries to create new pods before killing old ones. This can exceed the quota. Use `kubectl delete pod -l app=redash -n redash` instead to force restart.

## Operations

### Update Configuration

```bash
# Edit config
vim 05-config.yaml

# Apply changes
kubectl apply -f 05-config.yaml

# Restart pods to pick up new config
kubectl delete pod -l app=redash -n redash
```

### View Logs

```bash
./deploy.sh logs web
./deploy.sh logs worker
./deploy.sh logs scheduler

# Or directly
kubectl logs -f deployment/redash-web -n redash
```

### Check Status

```bash
./deploy.sh status

# Or
kubectl get pods -n redash
kubectl get events -n redash --sort-by='.lastTimestamp'
```

### Database Migration

Migration runs automatically on first deploy. For version upgrades:

```bash
# Delete old migration job
kubectl delete job redash-migrate -n redash

# Re-apply to run new migrations
kubectl apply -f 20-job-migrate.yaml

# Check status
kubectl logs job/redash-migrate -n redash
```

### Cleanup

```bash
./deploy.sh cleanup
```

## Troubleshooting

### Pods stuck in Pending

Check ResourceQuota:
```bash
kubectl describe resourcequota redash-quota -n redash
```

If quota exceeded, delete old pods or increase quota in `50-guardrails.yaml`.

### 500 Errors / Server Unavailable

1. Check pod health:
   ```bash
   kubectl get pods -n redash
   kubectl describe pod <pod-name> -n redash
   ```

2. Check logs:
   ```bash
   kubectl logs deployment/redash-web -n redash --tail=100
   ```

3. Verify database connectivity:
   ```bash
   kubectl exec -it deployment/redash-web -n redash -- /app/manage.py status
   ```

### Rollout Stuck

ResourceQuota may block new pod creation during rollouts:
```bash
# Force restart by deleting pods
kubectl delete pod -l app=redash,comp=web -n redash
kubectl delete pod -l app=redash,comp=worker -n redash
```

## Security

- **No exposed ports**: All traffic via Cloudflare Tunnel
- **Non-root containers**: All pods run as non-root users
- **Read-only filesystems**: Containers use read-only root FS
- **Dropped capabilities**: All Linux capabilities dropped
- **NetworkPolicy**: Traffic control (currently permissive)
- **ResourceQuota**: Prevents resource exhaustion
- **Token auth**: Headlamp requires authentication token

## Cost Optimization

This setup is optimized for Rackspace Spot instances:

- **Single replicas**: Minimizes resource usage
- **No LoadBalancer**: Cloudflare Tunnel eliminates LB costs
- **Ephemeral Redis**: No persistent storage costs
- **External DB**: Uses Supabase free/cheap tier

Trade-off: Brief downtime during node preemption (~30-60s).

## License

MIT
