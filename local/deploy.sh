#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NODE_PORT=30500

print_status()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ---------------------------------------------------------------------------
# Detect LAN IP (macOS / Linux)
# ---------------------------------------------------------------------------
detect_lan_ip() {
    local ip=""
    if command -v ipconfig &>/dev/null; then
        # macOS
        ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
    fi
    if [[ -z "$ip" ]] && command -v ip &>/dev/null; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' || true)
    fi
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    fi
    echo "${ip:-localhost}"
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
check_kubectl() {
    if ! command -v kubectl &>/dev/null; then
        print_error "kubectl is not installed or not in PATH"
        exit 1
    fi
    if ! kubectl cluster-info &>/dev/null; then
        print_error "kubectl cannot connect to cluster — is your Kubernetes cluster running?"
        exit 1
    fi
    print_success "kubectl connected to cluster"
}

check_env_file() {
    if [[ ! -f ".env" ]]; then
        print_error ".env file not found"
        print_status "Create one from the template:"
        echo "  cp .env.example .env"
        exit 1
    fi
    print_success ".env file found"
}

validate_env_vars() {
    print_status "Validating environment variables..."

    local required_vars=(
        "REDASH_COOKIE_SECRET"
        "REDASH_SECRET_KEY"
        "POSTGRES_PASSWORD"
    )

    local missing=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "Missing required environment variables:"
        for var in "${missing[@]}"; do
            echo "  - $var"
        done
        exit 1
    fi

    print_success "All required environment variables are set"
}

# ---------------------------------------------------------------------------
# Template processing
# ---------------------------------------------------------------------------
substitute_vars() {
    local file=$1
    print_status "Processing $file..."
    envsubst < "$file" > "$file.processed"
    print_success "Created $file.processed"
}

# ---------------------------------------------------------------------------
# Apply manifests
# ---------------------------------------------------------------------------
apply_manifests() {
    print_status "Applying Kubernetes manifests..."

    local files=(
        "00-namespace.yaml"
        "02-secrets.yaml.processed"
        "05-config.yaml"
        "10-redis.yaml"
        "15-postgres.yaml"
        "30-redash-core.yaml"
        "50-guardrails.yaml"
    )

    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            if kubectl apply -f "$file"; then
                print_success "Applied $file"
            else
                print_error "Failed to apply $file"
                exit 1
            fi
        else
            print_warning "File $file not found, skipping"
        fi
    done
}

# ---------------------------------------------------------------------------
# Wait for PostgreSQL to be ready before running migrations
# ---------------------------------------------------------------------------
wait_for_postgres() {
    print_status "Waiting for PostgreSQL to be ready..."
    if ! kubectl rollout status deployment/redash-postgres -n redash --timeout=120s; then
        print_error "PostgreSQL deployment failed"
        exit 1
    fi
    # Extra wait for pg_isready
    sleep 5
    print_success "PostgreSQL is ready"
}

# ---------------------------------------------------------------------------
# Database migration
# ---------------------------------------------------------------------------
run_migration() {
    print_status "Initializing database..."

    kubectl delete job redash-create-db -n redash --ignore-not-found=true &>/dev/null
    kubectl apply -f 20-job-migrate.yaml

    if kubectl wait --for=condition=complete --timeout=300s job/redash-create-db -n redash 2>/dev/null; then
        print_success "Database initialized successfully"
    elif kubectl wait --for=condition=failed --timeout=10s job/redash-create-db -n redash 2>/dev/null; then
        print_warning "Database init failed — check logs: kubectl logs job/redash-create-db -n redash"
    else
        print_warning "Database init still running — check: kubectl get job redash-create-db -n redash"
    fi
}

# ---------------------------------------------------------------------------
# Patch REDASH_HOST with detected LAN IP
# ---------------------------------------------------------------------------
patch_redash_host() {
    local lan_ip
    lan_ip=$(detect_lan_ip)
    local host_url="http://${lan_ip}:${NODE_PORT}"

    print_status "Setting REDASH_HOST to ${host_url}"
    kubectl patch configmap redash-config -n redash \
        --type merge -p "{\"data\":{\"REDASH_HOST\":\"${host_url}\"}}" &>/dev/null
}

# ---------------------------------------------------------------------------
# Wait for deployments
# ---------------------------------------------------------------------------
check_deployment_status() {
    print_status "Waiting for deployments to be ready..."

    local deployments=("redash-web" "redash-worker" "redash-scheduler")
    for d in "${deployments[@]}"; do
        if kubectl rollout status deployment/"$d" -n redash --timeout=300s; then
            print_success "$d is ready"
        else
            print_error "$d failed or timed out"
            exit 1
        fi
    done
}

# ---------------------------------------------------------------------------
# Cleanup temp files
# ---------------------------------------------------------------------------
cleanup() {
    rm -f *.processed
}

# ---------------------------------------------------------------------------
# Show final info
# ---------------------------------------------------------------------------
show_info() {
    local lan_ip
    lan_ip=$(detect_lan_ip)

    echo ""
    print_success "Deployment completed!"
    echo ""
    print_status "Access Redash:"
    echo "    Local:  http://localhost:${NODE_PORT}"
    echo "    LAN:    http://${lan_ip}:${NODE_PORT}"
    echo ""
    print_status "Useful commands:"
    echo "  ./deploy.sh status          # Pod status"
    echo "  ./deploy.sh logs web        # Web server logs"
    echo "  ./deploy.sh logs worker     # Worker logs"
    echo "  ./deploy.sh cleanup         # Remove everything"
    echo ""
}

# ===========================================================================
# Main
# ===========================================================================
main() {
    echo ""
    print_status "Starting Redash local deployment..."
    echo ""

    check_env_file
    set -a
    source .env
    set +a

    check_kubectl
    validate_env_vars

    substitute_vars "02-secrets.yaml"

    apply_manifests
    wait_for_postgres
    run_migration
    patch_redash_host
    check_deployment_status

    cleanup
    show_info
}

trap cleanup EXIT

case "${1:-deploy}" in
    "deploy")
        main
        ;;
    "cleanup")
        print_status "Removing Redash deployment..."
        kubectl delete namespace redash --ignore-not-found=true
        print_success "Cleanup completed"
        ;;
    "status")
        kubectl get all -n redash
        ;;
    "logs")
        component="${2:-web}"
        kubectl logs -f "deployment/redash-$component" -n redash
        ;;
    "help"|"-h"|"--help")
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  deploy    Deploy Redash to local K8s (default)"
        echo "  cleanup   Remove entire Redash namespace"
        echo "  status    Show pod/service status"
        echo "  logs      Tail logs: logs [web|worker|scheduler|postgres|redis]"
        echo "  help      Show this help"
        ;;
    *)
        print_error "Unknown command: $1"
        echo "Run '$0 help' for usage"
        exit 1
        ;;
esac
