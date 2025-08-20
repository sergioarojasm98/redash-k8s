# 00) Namespace

kubectl apply -f 00-namespace.yaml

# 00.5) Secret del Service Account de 1Password (paso “entre 00 y 01”)

kubectl -n redash create secret generic onepassword-service-account-token \
 --from-file=token=<(op read 'op://SR98 - Secrets - Cloud/onepassword-service-account-token/credential' --no-newline)

helm upgrade --install onepassword 1password/connect -n redash \
 --reset-values \
 --set connect.create=false \
 --set operator.create=true \
 --set operator.authMethod=service-account \
 --set operator.serviceAccountToken.name=onepassword-service-account-token \
 --set operator.serviceAccountToken.key=token

# 01) Ítems de 1Password (solo los válidos)

kubectl apply -f 01-onepassword-items.yaml

# 02) Secret con claves de app (para que el server arranque)

kubectl apply -f 02-secrets.yaml

# 05 → 50) Infra + Redash

kubectl apply -f 05-config.yaml
kubectl apply -f 10-redis.yaml
kubectl delete job -n redash redash-migrate --ignore-not-found
kubectl apply -f 20-job-migrate.yaml
kubectl apply -f 30-redash-core.yaml

# opcional

kubectl apply -f 40-cloudflared.yaml
kubectl apply -f 50-guardrails.yaml
