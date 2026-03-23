# stockbot-long-backend-k8s-infra

基礎設施設定 repo，管理所有「平台層」服務的 Helm values 和 K8s 資源。

## 架構總覽

```
Go Echo App + MariaDB + ELK + Fluent Bit + Prometheus + Grafana + ArgoCD
全部跑在 K3d（K3s in Docker）上，本地與線上統一流程
拆成三個 Git Repo 管理：
  stockbot-long-backend / stockbot-long-backend-k8s-manifests / stockbot-long-backend-k8s-infra
```

### 三個 Repo 的分工

| Repo | 存放內容 | 變更頻率 |
|------|---------|---------|
| `stockbot-long-backend` | Go 程式碼、Dockerfile、CI/CD | 每天（開發者） |
| `stockbot-long-backend-k8s-manifests` | Deployment、Service、Ingress、HPA 等 YAML | CI 自動改 image tag / DevOps 手動調 |
| **`stockbot-long-backend-k8s-infra`（本 repo）** | MariaDB、ES、Kibana、Fluent Bit、Prometheus、Grafana、Ingress Controller、ArgoCD | 極低（DevOps/SRE） |

### 完整 CI/CD 流程

```
開發者 push code → stockbot-long-backend repo
    ▼
GitHub Actions（CI）
  ├── go test → docker build → push image 到 GHCR
    ▼
CI 去改 stockbot-long-backend-k8s-manifests repo 的 image tag
    ▼
ArgoCD 偵測到變更 → 自動 sync 部署到 K8s
    ▼
Pod 跑起來
  ├── stdout JSON log → Fluent Bit → Elasticsearch → Kibana 查詢
  └── /metrics endpoint → Prometheus 定期拉取 → Grafana Dashboard
```

---

## 使用方式

### 前置條件

需要先安裝以下工具：

| 工具 | 安裝方式 |
|------|---------|
| Docker | Linux: `curl -fsSL https://get.docker.com \| sh`；WSL2: 安裝 Docker Desktop |
| K3d | `curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh \| bash` |
| kubectl | `curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && chmod +x kubectl && sudo mv kubectl /usr/local/bin/` |
| Helm | `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \| bash` |

加入 Helm Repos：

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add fluent https://fluent.github.io/helm-charts
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
```

### 最低硬體需求

| 項目 | 最低需求 | 建議 |
|------|---------|------|
| CPU | 4 核 | 8 核以上 |
| RAM | 8 GB | 16 GB |
| Disk | 60 GB | 100 GB |
| OS | Ubuntu 22.04+ / WSL2 | - |

### 快速開始

```bash
# 1. 複製密碼範本並填入密碼
cp .env.example .env
vim .env

# 2. 建立 K3d cluster
./k3d/create-cluster.sh

# 3. 一鍵安裝所有基礎設施
./install-all.sh

# 4. 設定 hosts（讓瀏覽器能用 .local 域名存取）
# Linux / WSL2
sudo tee -a /etc/hosts << 'EOF'
127.0.0.1  myapp.local grafana.local kibana.local argocd.local
EOF
# Windows（WSL2 使用者也要改，因為瀏覽器跑在 Windows 上）
# 用管理員身份編輯 C:\Windows\System32\drivers\etc\hosts
# 加入：127.0.0.1  myapp.local grafana.local kibana.local argocd.local
```

### 重置環境

```bash
k3d cluster delete mylab
./k3d/create-cluster.sh
./install-all.sh
```

---

## 使用前需要修改的地方

> ⚠️ **只需要修改 `.env` 一個檔案，所有密碼和設定都在這裡統一管理。**

| 變數 | 必填 | 說明 |
|------|:----:|------|
| `MARIADB_ROOT_PASSWORD` | ✅ | MariaDB root 密碼 |
| `MARIADB_PASSWORD` | ✅ | myapp 使用者的 DB 密碼 |
| `GRAFANA_PASSWORD` | ✅ | Grafana Web UI 登入密碼（帳號: admin） |
| `ES_PASSWORD` | ✅ | Elasticsearch / Kibana 登入密碼（帳號: elastic） |
| `ARGOCD_REPO_URL` | ✅ | manifest repo 的 Git URL |
| `ARGOCD_PASSWORD` | ✅ | ArgoCD Web UI 登入密碼（帳號: admin） |
| `ACME_EMAIL` | 選填 | Let's Encrypt 憑證申請用 email（正式環境才需要） |

以下是可選修改（根據需求調整，直接改 YAML 檔案）：

| 檔案 | 可調整項目 | 預設值 |
|------|-----------|--------|
| `argocd/application.yaml` | `spec.source.path` | `base` |
| `mariadb/values.yaml` | `auth.database`、`auth.username` | `myapp` |
| `mariadb/values.yaml` | `primary.persistence.size` | `10Gi` |
| `elastic/elasticsearch.yaml` | `spec.version` | `8.12.0` |
| `elastic/elasticsearch.yaml` | `volumeClaimTemplates.storage` | `20Gi` |
| `monitoring/values.yaml` | `prometheus.prometheusSpec.retention` | `7d` |
| `monitoring/values.yaml` | `prometheus.prometheusSpec.storageSpec.storage` | `10Gi` |
| `ingress/*.yaml` | `host` 域名 | `grafana.local`、`kibana.local`、`argocd.local` |

---

## 目錄結構

```
stockbot-long-backend-k8s-infra/
├── k3d/
│   └── create-cluster.sh       # K3d cluster 建立腳本
├── mariadb/
│   └── values.yaml             # MariaDB 設定（不含密碼）
├── elastic/
│   ├── elasticsearch.yaml      # Elasticsearch CRD
│   └── kibana.yaml             # Kibana CRD
├── fluent-bit/
│   └── values.yaml             # Fluent Bit 的 Helm chart 設定
├── monitoring/
│   └── values.yaml             # Prometheus + Grafana 設定（不含密碼）
├── ingress/
│   ├── values.yaml             # Nginx Ingress Controller 設定
│   ├── grafana-ingress.yaml    # Grafana 的 Ingress 規則
│   ├── kibana-ingress.yaml     # Kibana 的 Ingress 規則
│   └── argocd-ingress.yaml     # ArgoCD 的 Ingress 規則
├── argocd/
│   └── application.yaml        # 指向 manifest repo，讓 ArgoCD 監聽
├── cert-manager/
│   └── clusterissuer.yaml      # 正式環境 TLS 憑證
├── install-all.sh              # 一鍵安裝（含跳過機制，可重複執行）
├── .env.example                # 所有密碼與設定的範本（不含真實值，安全地 commit）
└── .gitignore                  # 排除 .env（真實密碼永遠不進 Git）
```

---

## 密碼處理策略

這個 repo 可以安全地設成 **public**，因為：

1. **所有密碼和環境設定**都集中在 `.env` 一個檔案（被 `.gitignore` 排除，不進 Git）
2. YAML 裡使用佔位符（如 `__ARGOCD_REPO_URL__`），由 `install-all.sh` 在 apply 時用 `sed` 替換
3. Helm 密碼透過 `--set` 注入，不寫在 values.yaml 裡
4. ES 密碼透過預建 K8s Secret 注入，ECK 直接採用而不隨機產生
5. ArgoCD 密碼透過 bcrypt hash patch 覆寫
6. myapp 的 DB Secret 也由 `install-all.sh` 建在 K8s 裡，不放在任何 Git repo

---

## 各檔案說明

### k3d/create-cluster.sh

建立名為 `mylab` 的 K3d cluster：1 個 server + 2 個 agent node。

```bash
k3d cluster create mylab \
  --servers 1 \                                          # control plane
  --agents 2 \                                           # worker nodes
  --port "80:80@loadbalancer" \                          # HTTP 映射到本機
  --port "443:443@loadbalancer" \                        # HTTPS 映射到本機
  --k3s-arg "--disable=traefik@server:0" \               # 停用 Traefik，改用 nginx
  --volume /tmp/k3d-storage:/var/lib/rancher/k3s/storage@all  # PVC 儲存
```

驗證：

```bash
kubectl get nodes
# 3 個 node 都是 Ready 就成功
```

### mariadb/values.yaml

MariaDB 的 Helm chart 客製化設定。密碼透過 `install-all.sh` 的 `--set` 注入，不寫在檔案裡。

重點設定：
- `auth.database` / `auth.username`：自動建立的 DB 和使用者（預設 `myapp`）
- `primary.persistence.size`：磁碟大小（預設 `10Gi`）
- `metrics.enabled`：啟用 Prometheus exporter
- `metrics.serviceMonitor.labels.release`：**必須**跟 Helm release name `monitoring` 一致

### elastic/elasticsearch.yaml

ECK（Elastic Cloud on Kubernetes）CRD，部署單節點 Elasticsearch。

重點設定：
- 開發環境用單節點（`count: 1`，ECK 自動處理 discovery）
- `xpack.security.http.ssl.enabled: false`：開發環境關閉 HTTP TLS
- `http.tls.selfSignedCertificate.disabled: true`：告訴 ECK 不產生 HTTP 層憑證
- `ES_JAVA_OPTS: "-Xms1g -Xmx1g"`：JVM heap 固定 1GB
- `memory: 2Gi`：ES 最低需要 2GB
- `storage: 20Gi`：索引儲存空間

### elastic/kibana.yaml

ECK CRD，部署 Kibana（ES 的 Web UI）。版本需跟 ES 一致。
透過 `elasticsearchRef.name: logs` 自動連接 ES。
`http.tls.selfSignedCertificate.disabled: true`：關閉 Kibana HTTPS，讓 HTTP Ingress 能正常存取。

### fluent-bit/values.yaml

Fluent Bit 以 DaemonSet 方式部署（每個 node 一個），讀取所有 container 的 log 並送到 ES。

處理流程：
1. **INPUT**：`tail` 監控 `/var/log/containers/*.log`
2. **FILTER (kubernetes)**：自動加上 pod_name、namespace 等 metadata，合併 JSON log
3. **FILTER (grep)**：排除系統 namespace 的 log（kube-system、elastic-system 等）
4. **OUTPUT**：送到 ES，每天一個 index（`myapp-logs-%Y.%m.%d`）

ES 密碼從環境變數 `${ES_PASSWORD}` 讀取，由安裝腳本從 `.env` 注入 K8s Secret。

### monitoring/values.yaml

kube-prometheus-stack 的 Helm values，一次安裝 Prometheus + Grafana + Alertmanager + Node Exporter。

重點設定：
- `grafana.persistence.enabled: true`：持久化 Dashboard 設定
- `prometheus.prometheusSpec.retention: 7d`：metrics 保留 7 天
- `serviceMonitorSelectorNilUsesHelmValues: false`：**必須設 false**，否則 Prometheus 找不到其他 namespace 的 ServiceMonitor

### ingress/values.yaml

Nginx Ingress Controller 的 Helm values。Ingress Controller 是 cluster 的「大門」，所有 Ingress 規則需要它來執行。

### ingress/grafana-ingress.yaml、kibana-ingress.yaml、argocd-ingress.yaml

Ingress 路由規則，將 `.local` 域名對應到各服務。

注意事項：
- **Kibana**：開發環境已關閉 Kibana HTTPS，不需要 `backend-protocol` annotation
- **ArgoCD**：需要 `backend-protocol: "HTTPS"` + `ssl-passthrough: "true"`，因為 ArgoCD 用同一個 port 處理 HTTPS 和 gRPC

### argocd/application.yaml

ArgoCD Application CRD，是本 repo 和 `stockbot-long-backend-k8s-manifests` repo 的「橋樑」。
告訴 ArgoCD：「去監聽 manifest repo，自動部署裡面的設定。」

重點設定：
- `source.repoURL`：從 `.env` 的 `ARGOCD_REPO_URL` 注入（佔位符 `__ARGOCD_REPO_URL__`）
- `source.path`：`base`（manifest repo 的目錄）
- `syncPolicy.automated.prune: true`：Git 裡刪了的資源，K8s 裡也自動刪
- `syncPolicy.automated.selfHeal: true`：手動改了 K8s 資源，自動改回 Git 定義的狀態

### cert-manager/clusterissuer.yaml

正式環境用。自動向 Let's Encrypt 申請免費 TLS 憑證，到期前自動續期。
本地開發（`.local` 域名）不需要。

使用前需額外安裝 cert-manager：

```bash
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true
```

---

## install-all.sh 安裝流程

腳本按以下順序安裝，已成功的步驟會自動跳過（可重複執行）：

| 步驟 | 元件 | 跳過條件 | 密碼來源 |
|------|------|---------|---------|
| 0/7 | Prometheus CRDs | CRD 已存在 | - |
| 1/7 | MariaDB + DB Secret | Pod Running | `.env` `MARIADB_*` |
| 2/7 | ECK + ES + Kibana | ES Pod Running | `.env` `ES_PASSWORD` |
| 3/7 | Fluent Bit | Pod Running | `.env` `ES_PASSWORD` |
| 4/7 | Prometheus + Grafana | Helm deployed | `.env` `GRAFANA_PASSWORD` |
| 5/7 | ArgoCD | Pod Running | `.env` `ARGOCD_PASSWORD`（bcrypt hash 覆寫） |
| 6/7 | Ingress Controller + 規則 | Helm deployed | - |
| 7/7 | ArgoCD Application | -（每次 apply） | `.env` `ARGOCD_REPO_URL`（sed 佔位符替換） |

所有密碼從 `.env` 讀取，透過 `--set` 注入 Helm、`kubectl create secret` 建立、或 `sed` 佔位符替換。

---

## 驗證與存取

### 確認所有 Pod

```bash
kubectl get pods -A
# 所有 Pod 都應該是 Running
# CrashLoopBackOff = 啟動就 crash，ImagePullBackOff = image 拉不下來
```

### 確認 Ingress

```bash
kubectl get ingress -A
# 每個 Ingress 的 ADDRESS 欄位不能是空的
```

### 存取服務

| 服務 | 網址 | 帳號 / 密碼 |
|------|------|-------------|
| App | http://myapp.local | -（等 ArgoCD sync 完才有） |
| Grafana | http://grafana.local | admin / `.env` `GRAFANA_PASSWORD` |
| Kibana | http://kibana.local | elastic / `.env` `ES_PASSWORD` |
| ArgoCD | https://argocd.local | admin / `.env` `ARGOCD_PASSWORD` |

```bash
# 快速測試
curl -s -o /dev/null -w "%{http_code}" http://myapp.local/health   # 回 200 = OK
curl -s -o /dev/null -w "%{http_code}" http://grafana.local         # 回 200 或 302
```

### 驗證 Log（Kibana）

```bash
curl http://myapp.local/health
# 去 Kibana → Stack Management → Data Views → Create → myapp-logs-*
# 到 Discover 查看 log，可搜尋：status:200、method:GET
```

### 驗證 Metrics（Grafana）

在 Grafana 建 Dashboard，用這些 PromQL：

```promql
rate(myapp_http_requests_total[5m])                                           # QPS
histogram_quantile(0.99, rate(myapp_http_request_duration_seconds_bucket[5m])) # P99 延遲
rate(myapp_http_requests_total{status=~"5.."}[5m]) / rate(myapp_http_requests_total[5m])  # 錯誤率
myapp_db_connections_active                                                    # DB 連線數
```

---

## 常見問題排除

### Ingress 連不到

```bash
kubectl get pods -n ingress-nginx              # Controller 有在跑嗎？
kubectl get ingress -A                          # ADDRESS 有值嗎？
ping myapp.local                                # 解析到 127.0.0.1 嗎？
kubectl -n ingress-nginx logs -l app.kubernetes.io/name=ingress-nginx --tail=30

# 繞過 Ingress 直接測 Service（確認問題在哪層）
kubectl port-forward -n myapp svc/myapp 9999:80
curl http://localhost:9999/health
```

### Pod 一直 Pending

```bash
kubectl describe pod <pod-name> -n <namespace>
# 看 Events：Insufficient cpu/memory → 降低 requests 或加 node
```

### Prometheus 沒抓到 Metrics

```bash
kubectl get servicemonitor myapp -n myapp -o yaml | grep -A2 labels
# 確認 release: monitoring 存在（label 沒對上 Helm release name 是最常見原因）
```

### 實用指令

```bash
kubectl get pods -A                                    # 所有 Pod
kubectl logs <pod> -n <ns> -f                          # 即時看 log
kubectl exec -it <pod> -n <ns> -- /bin/sh              # 進入 Pod shell
kubectl rollout restart deployment myapp -n myapp      # 重啟所有 Pod
kubectl top pods -A                                    # 資源使用量
```
