# Runbook: khởi tạo Vault (HA Raft, unseal thủ công) và bật giai đoạn 2

Chạy một lần cho mỗi cluster. Sau bước 9, mọi cấu hình Vault do VCO quản lý bằng YAML trong Git.
Mọi lệnh `vault` chạy bên trong pod qua `kubectl exec`; biến `VAULT_ADDR` và `VAULT_CACERT` đã được chart đặt sẵn.

Tổng quan thứ tự:

| Bước | Việc | Ai làm |
|---|---|---|
| 0 | Giai đoạn 1 (cert-manager, vault-tls, Vault, VCO, ESO, CNPG operator) | Argo CD tự sync |
| 1 đến 6 | Init, unseal, audit, Kubernetes auth, role `policy-admin` | Người, một lần |
| 7 | Dán CA của Vault vào values, áp và sync `pg-main-vault` | Người bấm sync |
| 8 | Ký intermediate CA bằng root offline, dán chuỗi CA, áp và sync `pg-main` | Người, một lần |
| 9 | Kiểm tra, rồi thu hồi root token | Người |

## 0. Điều kiện

- Argo CD đã sync giai đoạn 1; `kubectl get certificate -n vault` báo `READY=True` cho `vault-ca` và `vault-tls`.
- Pod `vault-0`, `vault-1`, `vault-2` ở trạng thái `Running` nhưng `0/1` (chưa init nên chưa ready, đây là bình thường).

## 1. Init (chỉ làm trên vault-0, đúng một lần)

```bash
kubectl exec -n vault vault-0 -- vault operator init -key-shares=5 -key-threshold=3
```

Lệnh in ra 5 unseal key và 1 root token. **Chỉ hiện đúng một lần.**

- Không lưu ra file, không dán vào chat/ticket, không để trong biến môi trường của CI.
- Chia 5 key cho 5 người (hoặc 5 nơi lưu tách biệt) sao cho không ai giữ từ 3 key trở lên.
- Root token chỉ giữ tạm đến bước 9.

## 2. Unseal vault-0

Mỗi lần chạy sẽ hỏi một key; cần 3 key khác nhau (có thể do 3 người nhập lần lượt).

```bash
kubectl exec -it -n vault vault-0 -- vault operator unseal
kubectl exec -it -n vault vault-0 -- vault operator unseal
kubectl exec -it -n vault vault-0 -- vault operator unseal
```

Kết quả mong đợi: `Sealed false`.

## 3. Unseal vault-1 và vault-2

Nhờ `retry_join` trong cấu hình, hai pod này tự gia nhập cụm Raft sau khi vault-0 đã init. Chỉ cần unseal từng pod (3 key mỗi pod):

```bash
kubectl exec -it -n vault vault-1 -- vault operator unseal   # lặp 3 lần
kubectl exec -it -n vault vault-2 -- vault operator unseal   # lặp 3 lần
```

Kiểm tra (lệnh `vault login` hỏi root token, token được lưu trong pod `vault-0` cho các bước sau):

```bash
kubectl exec -it -n vault vault-0 -- sh -c 'vault login && vault operator raft list-peers'
```

Mong đợi: 3 node, một `leader` và hai `follower`. Cả 3 pod phải `1/1 Ready`.

## 4. Bật audit device (làm ngay, trước mọi thứ khác)

```bash
kubectl exec -it -n vault vault-0 -- vault audit enable file file_path=/vault/audit/vault_audit.log
```

Từ đây mọi request đều được ghi lại. Nên gom log này về hệ thống log tập trung.

## 5. Bật Kubernetes auth

```bash
kubectl exec -it -n vault vault-0 -- sh -c '
vault auth enable kubernetes
vault write auth/kubernetes/config kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"
'
```

Chart đã tạo sẵn ClusterRoleBinding `auth-delegator` cho ServiceAccount của Vault nên không cần thêm token reviewer.

## 6. Policy và role cho VCO

VCO đăng nhập Vault bằng ServiceAccount nằm **trong namespace của từng CR** (không phải ServiceAccount của chính operator).
Chart `pg-main-vault` tạo ServiceAccount `vault-config` trong namespace `pg-main-vault`, nên role chỉ ràng buộc đúng cặp đó.

`policy-admin` chỉ được quản lý đúng phạm vi mà chart `pg-main-vault` dùng, và **không** có quyền xin cert
(`pki/pg/issue/*`, `pki/pg/sign/*`), nên VCO bị chiếm cũng không tự tạo được cert đăng nhập Postgres.

```bash
kubectl exec -it -n vault vault-0 -- sh -c '
vault policy write policy-admin - <<EOF
path "sys/mounts"                     { capabilities = ["read", "list"] }
path "sys/mounts/pki/pg"              { capabilities = ["create", "read", "update", "delete"] }
path "sys/mounts/pki/pg/tune"         { capabilities = ["read", "update"] }
path "pki/pg/roles/*"                 { capabilities = ["create", "read", "update", "delete", "list"] }
path "sys/policies/acl/pg-main-*"     { capabilities = ["create", "read", "update", "delete"] }
path "auth/kubernetes/role/pg-main-*" { capabilities = ["create", "read", "update", "delete"] }
EOF

vault write auth/kubernetes/role/policy-admin \
  bound_service_account_names=vault-config \
  bound_service_account_namespaces=pg-main-vault \
  policies=policy-admin \
  ttl=15m
'
```

Lưu ý bảo mật: ai tạo được pod với ServiceAccount `vault-config` là có `policy-admin`, mà `policy-admin` ghi được policy
`pg-main-*`, tức về thực chất rất gần quyền admin Vault. Namespace `pg-main-vault` không được chạy workload nào khác
và chỉ quản trị viên được tạo pod ở đó.

Nếu sau này CR của VCO báo lỗi tạo token, kiểm tra ClusterRole của operator có quyền `create` trên `serviceaccounts/token`.

## 7. Dán CA của Vault và sync `pg-main-vault`

1. Lấy CA của Vault rồi dán vào `vault.caCert` trong `values/pg-main.yaml`, commit và push:

```bash
kubectl get secret vault-ca -n vault -o jsonpath='{.data.tls\.crt}' | base64 -d
```

2. Áp Application rồi sync thủ công trong Argo CD (Application này nằm ngoài `apps` có chủ đích,
   vì Application gốc chờ mọi Application con Healthy mà Application chưa sync thì không bao giờ Healthy):

```bash
kubectl apply -f apps-phase2/pg-main-vault.yaml
```

   Chart tạo ServiceAccount `vault-config`, ConfigMap `vault-ca`
   (cho operator VCO tin TLS của Vault) và các CR: mount `pki/pg`, PKI role, policy, auth role.
3. Kiểm tra mọi CR báo thành công (cột `Ready` hoặc condition `ReconcileSuccessful`):

```bash
kubectl get secretenginemount,pkisecretenginerole,policy,kubernetesauthenginerole -n pg-main-vault
```

## 8. Ký intermediate CA và sync `pg-main`

1. Tạo CSR cho intermediate (khóa riêng sinh và ở lại trong Vault):

```bash
kubectl exec -it -n vault vault-0 -- vault write -field=csr pki/pg/intermediate/generate/internal \
  common_name="Postgres Intermediate CA" key_type=ec key_bits=256 > pg-intermediate.csr
```

2. Mang CSR sang máy offline giữ root CA, ký với `CA:TRUE, pathlen:0`, thời hạn vài năm.
3. Nạp cert đã ký vào Vault (file gồm cert intermediate, nối thêm cert root):

```bash
kubectl cp pg-intermediate-signed.pem vault/vault-0:/tmp/pg-intermediate-signed.pem
kubectl exec -it -n vault vault-0 -- vault write pki/pg/intermediate/set-signed certificate=@/tmp/pg-intermediate-signed.pem
```

4. Dán **chuỗi đầy đủ: intermediate rồi root** vào `postgres.clientCaChain` trong `values/pg-main.yaml`, commit và push.
   Postgres cần cả hai để xác minh client cert, chỉ có intermediate là không đủ.
5. Áp Application rồi sync thủ công trong Argo CD:

```bash
kubectl apply -f apps-phase2/pg-main.yaml
```

   Thứ tự bên trong: Secret CA, ServiceAccount, RBAC, Issuer, Certificate (chờ Ready), rồi mới tới Cluster.

## 9. Kiểm tra rồi thu hồi root token

Kiểm tra hạ tầng:

```bash
kubectl get certificate,issuer -n pg-main     # pg-main-replication READY=True, Issuer Ready
kubectl get cluster -n pg-main                # Cluster in healthy state, 3 instance
```

Thử đăng nhập bằng cert (trong `vault-0`, đã login bằng root token):

1. Xin cert thử 10 phút, chép `certificate` và `private_key` thành `tls.crt`, `tls.key` trên máy bạn (`chmod 600 tls.key`):

```bash
kubectl exec -it -n vault vault-0 -- vault write -format=json pki/pg/issue/app-migrator common_name=app_migrator.test ttl=10m
```

2. Kết nối (verify-ca vì chứng chỉ server không có SAN `localhost`):

```bash
kubectl get secret pg-main-ca -n pg-main -o jsonpath='{.data.ca\.crt}' | base64 -d > server-ca.crt
kubectl port-forward -n pg-main svc/pg-main-rw 5432:5432 &
psql "host=localhost dbname=app user=app_migrator sslmode=verify-ca sslrootcert=server-ca.crt sslcert=tls.crt sslkey=tls.key" -c "select current_user"
```

Mong đợi: `app_migrator`. Log Postgres có dòng `connection authenticated` kèm `identity="app_migrator.test"`, đây là
chỗ truy ngược job hoặc pod từ cert.

3. Thử trường hợp phải bị từ chối: `vault write pki/pg/issue/app-migrator common_name=other.test` phải lỗi
   (CN không nằm trong `allowed_domains` của role).

Sau khi xác nhận xong, thu hồi root token:

```bash
kubectl exec -it -n vault vault-0 -- vault token revoke <root-token>
```

Khi cần quyền root lại (sự cố), tạo root token tạm bằng `vault operator generate-root` với đủ 3 unseal key,
dùng xong thu hồi ngay.

---

# Vận hành định kỳ

## Vault restart (cập nhật, node chết, pod bị đẩy đi)

Pod khởi động lại sẽ ở trạng thái sealed. Unseal pod đó bằng 3 key như bước 2. Hai node còn lại vẫn phục vụ nên Vault không ngừng hoạt động.
Nếu cả 3 pod restart cùng lúc, hệ thống không cấp được cert/secret cho đến khi unseal xong ít nhất một node.

## Cert `vault-tls` được cert-manager gia hạn (mỗi ~60 ngày)

Vault nạp lại cert khi nhận SIGHUP, **không cần restart và không cần unseal**:

```bash
for p in vault-0 vault-1 vault-2; do kubectl exec -n vault $p -- kill -HUP 1; done
```

Kiểm tra bằng cách xem ngày hết hạn của cert mà Vault đang phục vụ (`openssl s_client -connect ... | openssl x509 -noout -enddate`).

## Việc nên lên lịch

- Gia hạn cert `vault-tls` và gửi SIGHUP (như trên).
- Intermediate CA hết hạn: tạo CSR mới, ký lại bằng root offline, `set-signed`, cập nhật `postgres.clientCaChain`
  (giữ cả CA cũ lẫn mới trong giai đoạn chuyển tiếp) rồi sync `pg-main`. CNPG tự nạp lại nhờ label `cnpg.io/reload`.
- CA nội bộ `vault-ca` (5 năm) đổi: cập nhật `vault.caCert` và sync cả `pg-main-vault` lẫn `pg-main`.
- Diễn tập unseal định kỳ để chắc chắn đủ người giữ key còn liên lạc được.
- Khi có máy thứ hai: dựng Vault transit và chuyển sang auto-unseal bằng seal migration (`vault operator unseal -migrate`).
