#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if kubectl is available and connected
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is not installed or not in PATH"
        exit 1
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        print_error "kubectl cannot connect to cluster"
        exit 1
    fi
    
    print_success "kubectl is available and connected"
}

# Function to check if .env file exists
check_env_file() {
    if [[ ! -f ".env" ]]; then
        print_error ".env file not found"
        print_status "Please create a .env file based on .env.example:"
        echo "  cp .env.example .env"
        echo "  # Edit .env with your actual values"
        exit 1
    fi
    print_success ".env file found"
}

# Function to validate required environment variables
validate_env_vars() {
    print_status "Validating environment variables..."
    
    local required_vars=(
        "REDASH_COOKIE_SECRET"
        "REDASH_SECRET_KEY"
        "REDASH_DATABASE_URL"
        "REDASH_MAIL_SERVER"
        "REDASH_MAIL_PORT"
        "REDASH_MAIL_USE_SSL"
        "REDASH_MAIL_USE_TLS"
        "REDASH_MAIL_USERNAME"
        "REDASH_MAIL_PASSWORD"
        "REDASH_MAIL_DEFAULT_SENDER"
        "TUNNEL_TOKEN"
        "KEEPALIVE_DATABASE_URL"
    )
    
    local missing_vars=()
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        print_error "Missing required environment variables:"
        for var in "${missing_vars[@]}"; do
            echo "  - $var"
        done
        print_status "Please check your .env file and ensure all required variables are set"
        exit 1
    fi
    
    print_success "All required environment variables are set"
}

substitute_vars() {
    local file=$1
    print_status "Processing $file..."
    
    # Create a temporary file with substituted variables
    local temp_file
    temp_file=$(mktemp)
    envsubst < "$file" > "$temp_file"
    
    # Replace the original file
    mv "$temp_file" "$file.processed"
    print_success "Created $file.processed with substituted variables"
}

# Function to apply Kubernetes manifests
apply_manifests() {
    print_status "Applying Kubernetes manifests..."
    
    local files=(
        "00-namespace.yaml"
        "02-secrets.yaml.processed"
        "05-config.yaml"
        "10-redis.yaml"
        "20-job-migrate.yaml"
        "30-redash-core.yaml"
        "40-cloudflared.yaml"
        "50-guardrails.yaml"
        "60-keepalive.yaml"
    )
    
    for file in "${files[@]}"; do
        if [[ -f "$file" ]]; then
            print_status "Applying $file..."
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

# Function to wait for job completion (optional for existing DBs)
wait_for_migration() {
    print_status "Checking if database migration is needed..."
    
    # Check if migration job exists and if it needs to run
    if kubectl get job redash-migrate -n redash &>/dev/null; then
        print_status "Migration job found. Waiting for completion..."
        
        # Wait for job to complete (timeout after 5 minutes)
        if kubectl wait --for=condition=complete --timeout=300s job/redash-migrate -n redash 2>/dev/null; then
            print_success "Migration job completed successfully"
        elif kubectl wait --for=condition=failed --timeout=10s job/redash-migrate -n redash 2>/dev/null; then
            print_warning "Migration job failed - this might be expected if DB is already up to date"
            print_status "Check job logs with: kubectl logs job/redash-migrate -n redash"
        else
            print_warning "Migration job is still running or failed"
            print_status "You can check status with: kubectl get job redash-migrate -n redash"
        fi
    else
        print_warning "No migration job found - skipping database migration"
        print_status "If you need to run migrations later: kubectl apply -f 20-job-migrate.yaml"
    fi
}

# Function to check deployment status
check_deployment_status() {
    print_status "Checking deployment status..."
    
    local deployments=("redash-web" "redash-worker" "redash-scheduler" "cloudflared-tunnel")
    
    # Check redash deployments
    for deployment in "${deployments[@]}"; do
        if kubectl rollout status deployment/"$deployment" -n redash --timeout=300s; then
            print_success "Deployment $deployment is ready"
        else
            print_error "Deployment $deployment failed or timed out"
            exit 1
        fi
    done
}

# Function to cleanup processed files
cleanup() {
    print_status "Cleaning up temporary files..."
    rm -f *.processed
    print_success "Cleanup completed"
}

# Function to show deployment information
show_info() {
    echo ""
    print_success "Deployment completed successfully!"
    echo ""
    print_status " Access your applications via Cloudflare Tunnel:"
    echo "    🎯 Redash: https://redash.example.com"
    echo ""
    print_status "Useful commands for monitoring:"
    echo "  # Check pod status:"
    echo "    kubectl get pods -n redash"
    echo ""
    echo "  # Check service status (all should be ClusterIP):"
    echo "    kubectl get svc -n redash"
    echo ""
    echo "  # View logs:"
    echo "    kubectl logs -f deployment/redash-web -n redash"
    echo "    kubectl logs -f deployment/redash-worker -n redash"
    echo "    kubectl logs -f deployment/redash-scheduler -n redash"
    echo "    kubectl logs -f deployment/cloudflared-tunnel -n redash"
    echo ""
    print_warning "⚠️  For local testing only (NOT for production):"
    echo "    kubectl port-forward svc/redash-web 5000:5000 -n redash"
    echo "    Then visit: http://localhost:5000 (Redash)"
    echo ""
    print_status "🎉 Your secure cluster setup:"
    echo "  �️ Zero external exposure - tunnel only access"
    echo "  � Complete monitoring and analytics stack"
    echo ""
}

# Main deployment function
main() {
    echo ""
    print_status "🚀 Starting Redash deployment..."
    echo ""
    
    # Load environment variables from .env file
    check_env_file
    set -a  # automatically export all variables
    source .env
    set +a  # stop automatically exporting
    
    # Run all checks and operations
    check_kubectl
    validate_env_vars
    
    # HC_PING_URL is optional (dead-man's switch); export it even when unset so
    # envsubst renders an empty value instead of leaving the ${...} placeholder.
    export HC_PING_URL="${HC_PING_URL:-}"

    # Process files with environment variable substitution
    substitute_vars "02-secrets.yaml"
    
    # Apply all manifests
    apply_manifests
    
    # Wait for migration to complete
    wait_for_migration
    
    # Check deployment status
    check_deployment_status
    
    # Cleanup
    cleanup
    
    # Show final information
    show_info
}

# Handle script interruption
trap cleanup EXIT

# Handle command line arguments
case "${1:-deploy}" in
    "deploy")
        main
        ;;
    "cleanup")
        print_status "Cleaning up Redash deployment..."
        kubectl delete namespace redash --ignore-not-found=true
        print_success "Cleanup completed"
        ;;
    "status")
        print_status "Checking Redash deployment status..."
        kubectl get all -n redash
        ;;
    "logs")
        component="${2:-web}"
        print_status "Showing logs for redash-$component..."
        kubectl logs -f deployment/redash-$component -n redash
        ;;
    "help"|"-h"|"--help")
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  deploy          Deploy Redash (default)"
        echo "  cleanup         Remove Redash deployment"
        echo "  status          Show deployment status"
        echo "  logs            Show logs for component (web|worker|scheduler)"
        echo "  help            Show this help"
        echo ""
        echo "Examples:"
        echo "  $0 deploy"
        echo "  $0 status"
        echo "  $0 logs web"
        echo "  $0 cleanup"
        ;;
    *)
        print_error "Unknown command: $1"
        print_status "Run '$0 help' for usage information"
        exit 1
        ;;
esac
