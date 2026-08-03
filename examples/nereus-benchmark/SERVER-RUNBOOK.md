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
- SeaweedFS 固定 4 CPU/4 GiB，OMB 固定两个 2 CPU/6 GiB worker
- 每个 `(suite, rate, stage, repetition)` 测试后执行冷重置，再安装下一组
- OMB release 在整个 campaign 中保持运行，不参与每轮 Pulsar 冷重置

`deploy-nereus-stage.sh` 内部执行 `helm install`。不要再额外执行一遍
`helm install`。`reset-nereus-benchmark-stage.sh --execute` 内部执行
`helm uninstall`。不要提前手工 uninstall 或删除 PV。

`deploy-nereus-stage.sh` 会先以不创建 VictoriaMetrics CR 的 bootstrap 值安装
operator 和 Pulsar 核心资源，等待 operator admission webhook Ready，再升级到
完整监控值；不要把这两个 Helm 阶段拆成手工命令。

服务器 checkout 只用于同步和执行，不用于编辑。任何脚本、Chart、workload
或操作文档修改都必须先在本地 checkout 完成、测试、commit 并 push，再在
服务器上执行 `git pull --ff-only` 同步；如果服务器工作区不是 clean，先停止
本次流程并处理漂移，不要直接在服务器上改文件。

本次执行固定的源码身份是：Apache Pulsar
`8dae0236c0a0d405ed7f8303081080520fe91551`，Nereus Pulsar
`0718b565f82e71a3ace2e28a3962c8c1385908c7`，Nereus v0.1.0
`20a9f8ebdae222b12d589c863f871583f283da10`。镜像 tag 和 digest 以本次
构建产生的 manifest 为准；不要复用旧的 `p50fc70fe`、`n1c23bc9b`、
`n78a15445` 或 OMB `7f89b90fc30d` 镜像。

## 0. 执行边界和开始测试前的硬门禁

不要在两个节点之间交替尝试同一条命令。固定执行边界如下：

| 工作 | 执行节点 |
| --- | --- |
| Pulsar/Nereus、OMB 镜像构建 | `denovo-r730-1` |
| Helm install/uninstall、Stage verify、evidence collect、冷重置 | Mac 本地 kubeconfig（`kubectl`/`helm`） |
| OMB worker/空闲 driver Pod | Kubernetes 调度到 `denovo-win-1` |
| SeaweedFS Pod | Kubernetes 调度到 `denovo-win-1` |
| `run-case.sh`、宿主机 OMB coordinator、结果分析 | `denovo-win-1` |

本次 k8s 操作边界固定为 Mac 本地 kubeconfig。主节点只负责镜像构建、containerd
镜像传输、物理盘清理以及保存服务器侧证据；不要在服务器上直接执行 Helm/kubectl
来替代本地操作，也不要在服务器 checkout 中编辑脚本、Chart 或 workload。

每次代码更新后，先更新两个节点的 benchmark checkout，再在主节点重新构建
OMB 镜像。源码 SHA、镜像构建 `SOURCE_SHA` 和两个节点 checkout 必须一致。
不能用新 checkout 运行旧镜像。

正式执行 `run-case.sh` 前，下面六项必须同时成立：

1. `pulsar/nereus` 和 `pulsar/omb` 都是 `deployed`；
2. `omb-worker-0`、`omb-worker-1` 都在 `denovo-win-1` 且 Ready；
3. apps 节点的 `omb-image.env` 非空并含三行
   `IMAGE_REF/IMAGE_DIGEST/SOURCE_SHA`；
4. apps 节点的 `omb-workers.yaml` 非空、恰好包含两个当前 Pod IP，且两个
   `/counters-stats` 端点都返回 HTTP 200；
5. apps 节点 kubelet 的 CPU Manager 是 `static`，系统保留 CPU 是
   `12-15`；
6. SeaweedFS 得到 4 个 `0-11` 范围内的逻辑 CPU，两个 worker 分别得到
   2 个 `0-11` 范围内的逻辑 CPU，且每组都是完整 P-Core sibling pair。

任一条件失败都不要启动 workload。本手册后面的命令会逐项断言这些条件。

### 0.1 历史现场检查结论（2026-07-26，仅用于解释恢复顺序）

以下记录是上次现场的历史快照，不代表本次当前状态；其中出现的旧 OMB
`SOURCE_SHA`、旧 checkout SHA 和旧 CPU evidence 均不可作为本次结果。

本次远程只读检查发现：

- Pulsar Stage A、OMB driver 和两个 worker 都处于 Running；
- `omb-workers.yaml` 在两个节点都不存在；
- apps 节点的 `omb-image.env` 是 0 字节；
- 当前 OMB 镜像的 `SOURCE_SHA` 是 `7f89b90fc30d`，两个 checkout 已经是
  `ad498ef657de7312e16fcda9429f025fdeaa576e`；
- kubelet 的 `cpuManagerPolicy` 是 `none`，节点 allocatable CPU 仍是 16；
- SeaweedFS、`omb-worker-0`、`omb-worker-1` 的
  `Cpus_allowed_list` 都是 `0-15`；
- 当前 SeaweedFS Pod 的 CPU request/limit 是 2，而本分支
  `values-common.yaml` 已固定为 4。

因此上次的
`results/v010-202607/block-01-s1-stage-A-rep-01/cpu-allocation.txt`
只能作为失败前置检查证据，不能计入性能结果。如果现场仍残留类似状态，
正确恢复顺序是：

1. 冷重置当前 Stage A 并卸载 OMB；
2. 给 `denovo-win-1` 启用 static CPU Manager；
3. 更新两台服务器代码；
4. 在主节点从当前 benchmark SHA 重新构建和传输 OMB 镜像；
5. 重新安装 OMB 和 Stage A；
6. 在 apps 节点重新生成 worker 文件并通过全部硬门禁；
7. 重新运行 S1。

### 0.2 当前现场的恢复命令

先在 `denovo-r730-1` 按第 1 节导出全部环境变量，然后清理尚未产生正式
OMB 结果的 Stage A：

```bash
cd /root/pulsar-helm-chart

./scripts/reset-nereus-benchmark-stage.sh A

NEREUS_COLD_RESET_CONFIRM='pulsar/nereus/A' \
  ./scripts/reset-nereus-benchmark-stage.sh A --execute

helm uninstall omb -n pulsar
kubectl -n pulsar wait \
  --for=delete \
  pod \
  -l app=omb \
  --timeout=5m
kubectl -n pulsar get pods -l app=omb
```

预期最后一条命令不再返回 OMB Pod。然后维护 apps 节点：

```bash
kubectl drain denovo-win-1 \
  --ignore-daemonsets \
  --delete-emptydir-data
```

登录 `denovo-win-1`，备份并编辑 kubelet 的真实配置文件：

```bash
cp -a \
  /var/lib/kubelet/config.yaml \
  "/var/lib/kubelet/config.yaml.before-cpu-manager.$(date +%Y%m%dT%H%M%S)"

vim /var/lib/kubelet/config.yaml
```

在 `KubeletConfiguration` 顶层加入且只加入一份：

```yaml
cpuManagerPolicy: static
cpuManagerPolicyOptions:
  full-pcpus-only: "true"
reservedSystemCPUs: "12-15"
```

保存后执行：

```bash
systemctl stop kubelet
rm -f /var/lib/kubelet/cpu_manager_state
systemctl start kubelet

systemctl is-active kubelet
journalctl -u kubelet -n 100 --no-pager
```

回到 `denovo-r730-1`：

```bash
kubectl uncordon denovo-win-1
kubectl wait \
  --for=condition=Ready \
  node/denovo-win-1 \
  --timeout=5m

kubectl get node denovo-win-1 \
  -o jsonpath='{.status.capacity.cpu}{" capacity\n"}{.status.allocatable.cpu}{" allocatable\n"}'
```

预期为 `16 capacity`、`12 allocatable`。随后按第 8.1 节更新两个 benchmark
checkout；按第 8.2 节重新构建、传输新 OMB 镜像；按第 8.4 节重新部署
OMB；最后按第 9.1 节重新部署 Stage A。不要复用旧的
`pulsar-b7f89b90fc30d-amd64` 镜像或旧 CPU evidence。

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
export OMB_RELEASE='omb'
export OMB_REPO='/root/denovo/benchmark'
export OMB_IMAGE_ENV='/root/denovo/nereus-campaign/omb-image.env'
export OMB_VALUES='/root/denovo/nereus-campaign/values-omb-apps.yaml'
export OMB_WORKERS_FILE='/root/denovo/nereus-campaign/omb-workers.yaml'
export CAMPAIGN_ID='v010-20260802'
```

检查当前上下文和固定身份：

```bash
printf 'context=%s\nrelease=%s\nnamespace=%s\ncluster=%s\nombRelease=%s\n' \
  "${NEREUS_EXPECTED_CONTEXT}" \
  "${NEREUS_RELEASE}" \
  "${NEREUS_NAMESPACE}" \
  "${NEREUS_CLUSTER}" \
  "${OMB_RELEASE}"
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

### 2.1 固定 apps 节点的 P-Core 分配

`denovo-win-1` 的 CPU 拓扑固定为：

- P-Core：逻辑 CPU `0-11`，物理核 sibling 分别为 `0-1`、`2-3`、
  `4-5`、`6-7`、`8-9`、`10-11`；
- E-Core：逻辑 CPU `12-15`。

SeaweedFS 固定 request/limit 为 4 CPU，在 kubelet static CPU Manager 和
`full-pcpus-only` 下占用两个完整 P-Core。两个 OMB worker 各固定为 2 CPU，
分别占用一个完整 P-Core。先完成当前冷重置并卸载 apps 节点上的 OMB release，
然后在控制节点执行：

```bash
kubectl drain denovo-win-1 \
  --ignore-daemonsets \
  --delete-emptydir-data
```

在 `denovo-win-1` 确认 kubelet 的 `--config` 路径，备份配置，并在
`KubeletConfiguration` 顶层设置：

```yaml
cpuManagerPolicy: static
cpuManagerPolicyOptions:
  full-pcpus-only: "true"
reservedSystemCPUs: "12-15"
```

保留现有的 memory、`systemReserved` 和 `kubeReserved` 配置，不要创建重复
字段。切换策略时必须停止 kubelet 并清理旧 checkpoint：

```bash
systemctl stop kubelet
rm -f /var/lib/kubelet/cpu_manager_state
systemctl start kubelet
journalctl -u kubelet -n 100 --no-pager
```

回到控制节点：

```bash
kubectl uncordon denovo-win-1
kubectl get node denovo-win-1 \
  -o jsonpath='{.status.capacity.cpu}{" capacity\n"}{.status.allocatable.cpu}{" allocatable\n"}'
```

预期 CPU capacity 为 16，allocatable 为 12。重新部署后，在 apps 节点保存
CPU Manager evidence：

```bash
jq . /var/lib/kubelet/cpu_manager_state
kubectl -n pulsar exec nereus-seaweedfs-0 -- \
  sh -c 'grep Cpus_allowed_list /proc/1/status'
kubectl -n pulsar exec omb-worker-0 -- \
  sh -c 'grep Cpus_allowed_list /proc/1/status'
kubectl -n pulsar exec omb-worker-1 -- \
  sh -c 'grep Cpus_allowed_list /proc/1/status'
```

SeaweedFS 的允许列表必须由 `0-11` 中的两个完整 sibling pair 组成，不能包含
`12-15`。两个 worker 的允许列表必须各由 `0-11` 中的一个完整 sibling pair
组成。

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
但数值不同。部署脚本会先通过
`nerdctl images --digests --no-trunc --format '{{json .}}'` 读取本地
tag 的 OCI target 并与冻结 manifest 核对，再把该 target 映射到
Docker-compatible inspect 的 config ID，最后用 config ID 校验 Pod。
这里不使用 `image inspect --mode native`：不同 nerdctl/containerd 组合
的 native inspect 输出结构并不稳定，有些版本只返回 config JSON，
没有 `.Target.digest`。
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

## 8. 构建并部署 OMB

OMB release 固定为 `pulsar/omb`，在 A–E 之间保持运行。当前 Helm
driver Pod 只写入 `example-run.sh` 后执行 `tail -f /dev/null`；正式
coordinator 由 `denovo-win-1` 上的 `run-case.sh` 启动。镜像构建、
`helm upgrade --install` 和 rollout 检查都在主节点执行；worker 地址文件
在 apps 节点根据当前 Pod IP 生成；
`nodeSelector: workload=apps` 使两个 worker Pod 和空闲 driver Pod 实际
运行在 apps 节点。主节点只做控制面操作，不运行 OMB Pod。

### 8.1 在两个节点准备相同的 OMB 源码

主节点负责构建镜像，apps 节点只编译并运行宿主机 coordinator。两个节点必须
使用完全相同的 `pulsar` 分支 commit。分别在两个节点首次执行：

```bash
mkdir -p /root/denovo
git clone \
  --branch pulsar \
  https://github.com/Denovo1998/benchmark.git \
  /root/denovo/benchmark
```

分别在两个节点后续更新：

```bash
cd /root/denovo/benchmark
git checkout pulsar
git pull --ff-only origin pulsar
git status --short
```

两个节点的 `git status --short` 都必须为空。在主节点比较 source SHA：

```bash
MAIN_OMB_SHA="$(git -C /root/denovo/benchmark rev-parse HEAD)"
APPS_OMB_SHA="$(
  ssh root@denovo-win-1 \
    'git -C /root/denovo/benchmark rev-parse HEAD'
)"

printf 'main=%s\napps=%s\n' "${MAIN_OMB_SHA}" "${APPS_OMB_SHA}"
test "${MAIN_OMB_SHA}" = "${APPS_OMB_SHA}"
```

只在 apps 节点为宿主机 coordinator 编译：

```bash
cd /root/denovo/benchmark
java -version
mvn -version
mvn install -DskipTests
```

不要给 Maven 增加 `-T`；多个模块并发执行 Spotless 会争用同一把锁。

### 8.2 在主节点构建并传输不可变 OMB 镜像

固定由 `denovo-r730-1` 构建所有 campaign 镜像，复用构建 Pulsar/Nereus
镜像时已经可用的 BuildKit。apps 节点不安装 BuildKit。先在主节点检查：

```bash
command -v nerdctl
command -v buildctl
buildctl --version
buildkitd --version
ps -ef | grep '[b]uildkitd'
find /run -maxdepth 2 -name buildkitd.sock -ls
```

Nereus 三个镜像已经在该节点通过 `nerdctl build` 构建成功，因此这里不改变
BuildKit 配置。然后在主节点执行：

```bash
cd /root/denovo/benchmark
mkdir -p \
  /root/denovo/images \
  /root/denovo/nereus-campaign

set -o pipefail
./scripts/nereus-benchmark/build-omb-image.sh 2>&1 |
tee /root/denovo/nereus-campaign/omb-image-build.log

grep -E '^(IMAGE_REF|IMAGE_DIGEST|SOURCE_SHA)=' \
  /root/denovo/nereus-campaign/omb-image-build.log \
  > /root/denovo/nereus-campaign/omb-image.env

test -s /root/denovo/nereus-campaign/omb-image.env
test "$(
  grep -Ec '^(IMAGE_REF|IMAGE_DIGEST|SOURCE_SHA)=' \
    /root/denovo/nereus-campaign/omb-image.env
)" -eq 3
source /root/denovo/nereus-campaign/omb-image.env
test "$(git -C /root/denovo/benchmark rev-parse --short=12 HEAD)" = \
  "${SOURCE_SHA}"
printf 'image=%s\ndigest=%s\nsource=%s\n' \
  "${IMAGE_REF}" "${IMAGE_DIGEST}" "${SOURCE_SHA}"
```

保存归档和两个匹配的 sidecar：

```bash
./scripts/nereus-benchmark/containerd-transfer-omb-image.sh save \
  "${IMAGE_REF}" \
  /root/denovo/images/omb-pulsar-amd64.tar

ls -l \
  /root/denovo/images/omb-pulsar-amd64.tar \
  /root/denovo/images/omb-pulsar-amd64.tar.sha256 \
  /root/denovo/images/omb-pulsar-amd64.tar.env
```

checksum 文件固定是 `<tar>.sha256`，不是 `<env>.sha256`。在主节点创建
apps 节点目录并复制镜像、校验文件、构建 identity 和 transfer 脚本：

```bash
ssh root@denovo-win-1 \
  'mkdir -p /root/denovo/images /root/denovo/nereus-campaign'

scp \
  /root/denovo/images/omb-pulsar-amd64.tar \
  /root/denovo/images/omb-pulsar-amd64.tar.sha256 \
  /root/denovo/images/omb-pulsar-amd64.tar.env \
  /root/denovo/benchmark/scripts/nereus-benchmark/containerd-transfer-omb-image.sh \
  root@denovo-win-1:/root/denovo/images/

scp \
  /root/denovo/nereus-campaign/omb-image.env \
  /root/denovo/nereus-campaign/omb-image-build.log \
  root@denovo-win-1:/root/denovo/nereus-campaign/

ssh root@denovo-win-1 \
  'test -s /root/denovo/nereus-campaign/omb-image.env'
```

在 apps 节点导入到 Kubernetes 使用的 `k8s.io` containerd namespace：

```bash
cd /root/denovo/images
chmod +x containerd-transfer-omb-image.sh

./containerd-transfer-omb-image.sh load \
  omb-pulsar-amd64.tar \
  omb-pulsar-amd64.tar.env
```

确认 apps 源码、镜像 identity 和 containerd digest 完全一致：

```bash
source /root/denovo/nereus-campaign/omb-image.env
test "$(
  grep -Ec '^(IMAGE_REF|IMAGE_DIGEST|SOURCE_SHA)=' \
    /root/denovo/nereus-campaign/omb-image.env
)" -eq 3
test "$(git -C /root/denovo/benchmark rev-parse --short=12 HEAD)" = \
  "${SOURCE_SHA}"

nerdctl --namespace k8s.io images \
  --digests --no-trunc |
grep 'nereus-benchmark/openmessaging-benchmark'
```

如果 `omb-image.env` 是 0 字节，不要从 tar sidecar 猜测 `SOURCE_SHA`，
也不要继续部署。回到主节点重新执行构建输出提取和 `scp`。tar sidecar 只
包含镜像引用与 digest，不能替代三行的构建 identity 文件。

### 8.3 给 apps 节点准备 Kubernetes context

`run-case.sh` 会验证当前 context 是否与 Pulsar deployment evidence
一致。在控制节点执行一次：

```bash
ssh root@denovo-win-1 'mkdir -p /root/.kube && chmod 700 /root/.kube'
scp /root/.kube/config root@denovo-win-1:/root/.kube/config
ssh root@denovo-win-1 'chmod 600 /root/.kube/config'
```

该文件包含集群凭据，只允许 root 读取，不得提交到仓库。然后在 apps
节点验证：

```bash
kubectl config current-context
kubectl get node denovo-win-1
```

context 必须与控制节点的 `NEREUS_EXPECTED_CONTEXT` 完全一致。

### 8.4 生成 OMB values 并安装两个 worker

在主节点生成 values 并通过 Helm 部署：

```bash
export OMB_RELEASE='omb'
export OMB_REPO='/root/denovo/benchmark'
export OMB_IMAGE_ENV='/root/denovo/nereus-campaign/omb-image.env'
export OMB_VALUES='/root/denovo/nereus-campaign/values-omb-apps.yaml'
export OMB_WORKERS_FILE='/root/denovo/nereus-campaign/omb-workers.yaml'

source "${OMB_IMAGE_ENV}"

cat > "${OMB_VALUES}" <<EOF
numWorkers: 2
image: ${IMAGE_REF}
# 本地 containerd + Never 必须使用已经导入的精确 tag。IMAGE_DIGEST 仍由
# transfer load 校验，并写入 OMB manifest，不能拼成 tag@digest。
imageDigest: ""
imagePullPolicy: Never

driverNodeSelector:
  workload: apps
workerNodeSelector:
  workload: apps

driverTolerations:
  - key: dedicated
    operator: Equal
    value: apps
    effect: NoSchedule
workerTolerations:
  - key: dedicated
    operator: Equal
    value: apps
    effect: NoSchedule

# 当前 driver Pod 是空闲 launcher；正式 coordinator 在宿主机运行。
driverCpuRequest: 500m
driverCpuLimit: 500m
driverMemoryRequest: 1Gi
driverMemoryLimit: 1Gi
driverHeapOpts: "-Xms512m -Xmx512m"

# benchmark-worker 默认使用 4 GiB heap，额外保留 2 GiB native memory。
workersCpuRequest: 2000m
workersCpuLimit: 2000m
workersMemoryRequest: 6Gi
workersMemoryLimit: 6Gi

results:
  enabled: false
EOF

cd "${OMB_REPO}"
helm template "${OMB_RELEASE}" \
  deployment/kubernetes/helm/benchmark \
  --namespace pulsar \
  -f "${OMB_VALUES}" \
  > /tmp/omb-rendered.yaml

grep -F "image: ${IMAGE_REF}" /tmp/omb-rendered.yaml
if grep -q '@sha256:' /tmp/omb-rendered.yaml; then
  echo 'ERROR: local Never deployment must not render tag@digest' >&2
  exit 1
fi

helm upgrade --install "${OMB_RELEASE}" \
  deployment/kubernetes/helm/benchmark \
  --namespace pulsar \
  -f "${OMB_VALUES}"
```

等待两个 worker 和 driver：

```bash
kubectl -n pulsar rollout status \
  statefulset/omb-worker \
  --timeout=10m
kubectl -n pulsar wait \
  --for=condition=Ready \
  pod/omb-driver \
  --timeout=10m
kubectl -n pulsar get pods \
  -l app=omb \
  -o wide
```

三个 Pod 都必须位于 `denovo-win-1`。生成固定 worker 文件：

```bash
kubectl -n pulsar get pods \
  -l 'app=omb,component=worker' \
  -o wide
```

worker 文件由实际运行 coordinator 的 apps 节点直接生成，不再在主节点
生成后 `scp`。这样可以避免漏传文件，并确保记录的是运行前的当前 Pod IP。
先在主节点同步只读的 OMB values 和构建 identity：

```bash
scp \
  "${OMB_VALUES}" \
  "${OMB_IMAGE_ENV}" \
  root@denovo-win-1:/root/denovo/nereus-campaign/

ssh root@denovo-win-1 \
  'test -s /root/denovo/nereus-campaign/omb-image.env'
```

然后在 `denovo-win-1` 执行下面整个代码块。它只接受两个 Running、Ready
worker，逐个检查真实的 `/counters-stats` 端点，最后才原子替换文件：

```bash
(
  set -euo pipefail

  OMB_WORKERS_FILE='/root/denovo/nereus-campaign/omb-workers.yaml'
  mapfile -t OMB_WORKER_URLS < <(
    kubectl -n pulsar get pods \
      -l 'app=omb,component=worker' \
      -o json |
    jq -r '
      .items[]
      | select(.status.phase == "Running")
      | select(any(.status.conditions[]?;
          .type == "Ready" and .status == "True"))
      | [.metadata.name, .status.podIP]
      | @tsv
    ' |
    sort |
    awk '{print "http://" $2 ":8080"}'
  )

  test "${#OMB_WORKER_URLS[@]}" -eq 2
  for worker in "${OMB_WORKER_URLS[@]}"; do
    curl --fail --silent --show-error \
      --max-time 5 \
      "${worker}/counters-stats" \
      >/dev/null
  done

  tmp_file="$(mktemp \
    /root/denovo/nereus-campaign/omb-workers.yaml.XXXXXX)"
  {
    printf 'workers:\n'
    printf '  - %s\n' "${OMB_WORKER_URLS[@]}"
  } > "${tmp_file}"
  chmod 600 "${tmp_file}"
  mv "${tmp_file}" "${OMB_WORKERS_FILE}"

  cat "${OMB_WORKERS_FILE}"
  test "$(grep -c '^  - http://' "${OMB_WORKERS_FILE}")" -eq 2
)
```

## 9. 单次冷启动测试闭环

一次测试只允许一个 `(suite, rate, stage, repetition)`。即使 Stage 相同，
更换 rate、message size 或 suite 也必须执行冷重置并重新安装。不要在一个
Pulsar deployment 上连续跑多个正式用例。

### 9.1 控制节点安装一个 Stage

设置本轮唯一身份。下面以 Stage C 的 S1 为例：

```bash
cd /root/pulsar-helm-chart

STAGE=C
BLOCK_ID=block-01-s1
REPETITION=1
SEED=202607250101
RUN_ID="${BLOCK_ID}-stage-${STAGE}-rep-$(printf '%02d' "${REPETITION}")"
```

Stage A：

```bash
./scripts/deploy-nereus-stage.sh "${STAGE}"
./scripts/verify-nereus-release.sh "${STAGE}"
```

Stage B–E：

```bash
./scripts/deploy-nereus-stage.sh "${STAGE}"
./scripts/activate-nereus-publications.sh "${STAGE}"
./scripts/run-object-store-contract.sh
./scripts/verify-nereus-release.sh "${STAGE}"
```

如果控制进程在 Helm install/upgrade 已完成、但 `run.env` 写入之前被中断，
不要手工伪造或覆盖 `latest.env`。确认现有 release 的 stage 和 storage class
仍与本轮一致后，可在本地源码已 commit/push 且服务器仓库已同步的前提下，使用
受约束的恢复模式完成部署收尾：

```bash
NEREUS_RESUME_RUN_STAMP='20260803T000000Z' \
  ./scripts/deploy-nereus-stage.sh "${STAGE}" --resume
```

`--resume` 只接受已存在且 annotation 完全匹配的 release，跳过 Helm install/
upgrade，仅重新收集部署证据、创建本轮 tenant/namespace/topic 并生成新的
`run.env`/`latest.env`；正常的冷启动仍必须先执行 reset，不能用该模式绕过冷重置。
如果 Nereus bootstrap Job 已因 `ttlSecondsAfterFinished` 被清理，恢复模式会
改用 Ready Broker 的 `wait-nereus-bookkeeper-namespace` initContainer 日志，
并保存来源标记；普通冷启动仍要求直接保存 bootstrap Job 的 termination evidence。

部署脚本会在 Helm install 前检查 Nereus admin 和 Broker ConfigMap 中的
long-valued BookKeeper properties 不得被渲染成科学计数法；如果该门禁失败，
保留本地 rendered manifest，修复本地 chart 后 commit/push，再同步服务器仓库，
不要直接编辑服务器上的 ConfigMap 或源码。
Broker ConfigMap 中只存在于 Nereus 镜像的 BookKeeper fields 还必须使用
`PULSAR_PREFIX_` 环境变量形式，否则容器 entrypoint 不会把它们加入
`broker.conf`，运行时会退回 `nereusBookKeeperPrimaryWalEnabled=false`。
激活脚本的第一次 `bookkeeper-primary-wal/activation/prepare` 返回
`PREPARED` 且 publication bits 为 `false` 是正常中间态；随后必须通过
`activation/publications` 才进入 `ACTIVE`，不能把 prepare 响应直接当成已激活。
如果控制进程在第一次 publications CAS 成功后中断，重试 prepare 会按服务端
幂等语义返回已有的 `ACTIVE` 记录；脚本仍必须继续执行
`activation/publications`，并用当前 readiness 校验返回值，不能跳过重绑定和
generation backfill。

对应关系：

| Stage | Broker 与数据路径 | namespace storage class |
| --- | --- | --- |
| A | Apache Pulsar 基线 | `bookkeeper` |
| B | Nereus dormant，原生 BookKeeper | `bookkeeper` |
| C | `BOOKKEEPER_WAL_ONLY` | `nereus` |
| D | `BOOKKEEPER_WAL_ASYNC_OBJECT` | `nereus` |
| E | `BOOKKEEPER_WAL_SYNC_OBJECT` | `nereus` |

部署成功后才会更新：

```text
/root/denovo/nereus-campaign/results/deploy/latest.env
```

把本轮 deployment evidence 同步到 apps 节点的相同绝对路径：

```bash
rsync -a \
  "${NEREUS_RESULTS_ROOT}/deploy/" \
  root@denovo-win-1:"${NEREUS_RESULTS_ROOT}/deploy/"
```

### 9.2 apps 节点准备 driver

```bash
cd /root/denovo/benchmark

export NEREUS_NAMESPACE='pulsar'
export NEREUS_RELEASE='nereus'
export NEREUS_RESULTS_ROOT='/root/denovo/nereus-campaign/results'
export NEREUS_RUN_ENV="${NEREUS_RESULTS_ROOT}/deploy/latest.env"
export OMB_WORKERS_FILE='/root/denovo/nereus-campaign/omb-workers.yaml'
export OMB_IMAGE_ENV='/root/denovo/nereus-campaign/omb-image.env'
export CAMPAIGN_ID='v010-20260802'
export HEAP_OPTS='-Xms2G -Xmx2G'

test -s "${NEREUS_RUN_ENV}"
test -s "${OMB_IMAGE_ENV}"
test -s "${OMB_WORKERS_FILE}"
source "${NEREUS_RUN_ENV}"
source "${OMB_IMAGE_ENV}"

OMB_FULL_GIT_SHA="$(git rev-parse HEAD)"
test "${SOURCE_SHA}" = "$(git rev-parse --short=12 HEAD)"
test "${OMB_FULL_GIT_SHA:0:${#SOURCE_SHA}}" = "${SOURCE_SHA}"

mapfile -t OMB_WORKER_URLS < <(
  sed -n 's/^[[:space:]]*- //p' "${OMB_WORKERS_FILE}" |
  sort
)
test "${#OMB_WORKER_URLS[@]}" -eq 2

mapfile -t OMB_LIVE_WORKER_URLS < <(
  kubectl -n pulsar get pods \
    -l 'app=omb,component=worker' \
    -o json |
  jq -r '
    .items[]
    | select(.status.phase == "Running")
    | select(any(.status.conditions[]?;
        .type == "Ready" and .status == "True"))
    | "http://\(.status.podIP):8080"
  ' |
  sort
)
test "${#OMB_LIVE_WORKER_URLS[@]}" -eq 2
test "$(printf '%s\n' "${OMB_WORKER_URLS[@]}")" = \
  "$(printf '%s\n' "${OMB_LIVE_WORKER_URLS[@]}")"

for worker in "${OMB_WORKER_URLS[@]}"; do
  curl --fail --silent --show-error \
    --max-time 5 \
    "${worker}/counters-stats" \
    >/dev/null
done

mapfile -t OMB_RUNTIME_IDS < <(
  kubectl -n pulsar get pods -l app=omb -o json |
  jq -r '.items[].status.containerStatuses[]?.imageID' |
  sort -u
)
test "${#OMB_RUNTIME_IDS[@]}" -eq 1

export OMB_GIT_SHA="${OMB_FULL_GIT_SHA}"
export OMB_IMAGE_REF="${IMAGE_REF}"
export OMB_IMAGE_DIGEST="${IMAGE_DIGEST}"
export OMB_RUNTIME_CONFIG_ID="${OMB_RUNTIME_IDS[0]}"

export PULSAR_CLUSTER="${CLUSTER}"
# Both broker Services are headless (clusterIP=None); use stable in-cluster DNS.
export PULSAR_SERVICE_URL='pulsar://nereus-broker.pulsar.svc.cluster.local:6650'
export PULSAR_HTTP_URL='http://nereus-broker.pulsar.svc.cluster.local:8080'

BLOCK_ID=block-01-s1
REPETITION=1
SEED=202607250101
RUN_ID="${BLOCK_ID}-stage-${STAGE}-rep-$(printf '%02d' "${REPETITION}")"
DRIVER_YAML="/root/denovo/nereus-campaign/${RUN_ID}-driver.yaml"

./scripts/nereus-benchmark/render-run-config.sh \
  "${STAGE}" \
  "${BLOCK_ID}" \
  "${RUN_ID}" \
  "${REPETITION}" \
  "${SEED}" \
  "${DRIVER_YAML}"

./scripts/nereus-benchmark/validate-run-config.sh "${DRIVER_YAML}"
```

如果 worker 地址比较失败，说明 worker Pod 在文件生成后重建过。回到 8.4，
在 apps 节点重新生成 `omb-workers.yaml`，不要手工修改旧 IP。

同一 block 的 A–E 必须使用相同 `SEED`。下一 block 才能换 seed。
正式 driver 必须由 `pulsar-stage-template.yaml` 渲染，不能直接使用
`driver-pulsar/pulsar.yaml`。

### 9.3 保存 CPUSet 证据

在 apps 节点：

```bash
test "$(jq -r '.policyName' /var/lib/kubelet/cpu_manager_state)" = \
  'static'

SEAWEEDFS_CPUSET="$(
  kubectl -n pulsar exec nereus-seaweedfs-0 -- \
    sh -c "awk '/Cpus_allowed_list/ {print \$2}' /proc/1/status"
)"
OMB_WORKER_0_CPUSET="$(
  kubectl -n pulsar exec omb-worker-0 -- \
    sh -c "awk '/Cpus_allowed_list/ {print \$2}' /proc/1/status"
)"
OMB_WORKER_1_CPUSET="$(
  kubectl -n pulsar exec omb-worker-1 -- \
    sh -c "awk '/Cpus_allowed_list/ {print \$2}' /proc/1/status"
)"

python3 - \
  "${SEAWEEDFS_CPUSET}" \
  "${OMB_WORKER_0_CPUSET}" \
  "${OMB_WORKER_1_CPUSET}" <<'PY'
import sys


def expand(cpu_list):
    cpus = set()
    for item in cpu_list.split(","):
        if "-" in item:
            start, end = (int(value) for value in item.split("-", 1))
            cpus.update(range(start, end + 1))
        else:
            cpus.add(int(item))
    return cpus


p_core_pairs = [{cpu, cpu + 1} for cpu in range(0, 12, 2)]
seaweedfs, worker_0, worker_1 = map(expand, sys.argv[1:])


def require_full_pairs(name, cpus, pair_count):
    if len(cpus) != pair_count * 2:
        raise SystemExit(
            f"{name} requires {pair_count * 2} logical CPUs, got {sorted(cpus)}"
        )
    covered = set().union(*(pair for pair in p_core_pairs if pair <= cpus))
    if covered != cpus:
        raise SystemExit(f"{name} is not assigned complete P-Core pairs: {sorted(cpus)}")


require_full_pairs("seaweedfs", seaweedfs, 2)
require_full_pairs("omb-worker-0", worker_0, 1)
require_full_pairs("omb-worker-1", worker_1, 1)
if len(seaweedfs | worker_0 | worker_1) != 8:
    raise SystemExit("SeaweedFS and OMB worker exclusive CPU sets overlap")
PY

RESULT_DIR="/root/denovo/benchmark/results/${CAMPAIGN_ID}/${RUN_ID}"
mkdir -p "${RESULT_DIR}"

{
  printf 'capturedAt=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '\n[cpu-manager-state]\n'
  cat /var/lib/kubelet/cpu_manager_state
  printf '\n[seaweedfs]\n'
  kubectl -n pulsar exec nereus-seaweedfs-0 -- \
    sh -c 'grep Cpus_allowed_list /proc/1/status'
  printf '\n[omb-worker-0]\n'
  kubectl -n pulsar exec omb-worker-0 -- \
    sh -c 'grep Cpus_allowed_list /proc/1/status'
  printf '\n[omb-worker-1]\n'
  kubectl -n pulsar exec omb-worker-1 -- \
    sh -c 'grep Cpus_allowed_list /proc/1/status'
} > "${RESULT_DIR}/cpu-allocation.txt"
```

上面的 Python 断言通过后才会写证据。SeaweedFS 必须得到 `0-11` 中两个
完整 sibling pair；两个 worker 必须各得到一个完整 sibling pair，三个
exclusive CPU set 不能重叠，也不能包含 E-Core `12-15`。

### 9.4 执行一个 workload

S1 smoke：

```bash
taskset -c 12-15 \
  ./scripts/nereus-benchmark/run-case.sh \
  "${DRIVER_YAML}" \
  workloads/nereus-v0.1.0/s1-smoke.yaml \
  "${OMB_WORKERS_FILE}"
```

`taskset` 只限制低负载的宿主机 coordinator；真正创建 producer/consumer
的是两个独占 P-Core 的 worker Pod。

检查结果：

```bash
RESULT_DIR="/root/denovo/benchmark/results/${CAMPAIGN_ID}/${RUN_ID}"

test -r "${RESULT_DIR}/manifest.json"
test -r "${RESULT_DIR}/result.json"

jq -r \
  '.runtimeInfo.attributes["persistence.managedLedgerStorageClassName"]' \
  "${RESULT_DIR}/manifest.json"

./scripts/nereus-benchmark/analyze-run.py \
  "${RESULT_DIR}/result.json" |
tee "${RESULT_DIR}/analysis.json"
```

A/B 必须输出 `bookkeeper`，C/D/E 必须输出 `nereus`。

如果 OMB 被中断，先对两个 worker 显式执行 `stop-all`，不得直接进入清理：

```bash
sed -n 's/^[[:space:]]*- //p' "${OMB_WORKERS_FILE}" |
while IFS= read -r worker; do
  curl --fail --silent --show-error \
    -X POST "${worker}/stop-all"
done
```

### 9.5 把 OMB 结果并入 Stage evidence

在控制节点，重新设置与 apps 节点相同的 `RUN_ID`，然后执行：

```bash
source "${NEREUS_RESULTS_ROOT}/deploy/latest.env"
mkdir -p "${RUN_DIR}/omb/${RUN_ID}"

rsync -a \
  root@denovo-win-1:"/root/denovo/benchmark/results/${CAMPAIGN_ID}/${RUN_ID}/" \
  "${RUN_DIR}/omb/${RUN_ID}/"

test -r "${RUN_DIR}/omb/${RUN_ID}/manifest.json"
test -r "${RUN_DIR}/omb/${RUN_ID}/result.json"
```

只有 OMB 原始结果、manifest、analysis 和 CPUSet 证据均已回传，才能收集
Helm evidence：

```bash
./scripts/verify-nereus-release.sh "${STAGE}"
./scripts/collect-helm-evidence.sh
```

### 9.6 冷重置

先生成只读清理计划：

```bash
./scripts/reset-nereus-benchmark-stage.sh "${STAGE}"
```

确认 PVC/PV 清单后执行：

```bash
NEREUS_COLD_RESET_CONFIRM="${NEREUS_NAMESPACE}/${NEREUS_RELEASE}/${STAGE}" \
  ./scripts/reset-nereus-benchmark-stage.sh "${STAGE}" --execute
```

reset 脚本会卸载 `pulsar/nereus`，擦除并删除 3 个 Oxia PVC、12 个
BookKeeper PVC 和 1 个 SeaweedFS PVC，然后把 `Retain` PV 恢复为
`Available`。静态 local/hostPath PV 使用 `Delete` reclaim policy 时没有
Kubernetes deletion plugin，脚本会在数据已擦除后删除 PV 对象；下一轮部署前
必须按第 4 节重新 apply 冻结的静态 PV YAML。它不会删除：

- `pulsar` namespace；
- `pulsar-nereus-secrets`；
- campaign identity 和已归档 evidence；
- 长期运行的 `pulsar/omb` release。

如果 Helm 卸载删除了 `${NEREUS_RELEASE}-grafana` PVC，reset 会只解绑定其静态
PV、保留 Grafana 数据，不会把它计入 16 个核心 benchmark PVC。benchmark
`values-common.yaml` 已关闭 Grafana 远程 dashboard 下载；指标采集不受影响。

重置后检查：

```bash
helm -n "${NEREUS_NAMESPACE}" list --all
kubectl -n "${NEREUS_NAMESPACE}" get pvc
kubectl get pv \
  -o custom-columns='NAME:.metadata.name,CLASS:.spec.storageClassName,PHASE:.status.phase,CAPACITY:.spec.capacity.storage'
```

确认 `pulsar/nereus` 和 16 个核心数据 PVC 均不存在，Retain PV 是
`Available`，并按第 4 节重新 apply 后确认所需静态 PV 都是 `Available`，才能
安装下一次测试。

## 10. Workload 选择与命令

| Suite | 文件 | 用途 | 当前参数 |
| --- | --- | --- | --- |
| S1 | `s1-smoke.yaml` | 部署 smoke | 16 partitions、50k msg/s、2 分钟 |
| C1 | `c1-throughput-template.yaml` | 最大可持续吞吐 | 48 partitions、显式 rate |
| L1 | `l1-latency-template.yaml` | 固定负载延迟 | common ceiling 的 25/50/75% |
| B1 | `b1-backlog-50g.yaml` | backlog/drain | 50 GiB backlog |
| R1 | `r1-broker-crash-template.yaml` | Broker crash recovery | common ceiling 约 60% |
| M1 | `m1-*-template.yaml` | 消息大小敏感性 | 100 B、1 KiB、10 KiB |

### 10.1 C1 每次只跑一个 rate

冷启动规则禁止一次执行默认的整个 rate ladder。每次部署只给
`run-c1-sweep.sh` 传一个 rate：

```bash
BLOCK_ID=block-01-c1
RATE=100000
RUN_ID="${BLOCK_ID}-stage-${STAGE}-rep-${REPETITION}-rate-${RATE}"

taskset -c 12-15 \
  ./scripts/nereus-benchmark/run-c1-sweep.sh \
  "${STAGE}" \
  "${BLOCK_ID}" \
  "${REPETITION}" \
  "${SEED}" \
  "${OMB_WORKERS_FILE}" \
  "${RATE}"
```

`run-c1-sweep.sh` 会自行渲染 driver 和 workload；不要使用 9.2 中为 S1
生成的 `DRIVER_YAML`。在运行前使用上面的 C1 `RUN_ID` 执行 9.3，运行后使用
同一个 `RUN_ID` 执行 9.5–9.6。下一 rate 必须重新安装对应 Stage。禁止省略
最后的 `RATE` 参数，否则脚本会在同一集群上连续执行 10 个 candidate，不
符合本 campaign 的冷启动要求。

初始候选 rate：

```text
50000 75000 100000 150000 200000 300000 400000 600000 800000 1000000
```

共同可持续上限取 A–E 五组可持续上限的最小值。

### 10.2 L1、R1 和 M1 替换模板 rate

这些用例先按 9.2 渲染 driver，但必须把 suite 和参数编码进唯一
`BLOCK_ID/RUN_ID`。把模板复制到本轮唯一文件，再替换 `name` 和
`producerRate`。以下是 L1 的示例：

```bash
BLOCK_ID=block-01-l1-p50
RATE=75000
RUN_ID="${BLOCK_ID}-stage-${STAGE}-rep-$(printf '%02d' "${REPETITION}")"
DRIVER_YAML="/root/denovo/nereus-campaign/${RUN_ID}-driver.yaml"
WORKLOAD_TEMPLATE='workloads/nereus-v0.1.0/l1-latency-template.yaml'
WORKLOAD_YAML="/root/denovo/nereus-campaign/${RUN_ID}-workload.yaml"

./scripts/nereus-benchmark/render-run-config.sh \
  "${STAGE}" \
  "${BLOCK_ID}" \
  "${RUN_ID}" \
  "${REPETITION}" \
  "${SEED}" \
  "${DRIVER_YAML}"

./scripts/nereus-benchmark/validate-run-config.sh "${DRIVER_YAML}"

python3 - \
  "${WORKLOAD_TEMPLATE}" \
  "${WORKLOAD_YAML}" \
  "${RATE}" \
  "${RUN_ID}" <<'PY'
import pathlib
import sys

source, target, rate, run_id = sys.argv[1:]
text = pathlib.Path(source).read_text()
lines = text.splitlines()
for index, line in enumerate(lines):
    if line.startswith("name: "):
        lines[index] = f"name: nereus-v010-{run_id}"
        break
text = "\n".join(lines) + "\n"
text = text.replace("producerRate: 100000", f"producerRate: {rate}")
pathlib.Path(target).write_text(text)
PY

taskset -c 12-15 \
  ./scripts/nereus-benchmark/run-case.sh \
  "${DRIVER_YAML}" \
  "${WORKLOAD_YAML}" \
  "${OMB_WORKERS_FILE}"
```

先用最终 `RUN_ID` 执行 9.3，再启动负载。对每个 Stage，L1 的三个 rate 和
M1 的三种 message size 合计六个独立冷启动测试；不得在同一 Pulsar
deployment 中连续执行。

### 10.3 B1

B1 当前固定 50 GiB backlog 和 100k msg/s：

```bash
BLOCK_ID=block-01-b1-50g-r100000
RUN_ID="${BLOCK_ID}-stage-${STAGE}-rep-$(printf '%02d' "${REPETITION}")"
DRIVER_YAML="/root/denovo/nereus-campaign/${RUN_ID}-driver.yaml"

./scripts/nereus-benchmark/render-run-config.sh \
  "${STAGE}" \
  "${BLOCK_ID}" \
  "${RUN_ID}" \
  "${REPETITION}" \
  "${SEED}" \
  "${DRIVER_YAML}"

./scripts/nereus-benchmark/validate-run-config.sh "${DRIVER_YAML}"

# 在这里执行 9.3，保存本轮 CPUSet evidence。

taskset -c 12-15 \
  ./scripts/nereus-benchmark/run-case.sh \
  "${DRIVER_YAML}" \
  workloads/nereus-v0.1.0/b1-backlog-50g.yaml \
  "${OMB_WORKERS_FILE}"
```

如果 100k 超过共同可持续上限，必须先生成独立 workload 文件调整 rate，
不能直接修改仓库中的模板。

## 11. R1 Broker crash

R1 使用约 60% common ceiling。apps 节点终端 1 启动
`r1-broker-crash-template.yaml` 渲染后的 workload。预热完成并确认目标
partition owner 后，在 apps 节点终端 2 执行。R1 的 `BLOCK_ID` 必须包含
实际 rate，例如 `block-01-r1-r120000`；按 10.2 渲染唯一 driver/workload
并在启动前执行 9.3。

```bash
OWNER_POD='nereus-broker-0'
RESULT_DIR="/root/denovo/benchmark/results/${CAMPAIGN_ID}/${RUN_ID}"
FAULT_EVENTS="${RESULT_DIR}/fault-events.jsonl"

/root/denovo/benchmark/scripts/nereus-benchmark/inject-broker-crash.sh \
  "${OWNER_POD}" \
  pulsar \
  "${FAULT_EVENTS}"
```

不得默认假设 `nereus-broker-0` 就是 owner；`OWNER_POD` 必须来自本轮
topic lookup evidence。故障脚本和 OMB 结果都在 apps 节点，因此事件文件会
直接进入本轮 `RESULT_DIR`。测试结束后执行：

```bash
./scripts/nereus-benchmark/analyze-run.py \
  "${RESULT_DIR}/result.json" \
  --fault-events "${RESULT_DIR}/fault-events.jsonl" |
tee "${RESULT_DIR}/analysis.json"
```

然后按 9.5–9.6 回传全部结果并冷重置。

## 12. 正式执行顺序

推荐顺序：

1. A–E 各运行一次 S1，验证部署、storage class、CPUSet 和 evidence；
2. 对 C1 每个 candidate rate，依次运行 A–E，每次都冷重置；
3. 取 A–E sustainable ceiling 的最小值作为 common ceiling；
4. L1 分别运行 common ceiling 的 25%、50%、75%；
5. 独立运行 B1；
6. 独立运行 R1；
7. M1 的 100 B、1 KiB、10 KiB 分别运行独立 rate sweep；
8. 新 repetition 使用新的 block/seed，并按预定 Stage 顺序轮换。

同一 block 内 A–E 使用完全相同的 seed、OMB image digest、两个 worker、
CPU/memory、placement、compression 和 workload。任一条件改变都必须开始
新的 campaign，不能把结果混入当前表格。

## 13. 失败处理与冷启动边界

如果部署后置门禁失败，本次 `RUN_DIR/run.env` 会保留，但不会提升为
`results/deploy/latest.env`。显式检查失败运行：

```bash
FAILED_RUN="$(
  ls -1dt "${NEREUS_RESULTS_ROOT}/deploy/${STAGE}"/* |
  head -n 1
)"

NEREUS_RUN_ENV="${FAILED_RUN}/run.env" \
  ./scripts/verify-nereus-release.sh "${STAGE}"
```

不要手工伪造或覆盖 `latest.env`。

只有在控制进程确实在部署脚本写出 `RUN_DIR/run.env` 之前中断、且 release
已经完成安装的恢复场景，才允许使用上面的 `--resume`。如果已有 `run.env`
或已经开始 activation/contract/workload，则必须按本轮证据收集和冷重置流程处理，
不能用 `--resume` 重建身份。

reset 脚本清理 16 个核心数据 PVC：Oxia 3、BookKeeper 12、
SeaweedFS 1。VMSingle 和 Grafana 的监控持久化卷不在该集合中。如果正式
定义要求每轮同时清空历史监控数据，必须先扩展 reset 脚本并验证安全擦除，
不能只删除 PV 对象。

因为 namespace 固定为共享的 `pulsar`：

- 不要执行 `kubectl delete namespace pulsar`；
- 不要在每轮卸载 `pulsar/omb`；
- 整个 campaign 结束后才执行 `helm uninstall omb -n pulsar`。
