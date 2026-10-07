#!/usr/bin/env bash
# ghcr-login.sh — Đăng nhập GitHub Container Registry (ghcr.io)
set -euo pipefail

REGISTRY="ghcr.io"

# --- 1. Lấy GitHub username ---
if [[ -z "${GITHUB_USERNAME:-}" ]]; then
  read -rp "GitHub username: " GITHUB_USERNAME
fi

if [[ -z "${GITHUB_USERNAME}" ]]; then
  echo "GITHUB_USERNAME không được để trống." >&2
  exit 1
fi

# --- 2. Lấy PAT (không hiển thị) ---
if [[ -z "${PAT:-}" ]]; then
  read -rsp "GitHub PAT (write:packages): " PAT
  echo  # xuống dòng sau khi nhập ẩn
fi

if [[ -z "${PAT}" ]]; then
  echo "PAT không được để trống." >&2
  exit 1
fi

# --- 3. Đăng nhập ---
echo "Đang đăng nhập vào ${REGISTRY} với user '${GITHUB_USERNAME}'..."
if printf '%s' "${PAT}" | docker login "${REGISTRY}" -u "${GITHUB_USERNAME}" --password-stdin; then
  echo "Đăng nhập thành công."
else
  echo "Đăng nhập thất bại. Kiểm tra lại username/PAT và scope 'write:packages'." >&2
  exit 1
fi

# --- 4. (Tùy chọn) Xóa PAT khỏi biến môi trường sau khi dùng ---
unset PAT