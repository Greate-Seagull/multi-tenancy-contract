#!/usr/bin/env bash
# ci/bootstrap.sh
set -euo pipefail
NS=db

# 1. Operator (--wait để webhook sẵn sàng trước khi apply Cluster)
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm upgrade --install cnpg cnpg/cloudnative-pg \
  -n cnpg-system --create-namespace --wait --timeout 3m

# 2. Namespace + PKI giả lập (thay cho Vault PKI)
kubectl create ns $NS
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt \
  -subj "/CN=test-client-ca" -days 1
openssl req -newkey rsa:2048 -nodes -keyout repl.key -out repl.csr \
  -subj "/CN=streaming_replica"
openssl x509 -req -in repl.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out repl.crt -days 1

kubectl -n $NS create secret generic pg-main-vault-client-ca --from-file=ca.crt
kubectl -n $NS create secret generic pg-main-replication-tls \
  --type=kubernetes.io/tls \
  --from-file=tls.crt=repl.crt --from-file=tls.key=repl.key --from-file=ca.crt

# 3. Render + apply (instances=1 cho runner)
helm template pg ./chart -n $NS -f values.yaml \
  --set postgres.instances=1 | kubectl -n $NS apply -f -

# 4. Chờ bootstrap xong
kubectl -n $NS wait --for=condition=Ready cluster/pg-main --timeout=300s
kubectl -n $NS get cluster pg-main