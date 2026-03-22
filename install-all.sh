#!/bin/bash
set -e

INFRA_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$INFRA_DIR"

# ─── 跳過檢查函式 ───
# 檢查某個 namespace 裡符合 label 的 pod 是否全部 Running 且 Ready
# 用法：pods_ready <namespace> <label-selector>
# 回傳：0 = 全部 ready，1 = 還沒 ready 或不存在
pods_ready() {
  local ns=$1 selector=$2
  local total ready
  total=$(kubectl -n "$ns" get pods -l "$selector" --no-headers 2>/dev/null | wc -l)
  [ "$total" -eq 0 ] && return 1
  ready=$(kubectl -n "$ns" get pods -l "$selector" --no-headers 2>/dev/null | grep -c "Running")
  [ "$ready" -eq "$total" ]
}

# 檢查某個 Helm release 是否已經 deployed
# 用法：helm_deployed <namespace> <release-name>
helm_deployed() {
  local ns=$1 name=$2
  helm status "$name" -n "$ns" 2>/dev/null | grep -q "STATUS: deployed"
}

# ─── 載入密碼 ───
if [ ! -f .env ]; then
  echo "❌ 找不到 .env！請先：cp .env.example .env 然後填入密碼"
  exit 1
fi
source .env
# source .env 把 KEY=VALUE 載入成 shell 環境變數

for var in MARIADB_ROOT_PASSWORD MARIADB_PASSWORD GRAFANA_PASSWORD; do
  if [ -z "${!var}" ]; then
    echo "❌ .env 裡的 $var 是空的，請填入密碼"
    exit 1
  fi
done
# ${!var} 是 bash 間接引用：var="XXX" → ${!var} = $XXX

echo "✅ 密碼已從 .env 載入"


echo ""
echo "========================================="
echo "  [0/7] 預先安裝 Prometheus CRDs"
echo "========================================="
# MariaDB 的 ServiceMonitor 需要 monitoring.coreos.com CRD
# 但 Prometheus 在步驟 4 才裝，所以先單獨裝 CRD
if kubectl get crd servicemonitors.monitoring.coreos.com &>/dev/null; then
  echo "⏭️  Prometheus CRDs 已存在，跳過"
else
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
  helm pull prometheus-community/kube-prometheus-stack --untar --untardir /tmp/prom-crds 2>/dev/null || true
  kubectl apply --server-side -f /tmp/prom-crds/kube-prometheus-stack/charts/crds/crds/ 2>/dev/null || \
    kubectl apply --server-side -f /tmp/prom-crds/kube-prometheus-stack/crds/ 2>/dev/null || true
  rm -rf /tmp/prom-crds
  echo "✅ Prometheus CRDs 已安裝"
fi


echo ""
echo "========================================="
echo "  [1/7] 安裝 MariaDB + 建立 App DB Secret"
echo "========================================="

if pods_ready myapp "app.kubernetes.io/name=mariadb"; then
  echo "⏭️  MariaDB 已在運行，跳過"
else
  kubectl create namespace myapp --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install mariadb bitnami/mariadb \
    --namespace myapp \
    -f mariadb/values.yaml \
    --set auth.rootPassword="$MARIADB_ROOT_PASSWORD" \
    --set auth.password="$MARIADB_PASSWORD" \
    --wait --timeout 5m
  # --set 從環境變數注入密碼，不會出現在任何 Git 檔案裡
  echo "✅ MariaDB 安裝完成"
fi

# DB Secret 每次都確保存在（冪等）
DB_DSN="myapp:${MARIADB_PASSWORD}@tcp(mariadb.myapp.svc.cluster.local:3306)/myapp?parseTime=true"
kubectl -n myapp create secret generic myapp-db \
  --from-literal=dsn="$DB_DSN" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "✅ DB Secret 已確認"


echo ""
echo "========================================="
echo "  [2/7] 安裝 ECK + Elasticsearch + Kibana"
echo "========================================="

if pods_ready elastic-system "elasticsearch.k8s.elastic.co/cluster-name=logs"; then
  echo "⏭️  Elasticsearch 已在運行，跳過"
else
  kubectl create -f https://download.elastic.co/downloads/eck/2.11.1/crds.yaml 2>/dev/null || true
  kubectl apply -f https://download.elastic.co/downloads/eck/2.11.1/operator.yaml
  echo "等待 ECK Operator 啟動..."
  kubectl -n elastic-system wait --for=condition=Ready pod -l control-plane=elastic-operator --timeout=120s
  kubectl apply -f elastic/elasticsearch.yaml
  kubectl apply -f elastic/kibana.yaml
  echo "等待 Elasticsearch 啟動（可能要 2-3 分鐘）..."
  sleep 30
  kubectl -n elastic-system wait --for=jsonpath='{.status.health}'=green elasticsearch/logs --timeout=300s || \
    echo "⚠️  ES 還沒完全 ready，先繼續"
  echo "✅ ELK 安裝完成"
fi


echo ""
echo "========================================="
echo "  [3/7] 取得 ES 密碼 + 安裝 Fluent Bit"
echo "========================================="

ES_PASSWORD=$(kubectl -n elastic-system get secret logs-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)

if pods_ready logging "app.kubernetes.io/name=fluent-bit"; then
  echo "⏭️  Fluent Bit 已在運行，跳過"
else
  echo "ES Password: $ES_PASSWORD"
  kubectl create namespace logging --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n logging create secret generic fluent-bit-es-password \
    --from-literal=ES_PASSWORD="$ES_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install fluent-bit fluent/fluent-bit \
    --namespace logging \
    -f fluent-bit/values.yaml \
    --set "env[0].name=ES_PASSWORD" \
    --set "env[0].valueFrom.secretKeyRef.name=fluent-bit-es-password" \
    --set "env[0].valueFrom.secretKeyRef.key=ES_PASSWORD" \
    --wait --timeout 3m
  echo "✅ Fluent Bit 安裝完成"
fi


echo ""
echo "========================================="
echo "  [4/7] 安裝 Prometheus + Grafana"
echo "========================================="

if helm_deployed monitoring monitoring; then
  echo "⏭️  Prometheus + Grafana 已部署，跳過"
else
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    -f monitoring/values.yaml \
    --set grafana.adminPassword="$GRAFANA_PASSWORD" \
    --wait --timeout 5m
  # Grafana 密碼也從 .env 注入
  echo "✅ Prometheus + Grafana 安裝完成"
fi


echo ""
echo "========================================="
echo "  [5/7] 安裝 ArgoCD"
echo "========================================="

if pods_ready argocd "app.kubernetes.io/name=argocd-server"; then
  echo "⏭️  ArgoCD 已在運行，跳過"
else
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  # --server-side 避免 CRD annotation 超過 262144 bytes 限制
  kubectl apply --server-side -n argocd \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  echo "等待 ArgoCD 啟動..."
  sleep 30
  kubectl -n argocd wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-server --timeout=180s || true
  echo "✅ ArgoCD 安裝完成"
fi
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "尚未產生")


echo ""
echo "========================================="
echo "  [6/7] 安裝 Ingress Controller + Ingress 規則"
echo "========================================="

if helm_deployed ingress-nginx ingress-nginx; then
  echo "⏭️  Ingress Controller 已部署，跳過安裝"
else
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx --create-namespace \
    -f ingress/values.yaml \
    --wait --timeout 3m
  kubectl -n ingress-nginx wait --for=condition=Ready pod -l app.kubernetes.io/name=ingress-nginx --timeout=120s || true
  echo "✅ Ingress Controller 安裝完成"
fi
# Ingress 規則每次都 apply（冪等，確保最新）
kubectl apply -f ingress/grafana-ingress.yaml
kubectl apply -f ingress/kibana-ingress.yaml
kubectl apply -f ingress/argocd-ingress.yaml
echo "✅ Ingress 規則已套用"


echo ""
echo "========================================="
echo "  [7/7] 註冊 ArgoCD Application"
echo "========================================="

kubectl apply -f argocd/application.yaml
echo "✅ ArgoCD 開始監聽 manifest repo"


echo ""
echo "========================================="
echo "  🎉 全部安裝完成！"
echo "========================================="
echo ""
echo "📌 請確認 hosts 已設定："
echo "   127.0.0.1  myapp.local grafana.local kibana.local argocd.local"
echo ""
echo "🌐 App:       http://myapp.local         （等 ArgoCD sync 完才有）"
echo "📊 Grafana:   http://grafana.local        帳號: admin / 密碼:（你在 .env 設的）"
echo "📋 Kibana:    http://kibana.local         帳號: elastic / 密碼: $ES_PASSWORD"
echo "🚀 ArgoCD:    https://argocd.local        帳號: admin / 密碼: $ARGOCD_PASS"
