# Redash Kubernetes Deployment with Headlamp Monitoring

This repository contains Kubernetes manifests for deploying Redash with all necessary components, plus Headlamp for cluster monitoring, secured via Cloudflare Tunnel.

## 🏗️ Architecture Overview

- **Redash Analytics**: Main application with web UI, background worker, and scheduler
- **Redis Cache**: In-memory caching for improved performance
- **Headlamp**: Kubernetes web UI for cluster monitoring and management
- **Cloudflare Tunnel**: Zero-trust external access without exposed ports
- **Security**: NetworkPolicies, ResourceQuotas, and PodDisruptionBudgets

## 🚀 Quick Start

### 1. Prerequisites

- Kubernetes cluster (4 vCPU + 7.5GB RAM recommended)
- kubectl configured and connected
- Cloudflare account with domain (for external access)

### 2. Configuration

Copy the example environment file and configure your values:

```bash
cp .env.example .env
# Edit .env with your actual values
```

**Required environment variables:**
```bash
# Redash Application
REDASH_COOKIE_SECRET=your-cookie-secret-here
REDASH_SECRET_KEY=your-secret-key-here
REDASH_DATABASE_URL=postgresql://user:pass@host:5432/redash

# SMTP Configuration
REDASH_MAIL_SERVER=smtp.gmail.com
REDASH_MAIL_PORT=587
REDASH_MAIL_USE_SSL=false
REDASH_MAIL_USE_TLS=true
REDASH_MAIL_USERNAME=your-email@gmail.com
REDASH_MAIL_PASSWORD=your-app-password
REDASH_MAIL_DEFAULT_SENDER=your-email@gmail.com

# Cloudflare Tunnel (for external access)
TUNNEL_TOKEN=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
```

### 3. Deploy

Use the automated deployment script:

```bash
# Deploy everything (recommended)
./deploy.sh deploy

# Check deployment status
./deploy.sh status

# View logs for specific component
./deploy.sh logs web
./deploy.sh logs worker
./deploy.sh logs scheduler

# Generate Headlamp access token
./deploy.sh generate-token

# Clean up deployment
./deploy.sh cleanup
```

## � Access Your Applications

### External Access (via Cloudflare Tunnel)
- **Redash**: https://redash.yourdomain.com
- **Headlamp**: https://hl-redash.yourdomain.com

### Local Testing (port-forward)
```bash
# Redash
kubectl port-forward svc/redash-web 5000:5000 -n redash
# Visit: http://localhost:5000

# Headlamp
kubectl port-forward svc/my-headlamp 8080:80 -n kube-system
# Visit: http://localhost:8080
```

## 🔐 Headlamp Authentication

Headlamp uses token-based authentication for security:

### Generate Access Token
```bash
# Generate token (valid for 1 year)
kubectl create token headlamp-admin --namespace kube-system --duration=8760h

# Or use the script
./deploy.sh generate-token
```

### Login Process
1. Visit https://hl-redash.yourdomain.com
2. Paste the generated token in the login form
3. Enjoy full cluster-admin access to your Kubernetes cluster

**Security Note**: Without a valid token, Headlamp is completely inaccessible.

## 📁 Component Details

| File | Purpose | Resources |
|------|---------|-----------|
| `00-namespace.yaml` | Creates `redash` namespace | - |
| `02-secrets.yaml` | Application secrets from .env | - |
| `05-config.yaml` | Redash configuration | - |
| `10-redis.yaml` | Redis cache | 768MB RAM |
| `20-job-migrate.yaml` | Database migrations | 256MB RAM |
| `30-redash-core.yaml` | Main Redash services | 2.5GB RAM total |
| `40-cloudflared.yaml` | Cloudflare tunnel | 256MB RAM |
| `50-guardrails.yaml` | Security policies | - |
| `60-headlamp.yaml` | Kubernetes web UI | 384MB RAM |

### Resource Allocation Summary
```
Total Requests: ~2 vCPU, 4GB RAM
Total Limits:   ~4 vCPU, 6GB RAM
Cluster Target: 4 vCPU, 7.5GB RAM (80% utilization)
```

## 🛠️ Manual Deployment

If you prefer step-by-step manual deployment:

```bash
# 1. Create namespace
kubectl apply -f 00-namespace.yaml

# 2. Configure environment
cp .env.example .env
# Edit .env with your values

# 3. Process and apply secrets
export $(cat .env | xargs)
envsubst < 02-secrets.yaml > 02-secrets.yaml.processed
kubectl apply -f 02-secrets.yaml.processed

# 4. Deploy infrastructure
kubectl apply -f 05-config.yaml
kubectl apply -f 10-redis.yaml

# 5. Run database migration
kubectl apply -f 20-job-migrate.yaml
kubectl wait --for=condition=complete --timeout=300s job/redash-migrate -n redash

# 6. Deploy Redash services
kubectl apply -f 30-redash-core.yaml

# 7. Deploy external access
kubectl apply -f 40-cloudflared.yaml

# 8. Apply security policies
kubectl apply -f 50-guardrails.yaml

# 9. Deploy Headlamp monitoring
kubectl apply -f 60-headlamp.yaml

# 10. Generate Headlamp token
kubectl create token headlamp-admin --namespace kube-system --duration=8760h
```

## 🔧 Useful Commands

### Monitoring and Logs
```bash
# Check all pods status
kubectl get pods -n redash
kubectl get pods -n kube-system | grep headlamp

# View service endpoints (all should be ClusterIP)
kubectl get svc -n redash
kubectl get svc -n kube-system my-headlamp

# Check Cloudflare tunnel connectivity
kubectl logs -f deployment/cloudflared-tunnel -n redash

# View Redash logs
kubectl logs -f deployment/redash-web -n redash
kubectl logs -f deployment/redash-worker -n redash
kubectl logs -f deployment/redash-scheduler -n redash
```

### Troubleshooting
```bash
# Check deployment status
kubectl get deployments -n redash
kubectl rollout status deployment/redash-web -n redash

# Verify secrets
kubectl get secrets -n redash
kubectl describe secret redash-core-secrets -n redash

# Check migration job
kubectl get job redash-migrate -n redash
kubectl logs job/redash-migrate -n redash
```

### Scaling
```bash
# Scale Redash components
kubectl scale deployment redash-web --replicas=2 -n redash
kubectl scale deployment redash-worker --replicas=3 -n redash

# Scale Cloudflare tunnel for HA
kubectl scale deployment cloudflared-tunnel --replicas=2 -n redash
```

## 🔒 Security Features

### Network Security
- **ClusterIP services only** - No external exposure except via tunnel
- **NetworkPolicies** - Microsegmentation between components
- **Cloudflare Tunnel** - Zero-trust external access

### Resource Protection  
- **ResourceQuotas** - Prevent resource exhaustion
- **PodDisruptionBudgets** - Ensure availability during updates
- **Security contexts** - Non-root containers with dropped capabilities

### Authentication
- **Headlamp token-based auth** - No anonymous access
- **ServiceAccount isolation** - Proper RBAC separation
- **Secret management** - Environment-based configuration

## 🔧 Configuration Options

### Resource Tuning
Edit resource limits in manifests for your cluster size:

```yaml
# 30-redash-core.yaml - adjust based on usage
resources:
  requests:
    cpu: "500m"
    memory: "896Mi"
  limits:
    cpu: "1000m"
    memory: "1.3Gi"
```

### Security Policies
Adjust NetworkPolicies in `50-guardrails.yaml` for stricter controls:

```yaml
# Currently permissive for simplicity
# Customize egress rules for production
egress:
  - {}  # Allow all egress
```

## 🎯 Production Considerations

### Before Production Deployment:
1. **Database**: Use managed PostgreSQL (not included in this repo)
2. **Persistence**: Add persistent volumes for Redis if needed  
3. **Monitoring**: Integrate with your monitoring stack
4. **Backups**: Set up regular database backups
5. **SSL/TLS**: Ensure proper certificate management
6. **Network Policies**: Tighten security rules as needed

### Recommended Cluster Resources:
- **Minimum**: 2 vCPU, 4GB RAM
- **Recommended**: 4 vCPU, 8GB RAM
- **Production**: 8 vCPU, 16GB RAM with autoscaling

## 📚 Additional Resources

- [Redash Documentation](https://redash.io/help/)
- [Headlamp Documentation](https://headlamp.dev/)
- [Cloudflare Tunnel Guide](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- [Kubernetes Security Best Practices](https://kubernetes.io/docs/concepts/security/)

## 🆘 Support

For issues and questions:
1. Check the logs: `./deploy.sh logs [component]`
2. Verify configuration: `./deploy.sh status`
3. Review the troubleshooting section above
4. Check Kubernetes events: `kubectl get events -n redash`
