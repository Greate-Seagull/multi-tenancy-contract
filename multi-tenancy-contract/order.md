1. `helm install argocd ...` với `values/argocd-values.yaml` (làm tay)
2. `kubectl apply -f root-app.yaml` (làm tay)
3. Argo CD tự sync thư mục `apps/` theo thứ tự:
    - Wave 0: `apps/argocd.yaml`, `apps/cert-manager.yaml`
    - Wave 1: `apps/cnpg.yaml`, `apps/eso.yaml`, `apps/vault-tls.yaml` (dùng `manifests/vault-tls/vault-tls.yaml`)
    - Wave 2: `apps/vco.yaml`
    - Wave 3: `apps/vault.yaml` (dùng `values/vault-values.yaml`)
4. `BOOTSTRAP.md` bước 1 đến 6 (init, unseal, audit, Kubernetes auth, role `policy-admin`)
5. Dán `vault.caCert` vào `values/pg-main.yaml`, push
6. `kubectl apply -f apps-phase2/pg-main-vault.yaml`, rồi sync trong Argo CD (dùng `charts/pg-main-vault`)
7. `BOOTSTRAP.md` bước 8: ký intermediate CA, dán `postgres.clientCaChain` vào `values/pg-main.yaml`, push
8. `kubectl apply -f apps-phase2/pg-main.yaml`, rồi sync trong Argo CD (dùng `charts/pg-main`)
9. `BOOTSTRAP.md` bước 9: kiểm tra, thu hồi root token

git change (bootstrap config) -> agro cd sync -> bootstrap