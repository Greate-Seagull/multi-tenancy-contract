#Default context is root
FROM alpine:3.20

ARG KUBECTL_VERSION=1.31.0
ARG HELM_VERSION=3.16.2
# TARGETARCH sẽ tự động được buildx inject (amd64, arm64, v.v.)
ARG TARGETARCH

# Cài đặt công cụ, bao gồm tini, yq, gettext (envsubst)
RUN apk add --no-cache \
      bash curl jq yq gettext ca-certificates postgresql-client tini \
    && curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
         -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
       | tar -xz -C /tmp \
    && mv /tmp/linux-${TARGETARCH}/helm /usr/local/bin/helm \
    && chmod +x /usr/local/bin/helm \
    && rm -rf /tmp/linux-${TARGETARCH} \
    && adduser -D -u 10001 deployer

# Script và entrypoint cần 0755 (thực thi)
COPY --chmod=0755 test/deploy/bootstrap/ /opt/deploy/scripts/
COPY --chmod=0755 test/deploy/entrypoint.sh /opt/deploy/entrypoint.sh
COPY --chmod=0755 deploy/migrate-database.sh /opt/deploy/scripts/migrate-database.sh
COPY --chmod=0755 deploy/charts/ /opt/deploy/charts/
# File cấu hình và charts chỉ cần 0644 (đọc)
COPY --chmod=0644 test/deploy/args/values.yaml /opt/deploy/scripts/values.yaml

USER deployer
ENV HOME=/tmp \
    KUBECONFIG=/home/deployer/.kube/config
WORKDIR /tmp

# Dùng tini làm PID 1 để xử lý tín hiệu và dọn dẹp tiến trình con
ENTRYPOINT ["/sbin/tini", "--", "/opt/deploy/entrypoint.sh"]