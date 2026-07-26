<!--
Licensed to the Apache Software Foundation (ASF) under one
or more contributor license agreements.  See the NOTICE file
distributed with this work for additional information
regarding copyright ownership.  The ASF licenses this file
to you under the Apache License, Version 2.0 (the
"License"); you may not use this file except in compliance
with the License.  You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing,
software distributed under the License is distributed on an
"AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, either express or implied.  See the License for the
specific language governing permissions and limitations
under the License.
-->

# Nereus v0.1.0 两节点性能测试操作手册

本文是服务器上的最终执行顺序。固定运行身份如下：

- Helm release：`nereus`
- Kubernetes namespace：`pulsar`
- Pulsar cluster：`beijing-1-benchmark`
- Pulsar 主节点：`denovo-r730-1`，标签 `workload=pulsar`
- 对象存储节点：`denovo-win-1`，标签
  `workload=apps,nereus-object-store=true`
- A–E 使用同一份 campaign identity 和 Secret
- 每个 Stage 测试后执行冷重置，再安装下一组

`deploy-nereus-stage.sh` 内部执行 `helm install`。不要再额外执行一遍
`helm install`。`reset-nereus-benchmark-stage.sh --execute` 内部执行
`helm uninstall`。不要提前手工 uninstall 或删除 PV。

## 1. 每次登录控制节点时设置环境

```bash
cd /root/pulsar-helm-chart

export NEREUS_EXPECTED_CONTEXT="$(kubectl config current-context)"
export NEREUS_RELEASE='nereus'
export NEREUS_NAMESPACE='pulsar'
export NEREUS_CLUSTER='beijing-1-benchmark'
export NEREUS_SECRET_NAME='pulsar-nereus-secrets'
export NEREUS_CAMPAIGN_VALUES='/root/denovo/nereus-campaign/values-campaign.yaml'
export NEREUS_OPERATOR_EVIDENCE_FILE='/root/denovo/nereus-campaign/values-campaign.operator-evidence.txt'
export NEREUS_RESULTS_ROOT='/root/denovo/nereus-campaign/results'
```

检查当前上下文和固定身份：

```bash
printf 'context=%s\nrelease=%s\nnamespace=%s\ncluster=%s\n' \
  "${NEREUS_EXPECTED_CONTEXT}" \
  "${NEREUS_RELEASE}" \
  "${NEREUS_NAMESPACE}" \
  "${NEREUS_CLUSTER}"
```

如果已经用其他 release 或 namespace 生成过 campaign，不能复用。检查：

```bash
test ! -f "${NEREUS_OPERATOR_EVIDENCE_FILE}" || \
  grep -E '^(kubernetesContext|kubernetesNamespace|helmRelease|pulsarCluster)=' \
    "${NEREUS_OPERATOR_EVIDENCE_FILE}"
```

正确结果必须包含：

```text
kubernetesNamespace=pulsar
helmRelease=nereus
pulsarCluster=beijing-1-benchmark
```

## 2. 准备节点标签

```bash
kubectl label node denovo-r730-1 workload=pulsar --overwrite
kubectl label node denovo-win-1 \
  workload=apps \
  nereus-object-store=true \
  --overwrite

kubectl get nodes -L workload,nereus-object-store -o wide
```

部署前置检查要求恰好一个可调度 Ready 节点匹配每组标签。精确检查对象
存储节点：

```bash
kubectl get nodes \
  -l 'workload=apps,nereus-object-store=true' \
  -o json |
jq '
  [.items[]
    | select(.spec.unschedulable != true)
    | select(any(.status.conditions[]?;
        .type == "Ready" and .status == "True"))]
  | {count: length, nodes: [.[].metadata.name]}
'
```

`count` 必须为 `1`，节点必须是 `denovo-win-1`。如果节点被有意设置
taint，使用与 Chart toleration 一致的值：

```bash
kubectl taint node denovo-r730-1 dedicated=pulsar:NoSchedule --overwrite
kubectl taint node denovo-win-1 dedicated=apps:NoSchedule --overwrite
```

## 3. 准备 containerd 镜像

三个 Pulsar/Nereus 镜像使用 `imagePullPolicy: Never`。在没有私有镜像
仓库时，把同一份校验过的 Pulsar 镜像归档导入两个 Kubernetes 节点的
`k8s.io` containerd namespace。

Oxia 只运行在 `workload=pulsar` 节点。在 `denovo-r730-1` 执行：

```bash
nerdctl --namespace k8s.io pull oxia/oxia:0.16.7
nerdctl --namespace k8s.io images --digests --no-trunc oxia/oxia:0.16.7
```

SeaweedFS 只运行在 `denovo-win-1`。错误

```text
Container image "nereus-benchmark/seaweedfs:4.29-amd64" is not present
with pull policy of Never
```

表示该精确标签不在对象存储节点的 `k8s.io` namespace。即使主节点有
该镜像，或者镜像位于 containerd 的 `default` namespace，Kubelet 也
无法使用。

### 3.1 对象存储节点可以访问 Docker Hub

在 `denovo-win-1` 执行：

```bash
nerdctl --namespace k8s.io pull \
  --platform linux/amd64 \
  chrislusf/seaweedfs:4.29

nerdctl --namespace k8s.io tag \
  chrislusf/seaweedfs:4.29 \
  nereus-benchmark/seaweedfs:4.29-amd64

nerdctl --namespace k8s.io images \
  --digests --no-trunc |
grep -E 'chrislusf/seaweedfs|nereus-benchmark/seaweedfs'
```

必须能看到：

```text
nereus-benchmark/seaweedfs  4.29-amd64
```

记录本次解析到的完整 digest。不要在 A–E 之间重新拉取可变 tag。

### 3.2 对象存储节点不能直接拉取

在能够拉取镜像的构建节点执行：

```bash
mkdir -p /root/denovo/images

nerdctl --namespace k8s.io pull \
  --platform linux/amd64 \
  chrislusf/seaweedfs:4.29

nerdctl --namespace k8s.io tag \
  chrislusf/seaweedfs:4.29 \
  nereus-benchmark/seaweedfs:4.29-amd64

nerdctl --namespace k8s.io save \
  -o /root/denovo/images/seaweedfs-4.29-amd64.tar \
  nereus-benchmark/seaweedfs:4.29-amd64

cd /root/denovo/images
sha256sum seaweedfs-4.29-amd64.tar \
  > seaweedfs-4.29-amd64.tar.sha256

scp \
  seaweedfs-4.29-amd64.tar \
  seaweedfs-4.29-amd64.tar.sha256 \
  root@denovo-win-1:/root/denovo/images/
```

在 `denovo-win-1` 执行：

```bash
cd /root/denovo/images
sha256sum -c seaweedfs-4.29-amd64.tar.sha256

nerdctl --namespace k8s.io load \
  -i seaweedfs-4.29-amd64.tar

nerdctl --namespace k8s.io images \
  --digests --no-trunc |
grep 'nereus-benchmark/seaweedfs'
```

镜像导入后 Kubelet 通常会自动重试。如果 Pod 仍未恢复，先查看：

```bash
kubectl -n pulsar get pods -o wide | grep seaweedfs
kubectl -n pulsar describe pod <SEAWEEDFS_POD>
```

不要在镜像仍缺失时反复执行新的 Helm install。

镜像构建 manifest 中的 `APACHE_IMAGE_ID`、`NEREUS_IMAGE_ID` 和
`NEREUS_ADMIN_IMAGE_ID` 是 OCI manifest/target digest。containerd CRI
向 Kubernetes Pod 状态报告的是 image config ID，两者都是 SHA-256，
但数值不同。部署脚本会先通过 `nerdctl image inspect --mode native`
证明本地 tag 的 OCI target 与冻结 manifest 一致，再把该 target 映射到
Docker-compatible inspect 的 config ID，最后用 config ID 校验 Pod。
不要直接拿 `nerdctl images` 的 DIGEST 列与 Pod `imageID` 比较。

## 4. 准备静态存储

在控制节点应用现有 PV：

```bash
kubectl apply -f /root/denovo/bookie_index_pv.yaml
kubectl apply -f /root/denovo/ledger_pv.yaml
kubectl apply -f /root/denovo/zk_pv.yaml
kubectl apply -f /root/denovo/journal_pv.yaml
kubectl apply -f /root/denovo/prometheus_pv.yaml
```

在 `denovo-win-1` 确保 SeaweedFS 的实际目录已经创建，并与
`local-seaweedfs-pv.example.yaml` 中的 `spec.local.path` 一致。然后在
控制节点执行：

```bash
cd /root/pulsar-helm-chart

kubectl apply \
  -f examples/nereus-benchmark/storage/local-seaweedfs-storage-class.yaml
kubectl apply \
  -f examples/nereus-benchmark/storage/local-seaweedfs-pv.example.yaml
```

检查：

```bash
kubectl get storageclass \
  local-zk \
  local-journal-1 \
  local-ledger \
  local-bookie-index \
  local-seaweedfs \
  local-prometheus-1 \
  local-grafana

kubectl get pv \
  -o custom-columns='NAME:.metadata.name,CLASS:.spec.storageClassName,PHASE:.status.phase,CAPACITY:.spec.capacity.storage,NODE:.spec.nodeAffinity.required.nodeSelectorTerms[*].matchExpressions[*].values[*]'
```

Oxia 每次冷安装需要至少三个 `local-zk`、47 Gi、`Available` 的 PV。

## 5. 生成 campaign identity

只在 Stage A 之前生成一次，A–E 共用。先确认镜像 manifest 和
sidecar：

```bash
IMAGE_MANIFEST='/root/denovo/nereus/nereus/build/performance-images/pulsar-5.0.0-M1-amd64.env'

ls -l "${IMAGE_MANIFEST}" "${IMAGE_MANIFEST}.sha256"
mkdir -p /root/denovo/nereus-campaign
```

如果目标目录中已经存在旧 campaign，先检查其 operator evidence。
release 或 namespace 不一致时将旧文件归档；生成脚本不会覆盖它们。

生成新 campaign：

```bash
cd /root/pulsar-helm-chart

./scripts/prepare-nereus-campaign-values.sh \
  /root/denovo/nereus-campaign/values-campaign.yaml \
  "${IMAGE_MANIFEST}"
```

验证：

```bash
grep -E \
  '^(kubernetesContext|kubernetesNamespace|helmRelease|pulsarCluster)=' \
  "${NEREUS_OPERATOR_EVIDENCE_FILE}"
```

必须得到当前 context、`pulsar`、`nereus` 和 `beijing-1-benchmark`。

## 6. 创建 namespace 和 Secret

只在 Stage A 之前执行一次。不要在 A–E 之间轮换 Secret。

```bash
kubectl create namespace "${NEREUS_NAMESPACE}" \
  --dry-run=client -o yaml |
kubectl apply -f -

SEAWEEDFS_ACCESS_KEY="nereus$(openssl rand -hex 8)"
SEAWEEDFS_SECRET_KEY="$(openssl rand -hex 32)"
NEREUS_BK_PASSWORD="$(openssl rand -hex 32)"

kubectl -n "${NEREUS_NAMESPACE}" create secret generic \
  "${NEREUS_SECRET_NAME}" \
  --from-literal=access-key="${SEAWEEDFS_ACCESS_KEY}" \
  --from-literal=secret-key="${SEAWEEDFS_SECRET_KEY}" \
  --from-literal=bookkeeper-password="${NEREUS_BK_PASSWORD}" \
  --dry-run=client -o yaml |
kubectl apply -f -

unset SEAWEEDFS_ACCESS_KEY SEAWEEDFS_SECRET_KEY NEREUS_BK_PASSWORD
kubectl -n "${NEREUS_NAMESPACE}" describe secret "${NEREUS_SECRET_NAME}"
```

## 7. Chart 和集群前置检查

```bash
cd /root/pulsar-helm-chart

./scripts/test-nereus-render.sh
helm -n "${NEREUS_NAMESPACE}" list --all
kubectl -n "${NEREUS_NAMESPACE}" get secret "${NEREUS_SECRET_NAME}"
test -r "${NEREUS_CAMPAIGN_VALUES}"
test -r "${NEREUS_OPERATOR_EVIDENCE_FILE}"
```

旧 `beijing-1` 集群不能与性能基准同时运行。部署脚本还会拒绝已存在的
`pulsar/nereus` release 和上一 Stage 遗留的核心数据 PVC。

## 8. 部署并测试 Stage A

```bash
STAGE=A

./scripts/deploy-nereus-stage.sh "${STAGE}"
./scripts/verify-nereus-release.sh "${STAGE}"
```

部署成功后查看脚本创建的测试目标：

```bash
source "${NEREUS_RESULTS_ROOT}/deploy/latest.env"
printf 'tenant=%s\nnamespace=%s\ntopic=%s\n' \
  "${BENCHMARK_TENANT}" \
  "${BENCHMARK_NAMESPACE}" \
  "${BENCHMARK_TOPIC}"
```

运行 Stage A 性能测试。结束时先停止所有生产者和消费者。

## 9. 部署并测试 Stage B–E

每个 Stage 必须在上一 Stage 冷重置完成后安装。以 B 为例：

```bash
STAGE=B

./scripts/deploy-nereus-stage.sh "${STAGE}"
./scripts/activate-nereus-publications.sh "${STAGE}"
./scripts/run-object-store-contract.sh
./scripts/verify-nereus-release.sh "${STAGE}"
```

C、D、E 使用同样流程，只修改 `STAGE`：

```bash
STAGE=C
# 或 STAGE=D
# 或 STAGE=E
```

对应关系：

| Stage | Broker 与数据路径 |
| --- | --- |
| A | Apache Pulsar 基线 |
| B | Nereus dormant，原生 `bookkeeper` storage class |
| C | Nereus `BOOKKEEPER_WAL_ONLY` |
| D | Nereus `BOOKKEEPER_WAL_ASYNC_OBJECT` |
| E | Nereus `BOOKKEEPER_WAL_SYNC_OBJECT` |

## 10. 每个 Stage 结束后关闭并冷重置

先停止全部压测客户端，再执行：

```bash
./scripts/verify-nereus-release.sh "${STAGE}"
./scripts/collect-helm-evidence.sh
```

先生成只读清理计划：

```bash
./scripts/reset-nereus-benchmark-stage.sh "${STAGE}"
```

确认 PVC/PV 清单后执行：

```bash
NEREUS_COLD_RESET_CONFIRM="${NEREUS_NAMESPACE}/${NEREUS_RELEASE}/${STAGE}" \
  ./scripts/reset-nereus-benchmark-stage.sh "${STAGE}" --execute
```

Stage A 的确认值示例：

```bash
NEREUS_COLD_RESET_CONFIRM='pulsar/nereus/A' \
  ./scripts/reset-nereus-benchmark-stage.sh A --execute
```

reset 脚本会卸载 Helm、挂载并擦除 3 个 Oxia PVC、12 个 BookKeeper
PVC 和 1 个 SeaweedFS PVC，然后删除这些 PVC，并把 `Retain` PV 恢复为
`Available`。它不会删除 `pulsar` namespace、Secret、campaign 文件和
测试证据。

重置后检查：

```bash
helm -n "${NEREUS_NAMESPACE}" list --all
kubectl -n "${NEREUS_NAMESPACE}" get pvc
kubectl get pv \
  -o custom-columns='NAME:.metadata.name,CLASS:.spec.storageClassName,PHASE:.status.phase,CAPACITY:.spec.capacity.storage'
```

确认 `pulsar/nereus` release 和 16 个核心数据 PVC 均不存在，所需静态
PV 都是 `Available`，再安装下一 Stage。

如果部署在后置门禁失败，新版脚本仍会保留该次运行自己的
`RUN_DIR/run.env`，但不会把它提升为 `results/deploy/latest.env`。先从
错误信息或目录时间找到失败运行，然后显式检查：

```bash
FAILED_RUN="$(
  ls -1dt "${NEREUS_RESULTS_ROOT}/deploy/${STAGE}"/* |
  head -n 1
)"

NEREUS_RUN_ENV="${FAILED_RUN}/run.env" \
  ./scripts/verify-nereus-release.sh "${STAGE}"
```

只有部署脚本全部通过后，才会更新 `latest.env`。不要为失败运行手工
伪造 `latest.env`。

## 11. 冷启动边界

当前 reset 脚本安全擦除的是 16 个核心数据 PVC：Oxia 3、
BookKeeper 12、SeaweedFS 1。VMSingle 和 Grafana 的监控持久化卷不在
该集合中。如果每一轮还必须清空历史监控数据，应先扩展 reset 脚本，
把 `local-prometheus-1` 和 `local-grafana` 纳入有证据的安全擦除流程；
不要用删除 PV 对象代替清空其本地目录。

因为 namespace 固定为共享的 `pulsar`，Stage E 后也不要执行
`kubectl delete namespace pulsar`。
