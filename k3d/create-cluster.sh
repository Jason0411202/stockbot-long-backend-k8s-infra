#!/bin/bash
set -e
# set -e：任何指令失敗就停止腳本

k3d cluster create mylab \
  --servers 1 \
  --agents 2 \
  --port "80:80@loadbalancer" \
  --port "443:443@loadbalancer" \
  --k3s-arg "--disable=traefik@server:0" \
  --volume /tmp/k3d-storage:/var/lib/rancher/k3s/storage@all

echo "✅ K3d cluster 建立完成"
echo "驗證：kubectl get nodes"
