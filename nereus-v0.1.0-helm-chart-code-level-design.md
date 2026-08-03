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

# Nereus v0.1.0 性能基线 Kubernetes / Helm Chart 代码级详细设计（最终版）

- **状态**：Final Design
- **目标用途**：Nereus v0.1.0 五组性能对比实验的可重复 Kubernetes 部署
- **Helm 仓库**：`Denovo1998/pulsar-helm-chart`
- **Helm 分支**：`nereus`
- **Nereus 仓库**：`nereusstream/nereus`
- **Nereus 代码线**：直接修改 `v0.1.0` 维护分支，不新增 `v0.1.1`
- **Pulsar fork 基线**：`nereusstream/pulsar@5ffc2caa0e08dac95bc8c2ea76ed3d32382dfe3e`
- **最终 Pulsar fork**：`nereusstream/pulsar@50fc70fe4620febcf0fd31d97ff7d2be447af3d4`
- **原始 Nereus 基线**：`81a1fa83e9aa4275229226cb895c72a6ea20ca87`
- **最终 Nereus v0.1.0 源码**：`nereusstream/nereus@78a1544596af3c74ec1f3ce8b6194f015f6a2c9a`
- **Apache Pulsar 镜像**：
  `nereus-benchmark/pulsar:5.0.0-m1-apache-p8dae0236-amd64`
- **原始 Nereus Pulsar 镜像**：
  `nereus-benchmark/pulsar:5.0.0-m1-nereus-p5ffc2caa-n81a1fa83-amd64`
- **最终 Nereus Pulsar 计划镜像 tag（尚待构建并记录 digest）**：
  `nereus-benchmark/pulsar:5.0.0-m1-nereus-p50fc70fe-n78a15445-amd64`
- **对象存储**：SeaweedFS 4.29，单节点 `weed mini`
- **对象存储调度节点**：`workload=apps`
- **Pulsar/Oxia/BookKeeper 调度节点**：`workload=pulsar`

> 本设计不提升 Nereus 的版本号。部署能力补丁直接提交到 `v0.1.0`
> 代码线；最终实验身份写成 `Nereus v0.1.0@<commit-sha>`。
> 原始 `n81a1fa83` 镜像在补丁完成后只作为历史构建基线，正式 B–E
> 运行必须使用包含最终 v0.1.0 commit 的新镜像 tag。

---

# 1. 最终决策摘要

本次实现采用以下不可变决策：

1. 保持一个 Helm Chart，通过 common values 和 A–E stage overlay 驱动五组实验。
2. 不在 Chart 中嵌入 MinIO。
3. 对象存储统一使用 **SeaweedFS 4.29 `weed mini`**。
4. SeaweedFS 以单副本 StatefulSet 运行在 `workload=apps` 节点。
5. SeaweedFS 数据写入专用 local PVC，不与 containerd、系统盘或 OMB 结果盘共用。
6. SeaweedFS 在 A–E 五组中始终运行，避免改变集群拓扑。
7. Pulsar control-plane、BookKeeper metadata 和 Nereus metadata 使用同一套 Oxia server，但分别位于：
   - `broker`
   - `bookkeeper`
   - `nereus`
8. stock ManagedLedger BookKeeper 和 Nereus BookKeeper primary-WAL 都固定为 `3/3/2`。
9. 第一轮性能测试禁用 Nereus physical GC 和 Nereus BookKeeper ledger GC。
10. Nereus v0.1.0 代码线只补部署能力：
   - environment secret resolver；
   - 独立 `nereus-admin` bootstrap / contract CLI；
   - SeaweedFS S3 compatibility gate。
11. Nereus Pulsar fork不修改 Broker Java 数据路径；只补齐 readiness 和
    generation registration backfill 的只读/受控管理入口。
12. Pulsar fork和 Nereus v0.1.0 都以最终 commit SHA重新构建 distribution image。
13. BookKeeper ledger-id namespace reservation 由独立 Job 在 Broker runtime 完成初始化前创建。
14. publication/generation activation 由显式脚本执行，不放入 Helm hook。
15. A–E 每轮都执行完整冷启动：上一轮 Helm release、Oxia metadata、
    BookKeeper journal/ledger/index、SeaweedFS object 和全部数据 PVC 必须清理；
    同时使用全新的测试 namespace/topic，禁止在线切换已创建 topic 的 Nereus
    profile。
16. 任何正式结果必须记录源码 SHA、容器 imageID/digest、渲染后 manifest hash 和运行证据。
17. Nereus/Oxia 不限制 Pulsar load manager 实现；`ModularLoadManagerImpl`
    和 `ExtensibleLoadManagerImpl` 都通过 Pulsar `MetadataStore` 抽象访问
    metadata，均属于支持配置。性能实验可以固定其中一种以控制变量，但 Chart
    不得把该实验选择升级为兼容性校验。

---

# 2. 是否需要修改源码

## 2.1 修改矩阵

| 代码库 | 是否修改 | 修改性质 |
|---|---:|---|
| `nereusstream/nereus` 的 v0.1.0 代码线 | 是 | 部署能力补丁，不改变数据协议和热路径 |
| `nereusstream/pulsar` Java 源码 | 是 | 不改消息数据热路径；补双 load manager capability 发布、MetadataStore readiness 和管理入口 |
| Nereus Pulsar 镜像构建 | 是 | 将修改后的 v0.1.0 JAR 打入最终 Pulsar fork commit |
| `Denovo1998/pulsar-helm-chart` `nereus` 分支 | 是 | 主要实施范围 |
| OMB/benchmark 仓库 | 本文不实施 | 后续增加 storage class、seed、correctness |

## 2.2 Nereus v0.1.0 的修改边界

允许修改：

```text
Secret 解析
部署 CLI
bootstrap orchestration
对象存储兼容性测试
构建和镜像包装
```

禁止借本次性能部署修改：

```text
append 状态机
read 状态机
commit/CAS 协议
ObjectKey 格式
Oxia record/codec
BookKeeper ledger metadata 格式
ManagedLedger Position/MessageId
profile completion 语义
ACK 时机
materialization planner/worker 逻辑
```

因此，最终性能结果仍属于 Nereus v0.1.0 的存储实现，只是基于 v0.1.0
分支上的部署补丁 commit。

## 2.3 Nereus Pulsar 的最小 Java 改动边界

现有 Pulsar fork 已经支持：

```text
managedLedgerStorageClassName
nereusEnabled
nereusRuntimeProviderClassName
nereusOxiaServiceAddress
nereusOxiaNamespace
nereusObjectStoreProviderClassName
nereusObjectStoreEndpoint
nereusObjectStoreRegion
nereusObjectStoreBucket
nereusObjectStorePrefix
nereusObjectStorePathStyleAccess
nereusObjectStoreSecretResolverClassName
nereusDefaultStorageProfile
nereusGenerationProtocolEnabled
nereusBookKeeperPrimaryWalEnabled
完整 BookKeeper WAL/GC typed fields
```

现有 hybrid storage provider也已经暴露：

```text
bookkeeper
nereus
```

并保持默认 storage class 为 `bookkeeper`。因此：

- A：Apache image；
- B：Nereus image + namespace storage class `bookkeeper`；
- C–E：Nereus image + namespace storage class `nereus`；

无需再修改 Broker/ManagedLedger/PersistentTopic 数据路径。

但现有 fork 仅把 generation backfill 暴露为
`NereusManagedLedgerStorage.runGenerationRegistrationBackfill(...)` Java 方法，
集群外脚本无法安全调用。为了让第 22 节成为可执行门禁，Pulsar fork必须增加
以下 broker admin API：

```text
GET  /admin/v2/brokers/bookkeeper-primary-wal/readiness
GET  /admin/v2/brokers/generation-protocol/readiness
POST /admin/v2/brokers/generation-protocol/registration-backfill
```

这些 API：

- 复用 `NereusManagedLedgerStorage` 和现有 capability coordinator；
- 继续执行 superuser 校验；
- publication mutation 在服务端重新读取两次稳定 broker snapshot，不允许调用方
  伪造 readiness：首次激活只接受当前 generation readiness；Broker 重启并安装
  durable BookKeeper binding 后只接受当前 BookKeeper primary-WAL readiness；
- 不允许调用方伪造并发度或 backfill 覆盖摘要；
- generation backfill 只接受合法的 `runId`，其余参数使用 broker typed config；
- 只有 backfill、proof installation 和 generation publication activation 全部成功后
  才返回成功；
- 不修改 append/read/commit/CAS、topic ownership 或 load-balancing 算法。

Readiness 不能依赖某一种 load manager 的 Java registry。Broker 在
`/loadbalance/brokers/<broker-id>` 写入的两种记录都携带同一组 Nereus 保留属性：

```text
ModularLoadManagerImpl   -> LocalBrokerData.properties
ExtensibleLoadManagerImpl -> BrokerLookupData.properties
```

Nereus capability coordinator 通过 Pulsar `MetadataStore` 直接读取该路径，解析
两种 record 的公共身份字段：

```text
brokerId
persistentTopicsEnabled
startTimestamp
properties
```

它不参与 broker 选择、bundle ownership 或 unload 决策。MetadataStore
notification 只用于使进程内 readiness cache 失效。Generation backfill 的资源
依赖在 `PulsarService` 的通用启动路径挂接，不依赖
`BrokerRegistryImpl`，因此 Modular 和 Extensible 使用同一套 readiness 与
activation 管理面语义。

---

# 3. 版本与分支政策

## 3.1 不新增版本号

最终版本策略：

```text
产品版本：v0.1.0
代码身份：v0.1.0@78a1544596af3c74ec1f3ce8b6194f015f6a2c9a
Pulsar 身份：5.0.0-M1-nereus@50fc70fe4620febcf0fd31d97ff7d2be447af3d4
镜像身份：p50fc70fe + n78a15445
```

不创建：

```text
v0.1.1
0.1.1-SNAPSHOT
```

## 3.2 不移动历史 release tag

如果远程已有不可变的 `v0.1.0` tag 指向 `81a1fa83`：

- 不 force-move tag；
- 从该 tag 切出并维护 v0.1.0 release branch；
- 性能报告以 branch commit SHA 为真实身份；
- 文档中写 `v0.1.0 branch build`，而不是声称仍是原 tag 字节级产物。

推荐分支命名按实际仓库决定：

```text
v0.1.0
```

若 Git 托管平台不允许与 tag 同名，则使用：

```text
release/v0.1.0
```

但 Gradle/Maven/产品展示版本仍保持 `v0.1.0`。

## 3.3 镜像命名

Apache image保持：

```text
nereus-benchmark/pulsar:
5.0.0-m1-apache-p8dae0236-amd64
```

修改后的 Nereus image：

```text
nereus-benchmark/pulsar:
5.0.0-m1-nereus-p50fc70fe-n78a15445-amd64
```

独立 admin image：

```text
nereus-benchmark/nereus-admin:
v0.1.0-n78a15445-amd64
```

SeaweedFS 本地冻结 image：

```text
nereus-benchmark/seaweedfs:
4.29-amd64
```

每个本地 tag 都必须额外记录：

```text
containerd image ID
RepoDigest（若有）
导入 archive SHA-256
源镜像或构建产物 SHA-256
```

---

# 4. 最终部署拓扑

本设计假设 `workload=pulsar` 和 `workload=apps` 节点属于同一个 Kubernetes
集群。

```text
Kubernetes cluster
|
+-- workload=pulsar
|   |
|   +-- Pulsar Broker x 3
|   +-- BookKeeper Bookie x 4
|   +-- AutoRecovery x 1
|   +-- Oxia Server x 3
|   +-- Oxia Coordinator x 1
|   +-- Pulsar/BookKeeper init Jobs
|   +-- Nereus namespace bootstrap Job
|
+-- workload=apps
    |
    +-- SeaweedFS weed mini StatefulSet x 1
    +-- SeaweedFS local PVC
    +-- 可选 OMB worker
```

数据路径：

```text
Producer
  -> Pulsar Broker
  -> BookKeeper WAL
  -> Oxia metadata CAS
  -> SeaweedFS S3 endpoint
  -> workload=apps local disk
```

SeaweedFS Service：

```text
http://<release>-seaweedfs:8333
```

SeaweedFS Prometheus：

```text
http://<pod>:9327/metrics
```

## 4.1 两类节点标签

Pulsar 节点：

```bash
kubectl label node <PULSAR_NODE> workload=pulsar --overwrite
```

App 节点：

```bash
kubectl label node <APPS_NODE> workload=apps --overwrite
kubectl label node <APPS_NODE> nereus-object-store=true --overwrite
```

正式 benchmark 要求恰好一个可调度且 Ready 的 `workload=pulsar` 主节点，以及
恰好一个不同的、可调度且 Ready 的
`workload=apps,nereus-object-store=true` 子节点。Broker、BookKeeper、
AutoRecovery、Oxia、Toolset、Pulsar/BookKeeper init Job、Nereus admin Job
和 VictoriaMetrics/Grafana 监控栈全部固定在主节点；只有 SeaweedFS
StatefulSet 固定在子节点。部署 preflight 和部署后 gate 都必须拒绝标签数量或
实际 Pod 落点不符合该拓扑的环境。

可选 taint：

```bash
kubectl taint node <PULSAR_NODE> dedicated=pulsar:NoSchedule
kubectl taint node <APPS_NODE> dedicated=apps:NoSchedule
```

## 4.2 单节点对象存储的含义

当前 SeaweedFS 模式是：

```text
single process
single pod
single PVC
replication=000
```

它适合实验，不提供生产级对象存储 HA。性能报告必须声明：

```text
single-node SeaweedFS laboratory object store
```

不能将 Broker failover 测试等同于对象存储节点故障容忍测试。

---

# 5. SeaweedFS 选择与固定配置

## 5.1 选择理由

SeaweedFS 4.29 提供：

- Apache-2.0；
- 活跃维护；
- S3-compatible API；
- `weed mini` 单进程模式；
- 环境变量配置 access key/secret key；
- `S3_BUCKET` 启动时创建 bucket；
- S3 endpoint 8333；
- Prometheus metrics port；
- Range GET、ETag、ListObjectsV2 和 user metadata；
- 条件 PUT/DELETE 实现路径。

本设计不依赖 SeaweedFS 的“完全 S3 兼容”宣传，所有 Nereus 实际依赖语义都要通过 contract gate。

## 5.2 固定运行参数

SeaweedFS StatefulSet容器启动命令：

```yaml
command:
   - weed

args:
   - mini
   - -dir=/data
   - -ip.bind=0.0.0.0
   - -metricsPort=9327
   - -metricsIp=0.0.0.0
   - -webdav=false
   - -admin.ui=false
   - -s3.port.iceberg=0
   - -master.telemetry=false
   - -master.defaultReplication=000
   - -master.volumeSizeLimitMB=1024
   - -filer.maxMB=64
   - -volume.index=memory
```

端口：

```text
8333  S3
9327  Prometheus
9333  Master（不通过 Service 对外暴露）
9340  Volume（不通过 Service 对外暴露）
8888  Filer（不通过 Service 对外暴露）
```

环境变量：

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
S3_BUCKET
```

默认 bucket：

```text
nereus-benchmark
```

## 5.3 为什么关闭 WebDAV 和 Admin UI

`weed mini` 默认会启动额外服务。性能基线中关闭：

```text
WebDAV
Admin UI
Iceberg REST Catalog
telemetry
```

原因：

- 避免无关 goroutine/HTTP listener；
- 减少额外周期任务；
- 降低端口和安全面；
- 保持对象存储只承担 Nereus S3 路径。

## 5.4 SeaweedFS 持久卷

StorageClass 由 Helm release 外部创建：

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
   name: local-seaweedfs
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
```

PersistentVolume：

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
   name: nereus-seaweedfs-pv
spec:
   capacity:
      storage: 500Gi
   volumeMode: Filesystem
   accessModes:
      - ReadWriteOnce
   persistentVolumeReclaimPolicy: Retain
   storageClassName: local-seaweedfs
   local:
      path: /mnt/nereus-seaweedfs
   nodeAffinity:
      required:
         nodeSelectorTerms:
            - matchExpressions:
                 - key: workload
                   operator: In
                   values:
                      - apps
                 - key: nereus-object-store
                   operator: In
                   values:
                      - "true"
```

目录必须位于专用数据盘：

```text
/mnt/nereus-seaweedfs
```

不得指向：

```text
/
/var/lib/containerd
OMB raw result directory
系统日志盘
```

---

# 6. Nereus v0.1.0 源码改造

## 6.1 文件变更清单

```text
nereus/
├── settings.gradle.kts                                      # 修改
├── nereus-object-store/
│   └── src/
│       ├── main/java/com/nereusstream/objectstore/
│       │   └── EnvironmentObjectStoreSecretResolver.java   # 新增
│       └── test/java/com/nereusstream/objectstore/
│           └── EnvironmentObjectStoreSecretResolverTest.java
│
├── nereus-admin/                                            # 新增模块
│   ├── build.gradle.kts
│   ├── src/main/java/com/nereusstream/admin/
│   │   ├── NereusAdminMain.java
│   │   ├── CommandLineArguments.java
│   │   ├── AdminExitCode.java
│   │   ├── AdminFailureClassifier.java
│   │   ├── AdminEvidenceWriter.java
│   │   ├── AdminConfiguration.java
│   │   ├── BookKeeperNamespaceCommand.java
│   │   ├── BookKeeperActivationReadCommand.java
│   │   └── ObjectStoreContractCommand.java
│   └── src/test/java/com/nereusstream/admin/
│       ├── NereusAdminMainTest.java
│       ├── CommandLineArgumentsTest.java
│       ├── AdminConfigurationTest.java
│       ├── AdminFailureClassifierTest.java
│       ├── BookKeeperNamespaceCommandTest.java
│       └── ObjectStoreContractCommandTest.java
│
├── docker/
│   └── nereus-admin/
│       └── Dockerfile
│
└── docs/performance/
    ├── pulsar-5.0.0-M1-baselines.md
    └── pulsar-5.0.0-M1-images.md
```

## 6.2 `settings.gradle.kts`

新增：

```kotlin
include("nereus-admin")
```

保持项目版本仍为 v0.1.0，不增加新版本。

---

# 7. Environment Secret Resolver 详细设计

## 7.1 目标

通过一个统一 resolver 支持：

```text
SeaweedFS access key
SeaweedFS secret key
可选 session token
Nereus BookKeeper ledger password
```

Secret reference 的值不是 secret 本身，而是环境变量名：

```text
NEREUS_S3_ACCESS_KEY
NEREUS_S3_SECRET_KEY
NEREUS_BK_PASSWORD
```

所有 reference 必须匹配 Kubernetes env name
`^[A-Za-z_][A-Za-z0-9_]*$` 且互不重复。Broker、initContainer 和临时
admin Job 的 `env[].name` 必须直接使用这些 reference；不得在 Pod template
中重新硬编码默认名称，否则自定义 reference 会解析不到对应 Secret。

## 7.2 实现

文件：

```text
nereus-object-store/src/main/java/
com/nereusstream/objectstore/EnvironmentObjectStoreSecretResolver.java
```

实现：

```java
/* Licensed under the Apache License, Version 2.0 */
package com.nereusstream.objectstore;

import java.util.Objects;
import java.util.Optional;
import java.util.function.Function;

/**
 * Resolves deployment secret references from process environment variables.
 *
 * <p>The reference is the exact environment-variable name. Values are copied
 * into a new char array and are never cached by this resolver.
 */
public final class EnvironmentObjectStoreSecretResolver
        implements ObjectStoreSecretResolver {

   private final Function<String, String> environment;

   public EnvironmentObjectStoreSecretResolver() {
      this(System::getenv);
   }

   EnvironmentObjectStoreSecretResolver(
           Function<String, String> environment) {
      this.environment = Objects.requireNonNull(
              environment, "environment");
   }

   @Override
   public Optional<char[]> resolve(String secretReference) {
      if (secretReference == null || secretReference.isBlank()) {
         return Optional.empty();
      }

      String value = environment.apply(secretReference);
      if (value == null || value.isEmpty()) {
         return Optional.empty();
      }

      return Optional.of(value.toCharArray());
   }
}
```

## 7.3 约束

Resolver 必须：

- 不缓存 secret；
- 每次返回新的 `char[]`；
- 不 trim secret value；
- 不输出 secret；
- 不在异常消息中包含 value；
- blank reference 返回 empty；
- 环境变量不存在返回 empty；
- 允许调用方在使用后覆写数组。

## 7.4 测试

```java
@Test
void resolvesExactEnvironmentVariable() { ... }

@Test
void missingVariableReturnsEmpty() { ... }

@Test
void blankReferenceReturnsEmpty() { ... }

@Test
void returnsFreshArrayForEveryResolution() { ... }

@Test
void preservesWhitespaceInsideSecretValue() { ... }
```

---

# 8. `nereus-admin` 模块设计

## 8.1 目标

解决两个 Helm 无法安全完成的前置任务：

1. Broker 启动前 provision/verify BookKeeper ledger-id namespace；
2. 使用 Nereus 自己的 S3 provider验证 SeaweedFS 语义。

## 8.2 为什么使用独立镜像

不把 CLI 放进 Broker 主进程，原因：

- 避免改 Pulsar Java 源码；
- bootstrap 与 Broker 生命周期分离；
- 减少 Broker image 内脚本耦合；
- 可以在 Broker 尚未启动时执行；
- Job 日志即为独立证据；
- admin image 可在 `workload=pulsar` 节点执行。

## 8.3 `build.gradle.kts`

```kotlin
plugins {
   application
}

dependencies {
   implementation(project(":nereus-api"))
   implementation(project(":nereus-bookkeeper"))
   implementation(project(":nereus-metadata-oxia"))
   implementation(project(":nereus-object-store"))
   implementation(project(":nereus-pulsar-adapter"))

   implementation(platform(libs.grpc.bom))
   implementation(libs.oxia.client)

   testImplementation(libs.junit.jupiter)
   testImplementation(libs.assertj)
   testRuntimeOnly(libs.junit.platform.launcher)
}

application {
   mainClass.set("com.nereusstream.admin.NereusAdminMain")
}

tasks.test {
   useJUnitPlatform()
}
```

不引入 Picocli，命令集合很小，使用严格的内部参数解析器，减少新增依赖。

## 8.4 命令集合

```text
nereus-admin bookkeeper namespace ensure
nereus-admin bookkeeper namespace verify
nereus-admin bookkeeper activation read
nereus-admin object-store verify
nereus-admin object-store contract
nereus-admin object-store persistence create
nereus-admin object-store persistence verify
nereus-admin object-store persistence cleanup
```

统一参数：

```text
--config <properties-file>
--timeout-seconds <positive-long>
--output <optional-json-file>
--run-id <lowercase-base32-id; persistence commands only>
```

## 8.5 配置文件

Helm 生成只含非 secret 值的 properties：

```properties
cluster=beijing-1

oxia.serviceAddress=pulsar-oxia-svc:6648
oxia.namespace=nereus
oxia.sessionTimeoutSeconds=30
oxia.maxPendingOperations=1024

objectStore.providerClassName=\
com.nereusstream.objectstore.S3CompatibleObjectStoreProvider
objectStore.endpoint=http://pulsar-seaweedfs:8333
objectStore.region=us-east-1
objectStore.bucket=nereus-benchmark
objectStore.prefix=v0.1.0
objectStore.pathStyleAccess=true
objectStore.requestTimeoutSeconds=30
objectStore.maxConnections=64
objectStore.secretResolverClassName=\
com.nereusstream.objectstore.EnvironmentObjectStoreSecretResolver
objectStore.accessKeySecretRef=NEREUS_S3_ACCESS_KEY
objectStore.secretKeySecretRef=NEREUS_S3_SECRET_KEY

bookkeeper.deploymentId=nereus-v010-benchmark
bookkeeper.providerScopeSha256=<64-lowercase-hex>
bookkeeper.ledgerIdPrefixBits=12
bookkeeper.ledgerIdPrefixValue=2049
bookkeeper.reservationId=<fixed-id>
bookkeeper.ensembleSize=3
bookkeeper.writeQuorumSize=3
bookkeeper.ackQuorumSize=2
bookkeeper.digestType=CRC32C
bookkeeper.passwordSecretRef=NEREUS_BK_PASSWORD
bookkeeper.passwordIdentityVersion=v1

operatorEvidenceSha256=<64-lowercase-hex>
```

ConfigMap 中不包含：

```text
access key value
secret key value
BookKeeper password value
```

## 8.6 CLI 参数解析

`CommandLineArguments` 要求：

- 未知命令失败；
- 未知 option 失败；
- 重复 option 失败；
- 缺少 option value 失败；
- timeout 必须为正数；
- config 必须为绝对或可读路径；
- 不从环境隐式推断非 secret 配置；
- 未知 properties key 失败，避免拼写错误静默回落到默认值；
- exit code稳定。

Exit code：

```java
public enum AdminExitCode {
   SUCCESS(0),
   INVALID_ARGUMENT(2),
   CONFIGURATION_ERROR(3),
   CONDITION_FAILED(4),
   TIMEOUT(5),
   PROVIDER_ERROR(6),
   INTERNAL_ERROR(10);
}
```

`AdminFailureClassifier` 必须递归展开 `ExecutionException` /
`CompletionException`。底层 `TimeoutException` 或 Nereus `TIMEOUT` 错误统一返回
`TIMEOUT(5)`；BookKeeper ensure/verify/read、Object Store verify/contract 和
persistence create/verify/cleanup 都不得把超时降级成普通 condition/provider
失败。Object Store contract 观察到首次 timeout 后立即停止后续语义检查，
不再用同一个已耗尽的 deadline 尝试 cleanup，并在证据中记录
`cleanupSkippedAfterTimeout=true`。证据只写安全错误摘要，不打印可能包含
provider 细节的完整堆栈。

## 8.7 Namespace ensure

核心伪代码：

```java
public AdminEvidence ensure(
        AdminConfiguration configuration,
        Duration timeout) throws Exception {

   Clock clock = Clock.systemUTC();

   OxiaClientConfiguration oxia =
           configuration.toOxiaClientConfiguration(timeout);

   NereusBookKeeperRuntimeConfiguration bookKeeper =
           configuration.toBookKeeperRuntimeConfiguration();

   try (SharedOxiaClientRuntime runtime =
                SharedOxiaClientRuntime.connect(oxia, clock)) {

      BookKeeperPrimaryWalAdministration admin =
              BookKeeperPrimaryWalAdministration.usingSharedRuntime(
                      bookKeeper,
                      oxia,
                      runtime,
                      clock);

      BookKeeperLedgerIdNamespaceReservation reservation =
              admin.provisionNamespace(
                              configuration.operatorEvidenceSha256(),
                              timeout)
                      .get(timeout.toMillis(),
                              TimeUnit.MILLISECONDS);

      return AdminEvidence.from(reservation);
   }
}
```

现有 provisioning coordinator本身已具备精确幂等语义：

- record 不存在：create；
- record 存在且 identity 完全相同：返回 existing；
- 任意 identity 冲突：fail closed；
- 不覆盖 REVOKED/foreign reservation。

## 8.8 Namespace verify

`verify` 不做 mutation：

```text
读取 reservation
校验 lifecycle=ACTIVE
校验 deploymentId
校验 cluster alias
校验 providerScopeSha256
校验 prefix bits/value
校验 reservationId
校验 operator evidence
```

Broker initContainer循环调用 `verify`，直到成功或超时。

## 8.9 Activation read

输出当前：

```text
presence
metadataVersion
readinessEpoch
readinessSha256
WAL_ONLY publication bit
ASYNC publication bit
SYNC publication bit
publicationActivationSha256
ledgerDeletionEnabled
```

该命令只读，不负责 activate。

## 8.10 Evidence JSON

成功示例：

```json
{
   "schemaVersion": 1,
   "command": "bookkeeper namespace ensure",
   "status": "ACTIVE",
   "cluster": "beijing-1",
   "deploymentId": "nereus-v010-benchmark",
   "providerScopeSha256": "...",
   "ledgerIdPrefixBits": 12,
   "ledgerIdPrefixValue": 2049,
   "reservationId": "...",
   "ledgerIdNamespaceSha256": "...",
   "metadataVersion": 1,
   "completedAtEpochMillis": 1784970000000
}
```

禁止输出 secret value。

---

# 9. SeaweedFS Object Store Contract 设计

## 9.1 Nereus 依赖的 S3 语义

当前 Nereus provider依赖：

```text
HeadBucket
PutObject
If-None-Match: *
ETag
x-amz-meta-* user metadata
HeadObject
Range GET with 206
Content-Range exactness
ListObjectsV2
continuationToken
DeleteObject
If-Match delete
```

## 9.2 Contract command

```text
nereus-admin object-store contract
```

使用 `S3CompatibleObjectStoreProvider` 和 `ObjectStore` API，而不是 AWS CLI，
确保验证的正是 Nereus 生产路径。

临时前缀：

```text
__nereus_contract/v1/<run-id>/
```

流程：

```text
1. provider.create -> HeadBucket
2. PUT object A with ifAbsent=true
3. HEAD object A
4. range read [0, N)
5. range read middle segment
6. duplicate conditional PUT on A
7. concurrent conditional PUT race on object B
8. create enough objects to force paginated LIST
9. LIST all pages and verify no duplicates/missing
10. DELETE A with wrong ETag
11. HEAD A must still exist
12. DELETE A with correct ETag
13. HEAD A must be not found
14. cleanup contract prefix
```

## 9.3 验收条件

```text
headBucketSuccess=true
conditionalCreateSingleWinner=true
duplicatePutRejected=true
metadataRoundTrip=true
etagPresent=true
rangeStatusSemantics=true
rangeChecksumValid=true
listNoDuplicates=true
listNoMissing=true
wrongEtagDeletePreservesObject=true
correctEtagDeleteRemovesObject=true
```

任何一项失败，D/E 不允许开始正式压测。

## 9.4 重启持久性门禁

外部脚本执行：

```text
object-store persistence create --run-id <lowercase-base32-id>
kubectl rollout restart statefulset/<release>-nereus-seaweedfs
wait Ready
object-store persistence verify --run-id <same-id>
object-store persistence cleanup --run-id <same-id>
```

三个命令都走与生产数据路径相同的 `ObjectStoreProvider`，并分别输出 JSON
证据。`create` 使用 conditional PUT；`verify` 校验 length、checksum、
user metadata 和完整 payload，且不得删除对象；`cleanup` 使用 HEAD 返回的
exact identity做 conditional delete。脚本只有在完整 contract 与重启持久性门禁
都成功后才返回 `0`。

每个临时 admin Job 的 `activeDeadlineSeconds` 必须比 CLI timeout 多 120 秒，
为调度、镜像启动和证据写出留出边界；不能把两者设为同一个值，否则 kubelet
可能在 CLI 返回稳定 `TIMEOUT(5)` 与 JSON 证据之前先终止 Pod。
成功路径同时使用 `--output /dev/termination-log`；脚本从已完成 container 的
termination message 提取纯 JSON，不把依赖库日志当作结构化证据。失败路径仍
采集 Pod describe/logs 用于诊断。

Stage B–E 的 `verify-nereus-release.sh` 必须 fail-closed：完整 contract、
persistence create、SeaweedFS restart 后 persistence verify 和 cleanup 四份
成功证据缺少任何一份，都不能声明 release verification 通过。

确认重启后：

```text
object bytes
length
ETag
user metadata
list visibility
```

均保持一致。

---

# 10. `nereus-admin` 镜像

## 10.1 Dockerfile

```dockerfile
FROM <SAME_PINNED_JRE21_BASE_AS_BROKER>

ARG NEREUS_COMMIT
LABEL org.opencontainers.image.version="v0.1.0"
LABEL org.opencontainers.image.revision="${NEREUS_COMMIT}"

WORKDIR /opt/nereus-admin

COPY nereus-admin/build/install/nereus-admin/ /opt/nereus-admin/

USER 10000:0

ENTRYPOINT ["/opt/nereus-admin/bin/nereus-admin"]
```

要求：

- 与 Broker 使用同一 JDK major；
- 使用非 root 用户；
- image label记录 Nereus SHA；
- 不包含凭证；
- 构建后保存 imageID、native inspect、digest listing 和 checksummed manifest。
  SBOM 如需纳入 campaign 证据，使用集群现有的 SBOM 工具另行生成并校验，
  不允许在无产物时把它列为已完成证据。

## 10.2 构建

```bash
./scripts/build-pulsar-5.0.0-M1-images.sh \
  --pulsar-repo /path/to/nereusstream/pulsar \
  --worktree-root /path/to/pulsar-worktrees \
  --nereus-pulsar-ref 50fc70fe4620febcf0fd31d97ff7d2be447af3d4 \
  --nereus-source-ref 78a1544596af3c74ec1f3ce8b6194f015f6a2c9a \
  --admin-base-image \
    'eclipse-temurin:21-jre-noble@sha256:<PINNED_DIGEST>'
```

该脚本是三个 campaign image 的唯一权威构建入口。它拒绝 dirty/untracked
Nereus 和 Pulsar checkout，校验 `pulsarExpectedHead`，使用两个 detached
Pulsar worktree，并通过 nerdctl 直接写入 containerd。admin Dockerfile 不提供
可变 base image 默认值；脚本必须传入 digest-pinned JRE 21 image。三个本地
image 全部通过离线 smoke 后，`--push` 才允许向 registry 发布。

---

# 11. Nereus Pulsar 镜像处理

## 11.1 Pulsar fork 增加 load-manager-independent 控制面集成

基线保持：

```text
nereusstream/pulsar@5ffc2caa0e08dac95bc8c2ea76ed3d32382dfe3e
```

在该分支增加第 2.3 节定义的最小控制面补丁，并形成：

```text
nereusstream/pulsar@50fc70fe4620febcf0fd31d97ff7d2be447af3d4
```

补丁包括：

```text
LocalBrokerData.properties
ModularLoadManagerImpl capability properties 发布
ExtensibleLoadManagerImpl 现有 BrokerLookupData.properties 发布
Nereus capability coordinator 通过 MetadataStore 读取两类公共记录
PulsarService 通用启动路径挂接 local broker identity 和 generation backfill
readiness/backfill broker admin API
publication mutation 的服务端 readiness 防伪校验
```

这些修改属于 broker registration、readiness 和 rollout 管理控制面；不修改
append/read/commit/CAS、topic ownership、bundle placement 或消息数据热路径。
最终镜像和证据必须记录 `50fc70fe4620febcf0fd31d97ff7d2be447af3d4`，不能继续把 `5ffc2caa` 声称为
最终源码身份。

## 11.2 重新构建原因

Broker 必须包含新类：

```text
com.nereusstream.objectstore.EnvironmentObjectStoreSecretResolver
```

因此原始：

```text
...-n81a1fa83-amd64
```

不能作为最终 B–E image。

最终 image：

```text
nereus-benchmark/pulsar:
5.0.0-m1-nereus-p50fc70fe-n78a15445-amd64
```

## 11.3 构建不变量

除 Nereus JAR commit 和第 11.1 节的控制面补丁外保持不变：

```text
base image
JDK/JVM
native libraries
bookkeeper binaries
entrypoint
container user
build architecture
```

构建证据记录：

```text
Pulsar SHA
Nereus SHA
Nereus adapter JAR SHA-256
admin base image digest
Apache/Nereus Pulsar/admin Dockerfile SHA-256
imageID
native image inspect/digest listing
checksummed build manifest
archive SHA
```

最终 gate 的 Pulsar source lock 必须同时拒绝 tracked 和 untracked 文件。
否则 Gradle 可能编译未提交源码，而 gate 结果不能由
`50fc70fe4620febcf0fd31d97ff7d2be447af3d4` 重建。最终封板顺序固定为：

```text
commit Pulsar -> 更新 pulsarExpectedHead -> commit Nereus
-> 两个 clean commit 运行 final gate -> clean gated commits 构建镜像
```

如果 final gate 后修改任一源码，必须先形成新 commit，再从新的两个 clean
commit 重跑完整 gate；不得把旧 gate 结果转移到新 SHA。

---

# 12. Helm Chart 文件改造清单

```text
pulsar-helm-chart/
├── charts/pulsar/
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── templates/
│   │   ├── _oxia.tpl
│   │   ├── _nereus_validation.tpl
│   │   ├── nereus-validation.yaml
│   │   ├── broker-configmap.yaml
│   │   ├── broker-statefulset.yaml
│   │   ├── nereus-seaweedfs-headless-service.yaml
│   │   ├── nereus-seaweedfs-service.yaml
│   │   ├── nereus-seaweedfs-statefulset.yaml
│   │   ├── nereus-seaweedfs-podmonitor.yaml
│   │   ├── nereus-admin-configmap.yaml
│   │   ├── nereus-bookkeeper-bootstrap-job.yaml
│   │   └── NOTES.txt
├── examples/nereus-benchmark/
│   ├── README.md
│   ├── values-common.yaml
│   ├── values-campaign.example.yaml
│   ├── values-stage-a-apache.yaml
│   ├── values-stage-b-dormant.yaml
│   ├── values-stage-c-bk-only.yaml
│   ├── values-stage-d-bk-async-object.yaml
│   ├── values-stage-e-bk-sync-object.yaml
│   ├── secrets.example.yaml
│   └── storage/
│       ├── local-seaweedfs-storage-class.yaml
│       └── local-seaweedfs-pv.example.yaml
│
└── scripts/
    ├── prepare-nereus-campaign-values.sh
    ├── deploy-nereus-stage.sh
    ├── reset-nereus-benchmark-stage.sh
    ├── activate-nereus-publications.sh
    ├── verify-nereus-release.sh
    ├── run-object-store-contract.sh
    ├── test-nereus-render.sh
    └── collect-helm-evidence.sh
```

---

# 13. `Chart.yaml`

```yaml
apiVersion: v2
name: pulsar
description: Apache Pulsar Helm chart with optional Nereus benchmark integration
type: application
version: 4.7.0-nereus.3
appVersion: "5.0.0-M1"
```

Chart version可以变更，它不是 Nereus 产品版本。

---

# 14. `values.yaml` 最终模型

根 values只增加默认关闭能力，不写真实环境值。

```yaml
oxia:
   extraNamespaces: []

   coordinator:
      # 非空时替代旧 cpuLimit/memoryLimit-only block。
      resources: {}

   server:
      # 非空时替代旧 cpuLimit/memoryLimit-only block。
      resources: {}
      # storageClassName为空时才允许走chart-wide local-storage fallback。
      local_storage: false

nereus:
   enabled: false

   managedLedgerStorageClassName:
      org.apache.pulsar.broker.storage.nereus.NereusManagedLedgerStorage

   runtimeProviderClassName:
      com.nereusstream.pulsar.DefaultNereusRuntimeProvider

   defaultStorageProfile: BOOKKEEPER_WAL_ONLY

   configData: {}

   oxia:
      serviceAddress: ""
      namespace: nereus

   secrets:
      resolverClassName:
         com.nereusstream.objectstore.EnvironmentObjectStoreSecretResolver

      existingSecret: ""

      accessKeyKey: access-key
      secretKeyKey: secret-key
      sessionTokenKey: ""
      bookKeeperPasswordKey: bookkeeper-password

      accessKeyReference: NEREUS_S3_ACCESS_KEY
      secretKeyReference: NEREUS_S3_SECRET_KEY
      sessionTokenReference: ""
      bookKeeperPasswordReference: NEREUS_BK_PASSWORD

   objectStore:
      providerClassName:
         com.nereusstream.objectstore.S3CompatibleObjectStoreProvider

      endpoint: ""
      region: us-east-1
      bucket: nereus-benchmark
      prefix: v0.1.0
      pathStyleAccess: true
      requestTimeoutSeconds: 30
      maxConnections: 64

      seaweedfs:
         enabled: false
         component: seaweedfs

         image:
            repository: nereus-benchmark/seaweedfs
            tag: 4.29-amd64
            pullPolicy: Never

         replicaCount: 1

         command:
            - weed

         args:
            - mini
            - -dir=/data
            - -ip.bind=0.0.0.0
            - -metricsPort=9327
            - -metricsIp=0.0.0.0
            - -webdav=false
            - -admin.ui=false
            - -s3.port.iceberg=0
            - -master.telemetry=false
            - -master.defaultReplication=000
            - -master.volumeSizeLimitMB=1024
            - -filer.maxMB=64
            - -volume.index=memory

         service:
            type: ClusterIP
            s3Port: 8333
            metricsPort: 9327
            annotations: {}

         nodeSelector:
            workload: apps
            nereus-object-store: "true"

         tolerations:
            - key: dedicated
              operator: Equal
              value: apps
              effect: NoSchedule

         affinity: {}
         topologySpreadConstraints: []

         resources:
            requests:
               cpu: "2"
               memory: 4Gi
            limits:
               cpu: "2"
               memory: 4Gi

         persistence:
            enabled: true
            existingClaim: ""
            storageClassName: local-seaweedfs
            accessModes:
               - ReadWriteOnce
            size: 500Gi
            selector: {}

         probes:
            startup:
               failureThreshold: 90
               periodSeconds: 2
               timeoutSeconds: 1
            readiness:
               periodSeconds: 5
               timeoutSeconds: 1
            liveness:
               periodSeconds: 10
               timeoutSeconds: 1

         podMonitor:
            enabled: true
            interval: 5s
            scrapeTimeout: 4s

   staging:
      mountPath: /pulsar/data/nereus-staging

      volume:
         type: emptyDir
         emptyDir:
            medium: ""
            sizeLimit: 20Gi
         existingClaim: ""
         hostPath: ""

   generationProtocol:
      enabled: true

   physicalGc:
      enabled: false
      dryRun: true

   bookkeeperWal:
      enabled: false

      deploymentId: ""
      providerScopeSha256: ""

      ledgerIdPrefixBits: 12
      ledgerIdPrefixValue: 2049
      ledgerIdNamespaceReservationId: ""

      ensembleSize: 3
      writeQuorumSize: 3
      ackQuorumSize: 2

      digestType: CRC32C
      passwordIdentityVersion: v1

      maxEntriesPerLedger: 100000
      maxBytesPerLedger: 268435456
      maxAppendRangesPerLedger: 1000
      protectionSlotsPerRange: 8
      maxReaderLeasesPerLedger: 64
      maxUncertainAllocations: 32
      maxLedgerAgeSeconds: 3600

      maxWritesInFlight: 1
      maxReadsInFlight: 64
      maxReadBytesInFlight: 134217728

      operationTimeoutSeconds: 30
      allocationTimeoutSeconds: 20
      sealTimeoutSeconds: 30
      deleteTimeoutSeconds: 30

      readerLeaseSeconds: 120
      readerLeaseRenewSeconds: 30
      retentionScanIntervalSeconds: 60
      retentionScanPageSize: 256

      gc:
         enabled: false
         dryRun: true
         maxConcurrentDeletes: 1
         maxClockSkewSeconds: 5
         drainGraceSeconds: 300
         lateCreateAuditGraceSeconds: 604800

   admin:
      image:
         repository: nereus-benchmark/nereus-admin
         tag: ""
         pullPolicy: Never

      timeoutSeconds: 600

      operatorEvidenceSha256: ""

      nodeSelector:
         workload: pulsar

      tolerations:
         - key: dedicated
           operator: Equal
           value: pulsar
           effect: NoSchedule

      resources:
         requests:
            cpu: 250m
            memory: 256Mi
         limits:
            cpu: "1"
            memory: 1Gi

   bootstrap:
      enabled: false
      activeDeadlineSeconds: 900
      backoffLimit: 4
      ttlSecondsAfterFinished: 3600

   brokerWait:
      objectStore: true
      bookKeeperNamespace: true
      timeoutSeconds: 600
```

---

# 15. Oxia namespace 模板

当前内建：

```text
default
broker
bookkeeper
```

新增通用 extra namespaces：

```gotemplate
{{- define "oxia.coordinator.config.yaml" -}}
namespaces:
  - name: default
    initialShardCount: {{ .Values.oxia.initialShardCount }}
    replicationFactor: {{ .Values.oxia.replicationFactor }}

  - name: broker
    initialShardCount: {{ .Values.oxia.initialShardCount }}
    replicationFactor: {{ .Values.oxia.replicationFactor }}

  - name: bookkeeper
    initialShardCount: {{ .Values.oxia.initialShardCount }}
    replicationFactor: {{ .Values.oxia.replicationFactor }}

  {{- range $index, $namespace := .Values.oxia.extraNamespaces }}
  - name: {{ required
      (printf "oxia.extraNamespaces[%d].name is required" $index)
      $namespace.name | quote }}
    initialShardCount: {{
      default $.Values.oxia.initialShardCount
      $namespace.initialShardCount }}
    replicationFactor: {{
      default $.Values.oxia.replicationFactor
      $namespace.replicationFactor }}
  {{- end }}

servers:
  # 保持现有逻辑
{{- end }}
```

禁止重复：

```gotemplate
{{- range $namespace := .Values.oxia.extraNamespaces }}
  {{- if has $namespace.name (list "default" "broker" "bookkeeper") }}
    {{- fail (printf
      "oxia.extraNamespaces cannot redefine %q"
      $namespace.name) }}
  {{- end }}
{{- end }}
```

---

# 16. `_nereus.tpl`

## 16.1 Oxia address

```gotemplate
{{- define "pulsar.nereus.oxia.serviceAddress" -}}
{{- if .Values.nereus.oxia.serviceAddress -}}
{{- .Values.nereus.oxia.serviceAddress -}}
{{- else -}}
{{- printf "%s:%d"
      (include "pulsar.oxia.server.service" .)
      (int .Values.oxia.server.ports.public) -}}
{{- end -}}
{{- end -}}
```

## 16.2 SeaweedFS fullname

```gotemplate
{{- define "pulsar.nereus.seaweedfs.fullname" -}}
{{- printf "%s-%s"
      (include "pulsar.fullname" .)
      .Values.nereus.objectStore.seaweedfs.component
    | trunc 63
    | trimSuffix "-" -}}
{{- end -}}
```

## 16.3 Object Store endpoint

```gotemplate
{{- define "pulsar.nereus.objectStore.endpoint" -}}
{{- if .Values.nereus.objectStore.endpoint -}}
{{- .Values.nereus.objectStore.endpoint -}}
{{- else if .Values.nereus.objectStore.seaweedfs.enabled -}}
{{- printf "http://%s:%d"
      (include "pulsar.nereus.seaweedfs.fullname" .)
      (int .Values.nereus.objectStore.seaweedfs.service.s3Port) -}}
{{- else -}}
{{- fail
    "nereus.objectStore.endpoint is required when SeaweedFS is disabled" -}}
{{- end -}}
{{- end -}}
```

## 16.4 Validation

核心约束：

> 这里不校验 `broker.configData.loadManagerClassName`。Nereus 依赖的是
> Pulsar 的 `MetadataStore` 抽象和 Oxia metadata store，不依赖特定 load
> manager 实现。Pulsar 5.0.0-M1 的 `ModularLoadManagerImpl` 与
> `ExtensibleLoadManagerImpl` 都可在 Oxia 部署中完成 cluster initialize。
> common values 可以为性能基线固定一种实现，但用户切换为另一种实现时 Helm
> 必须接受该配置。

只要 `nereus.enabled=true`，现有 Secret 名、access/secret key 名、环境
reference 和 admin image tag 都是必填；它们不仅服务于 BookKeeper profile，
也服务于 Object-only profile 的 Broker wait/contract Job。BookKeeper password
key 与 operator evidence 仅在 `bookkeeperWal.enabled=true` 时必填。

```gotemplate
{{- define "pulsar.nereus.validate" -}}

{{- if .Values.nereus.enabled }}

  {{- if not .Values.components.oxia }}
    {{- fail "Nereus requires components.oxia=true" }}
  {{- end }}

  {{- if not .Values.components.bookkeeper }}
    {{- fail "Nereus requires components.bookkeeper=true" }}
  {{- end }}

  {{- if not .Values.components.broker }}
    {{- fail "Nereus requires components.broker=true" }}
  {{- end }}

  {{- $profiles := list
      "OBJECT_WAL_ASYNC_OBJECT"
      "OBJECT_WAL_SYNC_OBJECT"
      "BOOKKEEPER_WAL_ONLY"
      "BOOKKEEPER_WAL_ASYNC_OBJECT"
      "BOOKKEEPER_WAL_SYNC_OBJECT" }}

  {{- if not
      (has .Values.nereus.defaultStorageProfile $profiles) }}
    {{- fail "unsupported Nereus storage profile" }}
  {{- end }}

  {{- required
      "nereus.secrets.existingSecret is required"
      .Values.nereus.secrets.existingSecret }}

  {{- if eq
      .Values.nereus.secrets.resolverClassName
      "com.nereusstream.objectstore.NoopObjectStoreSecretResolver" }}
    {{- fail
      "benchmark Nereus runtime cannot use NoopObjectStoreSecretResolver" }}
  {{- end }}

  {{- if .Values.nereus.bookkeeperWal.enabled }}

    {{- required
        "bookkeeperWal.deploymentId is required"
        .Values.nereus.bookkeeperWal.deploymentId }}

    {{- $scope := required
        "bookkeeperWal.providerScopeSha256 is required"
        .Values.nereus.bookkeeperWal.providerScopeSha256 }}

    {{- if not (regexMatch "^[0-9a-f]{64}$" $scope) }}
      {{- fail
        "providerScopeSha256 must be 64 lowercase hex" }}
    {{- end }}

    {{- required
        "ledgerIdNamespaceReservationId is required"
        .Values.nereus.bookkeeperWal.ledgerIdNamespaceReservationId }}

    {{- if lt
        (int .Values.nereus.bookkeeperWal.ensembleSize)
        (int .Values.nereus.bookkeeperWal.writeQuorumSize) }}
      {{- fail "ensembleSize must be >= writeQuorumSize" }}
    {{- end }}

    {{- if lt
        (int .Values.nereus.bookkeeperWal.writeQuorumSize)
        (int .Values.nereus.bookkeeperWal.ackQuorumSize) }}
      {{- fail "writeQuorumSize must be >= ackQuorumSize" }}
    {{- end }}

    {{- required
        "nereus.admin.image.tag is required"
        .Values.nereus.admin.image.tag }}

  {{- end }}

{{- end }}

{{- if .Values.nereus.objectStore.seaweedfs.enabled }}

  {{- if ne
      (int .Values.nereus.objectStore.seaweedfs.replicaCount)
      1 }}
    {{- fail "weed mini benchmark mode requires replicaCount=1" }}
  {{- end }}

  {{- required
      "SeaweedFS image tag is required"
      .Values.nereus.objectStore.seaweedfs.image.tag }}

  {{- if and
      (not .Values.nereus.objectStore.seaweedfs.persistence.enabled)
      (not .Values.nereus.objectStore.seaweedfs.persistence.existingClaim) }}
    {{- fail "SeaweedFS requires persistent storage" }}
  {{- end }}

{{- end }}

{{- end -}}
```

---

# 17. Broker ConfigMap

当 `nereus.enabled=true` 时生成：

```yaml
managedLedgerStorageClassName:
   "org.apache.pulsar.broker.storage.nereus.NereusManagedLedgerStorage"

nereusEnabled: "true"

nereusRuntimeProviderClassName:
   "com.nereusstream.pulsar.DefaultNereusRuntimeProvider"

nereusOxiaServiceAddress: "<oxia-service>:6648"
nereusOxiaNamespace: "nereus"

nereusObjectStoreProviderClassName:
   "com.nereusstream.objectstore.S3CompatibleObjectStoreProvider"

nereusObjectStoreEndpoint:
   "http://<release>-seaweedfs:8333"

nereusObjectStoreRegion: "us-east-1"
nereusObjectStoreBucket: "nereus-benchmark"
nereusObjectStorePrefix: "v0.1.0"
nereusObjectStorePathStyleAccess: "true"
nereusObjectStoreRequestTimeoutSeconds: "30"
nereusObjectStoreMaxConnections: "64"

nereusObjectStoreSecretResolverClassName:
   "com.nereusstream.objectstore.EnvironmentObjectStoreSecretResolver"

nereusObjectStoreAccessKeySecretRef: "NEREUS_S3_ACCESS_KEY"
nereusObjectStoreSecretKeySecretRef: "NEREUS_S3_SECRET_KEY"
nereusObjectStoreSessionTokenSecretRef: ""

nereusDefaultStorageProfile: "<stage-profile>"
nereusGenerationProtocolEnabled: "true"

nereusMaterializationStagingDirectory:
   "/pulsar/data/nereus-staging"

nereusPhysicalGcEnabled: "false"
nereusPhysicalGcDryRun: "true"

nereusBookKeeperPrimaryWalEnabled: "true"
nereusBookKeeperDeploymentId: "nereus-v010-benchmark"
nereusBookKeeperProviderScopeSha256: "<scope-sha>"
nereusBookKeeperLedgerIdPrefixBits: "12"
nereusBookKeeperLedgerIdPrefixValue: "2049"
nereusBookKeeperLedgerIdNamespaceReservationId: "<reservation-id>"

nereusBookKeeperEnsembleSize: "3"
nereusBookKeeperWriteQuorumSize: "3"
nereusBookKeeperAckQuorumSize: "2"

nereusBookKeeperDigestType: "CRC32C"
nereusBookKeeperPasswordSecretRef: "NEREUS_BK_PASSWORD"
nereusBookKeeperPasswordIdentityVersion: "v1"

nereusBookKeeperGcEnabled: "false"
nereusBookKeeperGcDryRun: "true"
```

这些 key 由 `.Values.nereus` 专属生成，禁止在 `broker.configData` 重复设置。

---

# 18. Broker StatefulSet

## 18.1 Secret env

```gotemplate
{{- if .Values.nereus.enabled }}
- name: {{ .Values.nereus.secrets.accessKeyReference }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.nereus.secrets.existingSecret | quote }}
      key: {{ .Values.nereus.secrets.accessKeyKey | quote }}

- name: {{ .Values.nereus.secrets.secretKeyReference }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.nereus.secrets.existingSecret | quote }}
      key: {{ .Values.nereus.secrets.secretKeyKey | quote }}

- name: {{ .Values.nereus.secrets.bookKeeperPasswordReference }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.nereus.secrets.existingSecret | quote }}
      key: {{ .Values.nereus.secrets.bookKeeperPasswordKey | quote }}
{{- end }}
```

## 18.2 Staging volume

Mount：

```gotemplate
{{- if .Values.nereus.enabled }}
- name: nereus-staging
  mountPath: {{ .Values.nereus.staging.mountPath | quote }}
{{- end }}
```

Volume：

```gotemplate
{{- if .Values.nereus.enabled }}
- name: nereus-staging
  emptyDir:
    sizeLimit: {{
      .Values.nereus.staging.volume.emptyDir.sizeLimit | quote }}
{{- end }}
```

第一轮允许 emptyDir，但必须记录实际宿主设备。后续若 D/E staging IO 明显，
切换到专用 local PVC，并重新跑全部 A–E。

## 18.3 等待 Object Store

使用 `nereus-admin object-store verify`：

```gotemplate
- name: wait-nereus-object-store
  image: "<nereus-admin-image>"
  command:
    - /opt/nereus-admin/bin/nereus-admin
  args:
    - object-store
    - verify
    - --config
    - /etc/nereus-admin/admin.properties
    - --timeout-seconds
    - "{{ .Values.nereus.brokerWait.timeoutSeconds }}"
```

它使用和 Broker 相同的 Secret env，不只检查 TCP，而是执行真实 HeadBucket。

## 18.4 等待 BK namespace

```gotemplate
- name: wait-nereus-bookkeeper-namespace
  image: "<nereus-admin-image>"
  command:
    - /opt/nereus-admin/bin/nereus-admin
  args:
    - bookkeeper
    - namespace
    - verify
    - --config
    - /etc/nereus-admin/admin.properties
    - --timeout-seconds
    - "{{ .Values.nereus.brokerWait.timeoutSeconds }}"
```

该容器不修改 Oxia。

---

# 19. SeaweedFS Kubernetes 资源

## 19.1 Headless Service

```yaml
apiVersion: v1
kind: Service
metadata:
   name: <release>-seaweedfs-headless
spec:
   clusterIP: None
   publishNotReadyAddresses: true
   selector:
      app: pulsar
      release: <release>
      component: seaweedfs
   ports:
      - name: s3
        port: 8333
        targetPort: s3
```

## 19.2 ClusterIP Service

```yaml
apiVersion: v1
kind: Service
metadata:
   name: <release>-seaweedfs
spec:
   type: ClusterIP
   selector:
      app: pulsar
      release: <release>
      component: seaweedfs
   ports:
      - name: s3
        port: 8333
        targetPort: s3
      - name: metrics
        port: 9327
        targetPort: metrics
```

Master/Filer/Volume 端口不创建 Service。

## 19.3 StatefulSet

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
   name: <release>-seaweedfs
spec:
   serviceName: <release>-seaweedfs-headless
   replicas: 1
   podManagementPolicy: OrderedReady

   selector:
      matchLabels:
         app: pulsar
         release: <release>
         component: seaweedfs

   template:
      metadata:
         labels:
            app: pulsar
            release: <release>
            component: seaweedfs

      spec:
         nodeSelector:
            workload: apps
            nereus-object-store: "true"

         tolerations:
            - key: dedicated
              operator: Equal
              value: apps
              effect: NoSchedule

         terminationGracePeriodSeconds: 60

         containers:
            - name: seaweedfs
              image: nereus-benchmark/seaweedfs:4.29-amd64
              imagePullPolicy: Never

              command:
                 - weed

              args:
                 - mini
                 - -dir=/data
                 - -ip.bind=0.0.0.0
                 - -metricsPort=9327
                 - -metricsIp=0.0.0.0
                 - -webdav=false
                 - -admin.ui=false
                 - -s3.port.iceberg=0
                 - -master.telemetry=false
                 - -master.defaultReplication=000
                 - -master.volumeSizeLimitMB=1024
                 - -filer.maxMB=64
                 - -volume.index=memory

              env:
                 - name: AWS_ACCESS_KEY_ID
                   valueFrom:
                      secretKeyRef:
                         name: pulsar-nereus-secrets
                         key: access-key

                 - name: AWS_SECRET_ACCESS_KEY
                   valueFrom:
                      secretKeyRef:
                         name: pulsar-nereus-secrets
                         key: secret-key

                 - name: S3_BUCKET
                   value: nereus-benchmark

              ports:
                 - name: s3
                   containerPort: 8333
                 - name: metrics
                   containerPort: 9327

              startupProbe:
                 tcpSocket:
                    port: s3
                 failureThreshold: 90
                 periodSeconds: 2
                 timeoutSeconds: 1

              readinessProbe:
                 tcpSocket:
                    port: s3
                 periodSeconds: 5
                 timeoutSeconds: 1

              livenessProbe:
                 tcpSocket:
                    port: s3
                 periodSeconds: 10
                 timeoutSeconds: 1

              resources:
                 requests:
                    cpu: "2"
                    memory: 4Gi
                 limits:
                    cpu: "2"
                    memory: 4Gi

              volumeMounts:
                 - name: data
                   mountPath: /data

   volumeClaimTemplates:
      - metadata:
           name: data
        spec:
           accessModes:
              - ReadWriteOnce
           storageClassName: local-seaweedfs
           resources:
              requests:
                 storage: 500Gi
```

TCP probe只代表进程端口存活；真正的 bucket/credential readiness由 Nereus admin
HeadBucket gate保证。

## 19.4 PodMonitor

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
   name: <release>-seaweedfs
spec:
   selector:
      matchLabels:
         app: pulsar
         release: <release>
         component: seaweedfs

   podMetricsEndpoints:
      - port: metrics
        path: /metrics
        interval: 5s
        scrapeTimeout: 4s
```

---

# 20. Nereus Admin ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
   name: <release>-nereus-admin
data:
   admin.properties: |
      cluster=beijing-1
      oxia.serviceAddress=<release>-oxia-svc:6648
      oxia.namespace=nereus
      oxia.sessionTimeoutSeconds=30
      oxia.maxPendingOperations=1024

      objectStore.providerClassName=com.nereusstream.objectstore.S3CompatibleObjectStoreProvider
      objectStore.endpoint=http://<release>-seaweedfs:8333
      objectStore.region=us-east-1
      objectStore.bucket=nereus-benchmark
      objectStore.prefix=v0.1.0
      objectStore.pathStyleAccess=true
      objectStore.requestTimeoutSeconds=30
      objectStore.maxConnections=64
      objectStore.secretResolverClassName=com.nereusstream.objectstore.EnvironmentObjectStoreSecretResolver
      objectStore.accessKeySecretRef=NEREUS_S3_ACCESS_KEY
      objectStore.secretKeySecretRef=NEREUS_S3_SECRET_KEY

      bookkeeper.deploymentId=nereus-v010-benchmark
      bookkeeper.providerScopeSha256=<scope>
      bookkeeper.ledgerIdPrefixBits=12
      bookkeeper.ledgerIdPrefixValue=2049
      bookkeeper.reservationId=<reservation>
      bookkeeper.ensembleSize=3
      bookkeeper.writeQuorumSize=3
      bookkeeper.ackQuorumSize=2
      bookkeeper.digestType=CRC32C
      bookkeeper.passwordSecretRef=NEREUS_BK_PASSWORD
      bookkeeper.passwordIdentityVersion=v1

      operatorEvidenceSha256=<evidence>
```

`admin.properties` is parsed by `nereus-admin` as typed Java properties, while the
Broker ConfigMap is parsed by the Nereus broker adapter as typed runtime
configuration. Helm may decode large unquoted YAML integers as floating-point
values, which would render `maxBytesPerLedger` or `maxReadBytesInFlight` in
scientific notation and fail a `long` parser. Both ConfigMap templates therefore
pipe every integral BookKeeper field through `int` before rendering decimal text,
and the local deployment preflight rejects scientific notation in the admin and
broker forms of these long-valued properties before any Helm install.

The BookKeeper-specific broker fields are emitted with the `PULSAR_PREFIX_`
environment form. The Pulsar container entrypoint strips that prefix and adds
custom keys that are absent from the stock `broker.conf`; emitting only the raw
ConfigMap key would silently leave `nereusBookKeeperPrimaryWalEnabled=false`.

ConfigMap checksum加入：

```text
bootstrap Job name
Broker Pod annotation
```

Bootstrap Job 的 revision hash 还必须覆盖 admin image、resources、
nodeSelector、tolerations 和 timeout 等完整 `.Values.nereus` 输入。否则仅替换
admin image 时 Helm 会尝试修改已有 Job 的 immutable Pod template。Broker Pod
annotation 继续绑定 ConfigMap checksum，防止 configuration drift。

---

# 21. BookKeeper Namespace Bootstrap Job

不使用 Helm hook。

```yaml
apiVersion: batch/v1
kind: Job
metadata:
   name: <release>-nereus-bk-bootstrap-<checksum8>
spec:
   activeDeadlineSeconds: 900
   backoffLimit: 4
   ttlSecondsAfterFinished: 3600

   template:
      spec:
         restartPolicy: OnFailure

         nodeSelector:
            workload: pulsar

         tolerations:
            - key: dedicated
              operator: Equal
              value: pulsar
              effect: NoSchedule

         initContainers:
            - name: wait-oxia
              image: <nereus-admin-image>
              command:
                 - sh
                 - -ec
              args:
                 - |
                    deadline=$((SECONDS + 600))
                    until getent hosts <release>-oxia-svc >/dev/null 2>&1; do
                      test "$SECONDS" -lt "$deadline"
                      sleep 2
                    done

         containers:
            - name: bootstrap
              image: <nereus-admin-image>
              imagePullPolicy: Never

              command:
                 - /opt/nereus-admin/bin/nereus-admin

              args:
                 - bookkeeper
                 - namespace
                 - ensure
                 - --config
                 - /etc/nereus-admin/admin.properties
                 - --timeout-seconds
                 - "600"
                 - --output
                 - /dev/termination-log

              volumeMounts:
                 - name: config
                   mountPath: /etc/nereus-admin
                   readOnly: true

         volumes:
            - name: config
              configMap:
                 name: <release>-nereus-admin
```

Namespace provisioning本身不需要 secret value，因此 bootstrap Job无需挂载
BookKeeper password。Broker runtime后续才解析 password。`ensure` 的 JSON
小于 termination message 上限；部署脚本在 Job 完成后立即从 bootstrap
container 的 termination message 提取并校验 `ACTIVE`、cluster、
provider-scope 和 namespace digest，固化为
`bookkeeper-namespace-bootstrap.json`。因此即使 TTL controller 后续删除 Job，
本轮 namespace identity 证据仍然保留。

---

# 22. Publication / Generation Activation

## 22.1 不属于 Helm mutation

Helm只负责：

```text
Oxia namespace
SeaweedFS
BK namespace reservation
Broker runtime config
```

activation脚本负责：

```text
读取稳定的 generation broker readiness
BK publication prepare
WAL_ONLY/ASYNC/SYNC publication activate
generation registration backfill
generation protocol activate
Broker rollout restart
读取最强的 BookKeeper primary-WAL broker readiness
以 post-restart readiness 强制重新绑定 publication activation
再次运行 generation registration backfill
capability verification
```

## 22.2 流程

```text
helm install
  -> SeaweedFS Ready
  -> BK bootstrap Job succeeded
  -> Broker init verifies dependencies
  -> Broker starts read-capable runtime
  -> GET stable generation persistent-broker readiness
  -> prepare BK publication activation
     (PREPARED；publication bits暂为false)
  -> activate all three publication bits
  -> POST generation registration backfill
     (broker内部完成 readiness重检、proof install和generation publication activation)
  -> rollout restart Broker StatefulSet
  -> Broker加载durable ACTIVE activation并发布BK binding capability
  -> GET stable BookKeeper primary-WAL readiness
  -> GET stable post-restart generation readiness
  -> 无条件用BK readiness重新prepare/publication activation
  -> 无条件用generation readiness再次backfill
  -> read activation并验证其epoch/digest与BK readiness完全相同
```

脚本不得从 Pod 日志拼接 readiness，也不得由调用方自行计算 broker-set hash。
API 返回的 `brokerReadinessEpoch`、`brokerReadinessSha256` 和
`persistentBrokerCount` 是后续 publication 请求的唯一输入。backfill 返回的
`failureCount` 必须为 `0`，且响应必须落盘后才能重启 Broker。
Broker restart会改变 process identity，因此脚本必须把 post-restart readiness
视为新的权威输入；不能仅凭 restart前的 activation证据宣告完成。

首次启动时 Broker 尚未从 durable activation 安装 BookKeeper binding，因此
BookKeeper 专用 readiness 必然不可用。首次 publication activation 使用
generation readiness 作为唯一 bootstrap authority。服务端按当前进程状态重新
读取并校验：

```text
binding未安装 -> 只接受当前generation readiness
binding已安装 -> 只接受当前BookKeeper primary-WAL readiness
```

`activation/prepare` 只负责写入并返回 `PREPARED` activation identity；此时
`walOnlyPublicationEnabled`、`asyncPublicationEnabled`、
`syncPublicationEnabled` 和 `ledgerDeletionEnabled` 必须仍为 `false`。
只有紧接着的 `activation/publications` 成功响应才允许要求这些 capability
为 `true`。脚本不能把 prepare 的中间态误判成失败，也不能跳过 publications
直接执行 backfill。

即使重启前后 broker 集合表面上未变化，两类 readiness 的 hash domain 也不同，
所以 post-restart reconciliation 是强制步骤，不是条件分支。

## 22.3 脚本证据

保存：

```text
generation-readiness-before.json
bk-activation-prepare.json
bk-activation-active.json
generation-backfill.json
broker-rollout.txt
readiness-after.json
generation-readiness-after.json
bk-activation-prepare-reconciled.json
bk-activation-active-reconciled.json
generation-backfill-reconciled.json
bk-activation-final.json
```

`generation-backfill.json` 的成功响应同时是 activation 证据，因为 broker 方法
只有在 backfill proof 与 generation publication activation 都完成后才结束。

---

# 23. A–E Values

## 23.1 Common

```yaml
# 空值使 Helm release namespace 成为默认权威值；部署脚本还会用同一个
# NEREUS_NAMESPACE 显式覆盖，避免 --namespace 与 .Values.namespace 分裂。
namespace: ""
clusterName: beijing-1
initialize: true

components:
   zookeeper: false
   oxia: true
   bookkeeper: true
   autorecovery: true
   broker: true
   proxy: false
   toolset: true

defaultPulsarImageRepository: nereus-benchmark/pulsar
defaultPulsarImageTag: 5.0.0-m1-apache-p8dae0236-amd64
defaultPullPolicy: Never

images:
   oxia:
      repository: oxia/oxia
      tag: 0.16.7
      pullPolicy: Never

   bookie:
      repository: nereus-benchmark/pulsar
      tag: 5.0.0-m1-apache-p8dae0236-amd64
      pullPolicy: Never

   autorecovery:
      repository: nereus-benchmark/pulsar
      tag: 5.0.0-m1-apache-p8dae0236-amd64
      pullPolicy: Never

   toolset:
      repository: nereus-benchmark/pulsar
      tag: 5.0.0-m1-apache-p8dae0236-amd64
      pullPolicy: Never

oxia:
   initialShardCount: 3
   replicationFactor: 3

   extraNamespaces:
      - name: nereus
        initialShardCount: 3
        replicationFactor: 3

   coordinator:
      # 与本轮原 ZooKeeper resource envelope 完全一致。
      resources:
         requests:
            memory: 2Gi
            cpu: 2
         limits:
            memory: 2304Mi
            cpu: 2

      podMonitor:
         enabled: true
         interval: 5s
         scrapeTimeout: 4s

   server:
      replicas: 3

      resources:
         requests:
            memory: 2Gi
            cpu: 2
         limits:
            memory: 2304Mi
            cpu: 2

      storageSize: 47Gi
      local_storage: true
      storageClassName: local-zk

      podMonitor:
         enabled: true
         interval: 5s
         scrapeTimeout: 4s

bookkeeper:
   replicaCount: 4

   podMonitor:
      enabled: true
      interval: 5s
      scrapeTimeout: 4s

broker:
   replicaCount: 3

   podMonitor:
      enabled: true
      interval: 5s
      scrapeTimeout: 4s

   configData:
      # 这是本轮基准为控制变量而固定的实现，不是 Nereus/Oxia 的兼容性要求。
      # 可替换为 org.apache.pulsar.broker.loadbalance.impl.ModularLoadManagerImpl。
      loadManagerClassName:
         org.apache.pulsar.broker.loadbalance.extensions.ExtensibleLoadManagerImpl

      managedLedgerDefaultEnsembleSize: "3"
      managedLedgerDefaultWriteQuorum: "3"
      managedLedgerDefaultAckQuorum: "2"

nereus:
   secrets:
      existingSecret: pulsar-nereus-secrets

   objectStore:
      region: us-east-1
      bucket: nereus-benchmark
      prefix: v0.1.0
      pathStyleAccess: true

      seaweedfs:
         enabled: true

         image:
            repository: nereus-benchmark/seaweedfs
            tag: 4.29-amd64
            pullPolicy: Never

         nodeSelector:
            workload: apps
            nereus-object-store: "true"

         persistence:
            enabled: true
            storageClassName: local-seaweedfs
            size: 500Gi

   generationProtocol:
      enabled: true

   physicalGc:
      enabled: false
      dryRun: true

   bookkeeperWal:
      enabled: true
      deploymentId: nereus-v010-benchmark
      providerScopeSha256: <64_HEX_PROVIDER_SCOPE>
      ledgerIdPrefixBits: 12
      ledgerIdPrefixValue: 2049
      ledgerIdNamespaceReservationId: <FIXED_RESERVATION_ID>

      ensembleSize: 3
      writeQuorumSize: 3
      ackQuorumSize: 2

      gc:
         enabled: false
         dryRun: true

   admin:
      image:
         repository: nereus-benchmark/nereus-admin
         tag: v0.1.0-n78a15445-amd64
         pullPolicy: Never

      operatorEvidenceSha256: <64_HEX_OPERATOR_EVIDENCE>
```

tracked values 固定源码和拓扑，campaign identity 单独放在不提交的第三层：

```yaml
# values-campaign.yaml
nereus:
   bookkeeperWal:
      providerScopeSha256: <64_HEX_PROVIDER_SCOPE>
      ledgerIdNamespaceReservationId: <FIXED_RESERVATION_ID>

   admin:
      operatorEvidenceSha256: <64_HEX_OPERATOR_EVIDENCE>
```

`prepare-nereus-campaign-values.sh` 从 checksummed image manifest 校验三个 frozen
image/source identity，按实际 release/namespace 渲染 Oxia BookKeeper metadata
service URI，扩展为集群内 FQDN 后计算 provider scope SHA-256，生成一个 reservation
UUID，并把 context、release、namespace、cluster、scope、reservation、manifest
SHA-256 和三个完整 image ID 固化到相邻的 non-secret operator-evidence 文件。
`deploy-nereus-stage.sh` 对 A–E 都要求该 values 层和 evidence 文件同时存在；
A 用它校验 Apache image ID，B–E 还校验 rendered `operatorEvidenceSha256`
等于 evidence 文件 SHA-256。一个 campaign 的 B–E 必须复用同一组 identity；
不同物理 BookKeeper scope 必须重新生成。

每个 A–E overlay必须给 Broker Pod写入以下纯证据 annotation：

```text
benchmark.nereusstream.com/stage
benchmark.nereusstream.com/managed-ledger-storage-class
```

namespace policy仍由部署脚本通过 `pulsar-admin namespaces set-persistence`
设置；annotation不参与运行时决策，只用于让 B/C 的渲染意图和集群证据可审计。

## 23.2 A

```yaml
images:
   broker:
      repository: nereus-benchmark/pulsar
      tag: 5.0.0-m1-apache-p8dae0236-amd64
      pullPolicy: Never

nereus:
   enabled: false

   bootstrap:
      enabled: false
```

SeaweedFS仍运行。

## 23.3 B

```yaml
images:
   broker:
      repository: nereus-benchmark/pulsar
      tag: 5.0.0-m1-nereus-p50fc70fe-n78a15445-amd64
      pullPolicy: Never

nereus:
   enabled: true
   defaultStorageProfile: BOOKKEEPER_WAL_ONLY

   bootstrap:
      enabled: true
```

测试 namespace storage class：

```text
bookkeeper
```

## 23.4 C

```yaml
images:
   broker:
      repository: nereus-benchmark/pulsar
      tag: 5.0.0-m1-nereus-p50fc70fe-n78a15445-amd64
      pullPolicy: Never

nereus:
   enabled: true
   defaultStorageProfile: BOOKKEEPER_WAL_ONLY

   bootstrap:
      enabled: true
```

测试 namespace storage class：

```text
nereus
```

## 23.5 D

```yaml
nereus:
   enabled: true
   defaultStorageProfile: BOOKKEEPER_WAL_ASYNC_OBJECT
```

测试 namespace storage class：

```text
nereus
```

## 23.6 E

```yaml
nereus:
   enabled: true
   defaultStorageProfile: BOOKKEEPER_WAL_SYNC_OBJECT
```

测试 namespace storage class：

```text
nereus
```

---

# 24. Secret

```bash
kubectl -n pulsar create secret generic pulsar-nereus-secrets \
  --from-literal=access-key='<SEAWEEDFS_ACCESS_KEY>' \
  --from-literal=secret-key='<SEAWEEDFS_SECRET_KEY>' \
  --from-literal=bookkeeper-password='<NEREUS_BK_PASSWORD>'
```

禁止提交真实 Secret YAML。

---

# 25. Helm 渲染测试

## 25.1 正向

对 A–E：

```bash
helm lint charts/pulsar \
  -f examples/nereus-benchmark/values-common.yaml \
  -f examples/nereus-benchmark/values-stage-<stage>.yaml \
  --set-string nereus.bookkeeperWal.providerScopeSha256=<64_HEX> \
  --set-string nereus.bookkeeperWal.ledgerIdNamespaceReservationId=<UUID> \
  --set-string nereus.admin.operatorEvidenceSha256=<64_HEX>

helm template pulsar charts/pulsar \
  --namespace pulsar-benchmark \
  -f examples/nereus-benchmark/values-common.yaml \
  -f examples/nereus-benchmark/values-stage-<stage>.yaml \
  --set-string nereus.bookkeeperWal.providerScopeSha256=<64_HEX> \
  --set-string nereus.bookkeeperWal.ledgerIdNamespaceReservationId=<UUID> \
  --set-string nereus.admin.operatorEvidenceSha256=<64_HEX> \
  > /tmp/stage-<stage>.yaml
```

正向矩阵还必须断言 `--namespace pulsar-benchmark` 传播到 namespaced resources，
并拒绝 common values 把它重新固定为 `pulsar`；同时断言 Apache、Nereus Broker
和 Nereus admin 都使用 frozen source-qualified tag。每个 stage 还必须断言：

```text
不渲染 ZooKeeper resource
broker metadataStoreUrl = oxia://<release>-oxia-svc:6648/broker
BookKeeper metadataServiceUri =
  metadata-store:oxia://<release>-oxia-svc:6648/bookkeeper
Oxia server PVC = 47Gi, storageClassName = local-zk
Oxia server/coordinator requests = 2 CPU / 2Gi
Oxia server/coordinator limits = 2 CPU / 2304Mi
```

## 25.2 A 断言

```text
Apache Broker image
无 nereusEnabled
无 Nereus bootstrap Job
SeaweedFS StatefulSet存在
SeaweedFS位于 workload=apps
```

## 25.3 B–E 断言

```text
Nereus Broker image包含 78a1544596af3c74ec1f3ce8b6194f015f6a2c9a
managedLedgerStorageClassName正确
nereusEnabled=true
Nereus Oxia namespace=nereus
SeaweedFS endpoint=:8333
secret resolver=EnvironmentObjectStoreSecretResolver
BK quorum=3/3/2
GC disabled/dry-run
bootstrap Job存在
Broker wait initContainers存在
staging volume存在
```

## 25.4 负向

以下必须 render失败：

```text
Nereus enabled + Oxia disabled
Noop resolver
missing Secret
invalid or duplicate Secret environment reference
missing provider scope
invalid SHA-256
missing reservation ID
ensemble < write quorum
write quorum < ack quorum
invalid profile
legacy OBJECT_WAL alias
SeaweedFS replicas != 1
SeaweedFS persistence disabled
admin image tag empty
duplicate reserved broker config key
```

以下 load manager 正向组合必须 render 成功，且 cluster initialize/smoke
证据必须记录实际使用的 `loadManagerClassName`：

```text
Nereus + Oxia + ModularLoadManagerImpl
Nereus + Oxia + ExtensibleLoadManagerImpl
```

Pulsar fork 的运行时 gate 不能只验证 JSON 兼容性：

- `NereusMultiBrokerIntegrationTest` 使用
  `ExtensibleLoadManagerImpl` 完成真实 Oxia、两 Broker initialize 与 capability
  convergence；
- `NereusModularLoadManagerMultiBrokerIntegrationTest` 使用
  `ModularLoadManagerImpl` 完成同样的真实 Oxia、两 Broker initialize 与
  capability convergence；
- 两条路径都必须从 `/loadbalance/brokers` 的 `MetadataStore` 记录收敛
  storage-binding/cursor capability，不能通过测试专用 registry adapter 绕过。

不得增加“只允许 ExtensibleLoadManagerImpl”或“只允许
ModularLoadManagerImpl”的 Helm 校验。

---

# 26. 部署脚本

`deploy-nereus-stage.sh`：

```text
1. 校验 stage参数并映射精确 overlay和namespace storage class。
2. 要求显式设置NEREUS_EXPECTED_CONTEXT，并与current-context逐字匹配。
3. A–E都要求NEREUS_CAMPAIGN_VALUES和相邻/显式operator evidence；A用它校验
   Apache image ID，B–E还绑定BookKeeper campaign identity。
4. helm lint + template，并保存 common/overlay/campaign/evidence/manifest SHA-256。
5. 在任何 Kubernetes mutation前拒绝zero SHA、zero UUID和image tag占位符；
   rendered operatorEvidenceSha256必须等于operator evidence文件SHA-256；
   metadata path必须为Oxia且不得渲染ZooKeeper；Oxia PVC必须为local-zk/47Gi。
6. 校验目标namespace已存在，且不存在同名 Helm release 或任何同名前缀的
   Oxia/BookKeeper/SeaweedFS 数据 PVC；`local-zk` StorageClass存在；若它是
   `kubernetes.io/no-provisioner`，必须有至少3个 `Available` PV；
   Secret存在且必需key均有非空value。A 需要
   SeaweedFS access/secret key；B–E 额外需要 BookKeeper password。
7. helm install；namespace、fullnameOverride、clusterName和
   existingSecret使用同一组显式override贯穿lint/template/upgrade；
   fullnameOverride固定为release名，使脚本等待的资源名不依赖Chart fullname
   拼接规则。
8. 按依赖顺序显式等待：
   Oxia coordinator/server
   三个Oxia PVC均为local-zk/47Gi/Bound
   BookKeeper init/StatefulSet
   Pulsar cluster initialize
   AutoRecovery
   SeaweedFS
   Nereus namespace bootstrap（仅 B–E）
   Broker
   Toolset
9. 创建全新的 tenant/namespace。
10. 通过 pulsar-admin set-persistence写入3/3/2和stage storage class。
11. A/B创建stock smoke topic；C–E在activation完成后创建Nereus smoke topic。
12. 保存run.env、campaign/evidence SHA、镜像ID、namespace policy和Pod证据；
    Apache/Nereus/admin必须匹配build manifest完整image ID，四个Oxia container
    必须收敛到同一个SHA-256 image identity。
```

两节点环境默认只保留一个隔离的 benchmark Helm release。每个 A–E stage
都按 `helm install -> gate -> 测量 -> gate -> evidence -> cold reset`
执行，不允许原地 upgrade。profile 变化不迁移既有 topic，而是在前一 stage
全部物理数据清空、PV 恢复 `Available` 后重新安装。

如果控制进程在 Helm install/upgrade 已完成、但写入 `RUN_DIR/run.env` 前中断，
部署脚本允许显式的 `--resume` 收尾模式。该模式只接受 live release 的 stage
和 managed-ledger storage class annotation 与请求完全匹配的情况，跳过 Helm
install/upgrade，仅重新完成 readiness、初始化身份、运行证据和 `run.env` 写入；
它不是在线切换 profile 或绕过冷重置的通用入口。

`reset-nereus-benchmark-stage.sh` 必须：

1. 从本轮 `run.env` 绑定 stage、context、release 和 namespace；
2. 要求 `collect-helm-evidence.sh` 已生成且校验通过的 archive/sidecar；
3. 只接受显式的 `<namespace>/<release>/<stage>` 删除确认；
4. 从运行中 release Pod 解析本轮恰好 16 个核心数据 PVC：
   Oxia 3、BookKeeper journal/ledger/index 12、SeaweedFS 1；如果存在
   `${release}-grafana` 监控 PVC，单独记录其 PV 以便 Helm 卸载后解绑定；
5. `helm uninstall --wait` 后，为每个 PVC 创建短生命周期 cleaner Pod，
   使用已导入的 frozen Apache image 挂载并清空文件系统；cleaner 必须容忍
   `dedicated=pulsar:NoSchedule`，以便挂载本地 BookKeeper PV 的节点能够调度；
6. 任一 wipe 失败时停止且不得删除该 PVC；
7. wipe 全部成功后删除 PVC；`Retain` PV 移除旧 claimRef 并等待
   `Available`，动态 `Delete` PV 等待资源消失；静态 local/hostPath
   `Delete` PV 因没有 deletion plugin，必须在 wipe 完成后删除 PV 对象，下一轮
   再从冻结 YAML apply；
8. 保存 PVC/PV mapping、逐 PVC wipe log、完成记录及 SHA-256。

Grafana PV 只解绑定、不由 benchmark reset 擦除；benchmark 的
`values-common.yaml` 关闭远程 dashboard 下载，避免部署依赖公网 endpoint，
但 VictoriaMetrics、vmagent 和 Grafana 指标采集仍然启用。

namespace、手工创建的 Secret、campaign values 和本地 results/evidence 不由
reset 脚本删除。下一 stage 复用同一 campaign identity，但物理存储内容必须
为空；若使用新的 physical provider scope，则必须生成新的 campaign identity。

脚本不使用一个全局 `--wait` 隐藏失败来源，而是分别等待：

```text
Oxia
BookKeeper init
Pulsar initialize
SeaweedFS
bootstrap Job
Broker rollout
Toolset
```

`test-nereus-render.sh` 是本地/CI preflight，覆盖 A–E、两个 load manager
正向组合、任意其他 load manager 不被 Helm allowlist 拦截，以及 fail-closed
负向矩阵。Stage A 还必须断言不渲染 Nereus admin 或 Broker Nereus 配置，
同时仍渲染 common SeaweedFS，以保持 A–E 的对象存储拓扑和背景资源占用一致。

---

# 27. 部署后验证

## 27.1 调度

```bash
kubectl get pods -n pulsar -o wide
```

断言：

```text
Broker/Bookie/Oxia -> workload=pulsar
SeaweedFS -> workload=apps
```

## 27.2 镜像

```bash
kubectl get pods -n pulsar \
  -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,IMAGE:.spec.containers[*].image,IMAGE_ID:.status.containerStatuses[*].imageID'
```

## 27.3 SeaweedFS

```text
StatefulSet Ready 1/1
PVC Bound
Pod所在 app node
S3 8333 reachable
metrics 9327 scrape successful
object-store verify success
object-store contract success
restart persistence gate success
```

## 27.4 Oxia

coordinator config包含：

```text
default
broker
bookkeeper
nereus
```

## 27.5 Nereus Broker

```text
hybrid provider加载
bookkeeper storage class存在
nereus storage class存在
BK namespace ACTIVE
publication activation ACTIVE
generation activation ACTIVE
所有 Broker capability digest相同
```

---

# 28. 对象存储与 OMB 共节点

若 OMB 也运行在 `workload=apps`：

必须：

```text
Object Store requests=limits整数 CPU
OMB requests=limits整数 CPU
二者 cpuset不重叠
SeaweedFS数据盘与 OMB raw result盘分离
记录 NIC utilization/retransmit/drop
```

否则 D/E 的上限可能来自 app 节点：

```text
CPU
磁盘
NIC
```

而不是 Nereus。

更优方案：

```text
SeaweedFS -> app node固定 CPU/盘
OMB -> 外部主机或 app node独立 CPU/盘
```

---

# 29. 性能结果中的版本表述

正确：

```text
Nereus v0.1.0 branch @ 78a1544596af3c74ec1f3ce8b6194f015f6a2c9a
Pulsar fork @ 50fc70fe4620febcf0fd31d97ff7d2be447af3d4
Broker image @ <image-id>
Helm chart @ <helm-sha>
SeaweedFS 4.29 @ <image-id>
```

不正确：

```text
纯 v0.1.0 tag
```

因为最终镜像已经包含 v0.1.0 分支上的部署补丁。

---

# 30. 推荐提交拆分

## Nereus v0.1.0

### Commit 1

```text
feat(secrets): add environment-backed deployment resolver
```

### Commit 2

```text
feat(admin): add BookKeeper namespace bootstrap CLI
```

### Commit 3

```text
test(object-store): add deployable S3 contract command
```

### Commit 4

```text
build(admin): add v0.1.0 bootstrap image
```

## Helm `nereus`

### Commit 1

```text
feat(oxia): support isolated Nereus namespace
```

### Commit 2

```text
feat(storage): deploy pinned SeaweedFS mini on app nodes
```

### Commit 3

```text
feat(broker): render Nereus v0.1.0 runtime configuration
```

### Commit 4

```text
feat(bootstrap): provision Nereus BookKeeper namespace
```

### Commit 5

```text
test(chart): add A-E render and validation matrix
```

### Commit 6

```text
docs(perf): add activation and evidence workflow
```

---

# 31. 实施顺序

```text
1. 在 v0.1.0 代码线增加 EnvironmentObjectStoreSecretResolver。
2. 增加 nereus-admin module。
3. 增加 BookKeeper namespace ensure/verify。
4. 增加 Object Store verify/contract。
5. Pulsar fork 增加 readiness/backfill 管理入口和测试。
6. 构建 nereus-admin image。
7. 基于最终 Pulsar/Nereus SHA重构 Nereus Broker image。
8. Helm 增加 Oxia extraNamespaces。
9. Helm 增加 SeaweedFS StatefulSet/Service/PVC/PodMonitor。
10. Helm 增加 Nereus Broker ConfigMap/Secret/staging。
11. Helm 增加 bootstrap Job和 Broker wait initContainer。
12. 增加 A–E overlays。
13. 执行 lint/render负向测试。
14. 部署 A smoke。
15. 部署 B并完成 activation。
16. 执行 SeaweedFS contract/restart gate。
17. 部署 C/D/E smoke。
18. 才开始正式性能实验。
```

---

# 32. Helm 阶段完成标准

只有同时满足以下条件，才算完成：

```text
A–E helm lint通过
A–E helm template通过
ModularLoadManagerImpl与ExtensibleLoadManagerImpl正向render通过
两个load manager的真实Oxia双Broker initialize/capability smoke通过
非法配置 fail closed
Oxia包含独立 nereus namespace
SeaweedFS固定 workload=apps
Pulsar组件固定 workload=pulsar
SeaweedFS使用持久卷
SeaweedFS 4.29 image identity已冻结
object-store contract全部通过
v0.1.0 env resolver测试通过
v0.1.0 admin CLI测试通过
Pulsar readiness/backfill管理 API 测试通过
clean Oxia可自动 provision namespace
Broker可在 clean install启动
publication/generation activation完成
activation后 Broker重启完成
所有 Broker capability一致
stock/BK WAL quorum统一3/3/2
GC关闭/dry-run
最终 Nereus image包含 78a1544596af3c74ec1f3ce8b6194f015f6a2c9a
所有部署证据完整
```

---

# 33. 主要风险

| 风险 | 处理 |
|---|---|
| SeaweedFS 某项 S3 语义不兼容 | Nereus production provider contract gate；失败则停止 D/E |
| 原始 n81a1fa83 镜像缺 resolver | 重构新 commit-qualified image |
| namespace bootstrap 循环依赖 | 独立 nereus-admin Job |
| Helm hook 死锁 | 不使用 hook，Broker init轮询真实状态 |
| SeaweedFS/OMB资源争用 | CPU、磁盘和 NIC隔离 |
| local PV调度失败 | WaitForFirstConsumer + nodeAffinity |
| v0.1.0 tag与最终代码不一致 | 使用 `v0.1.0@SHA` 表述，不移动 tag |
| A 不运行对象存储导致拓扑变化 | SeaweedFS始终由 common values启动 |
| D 异步积压制造虚高吞吐 | 后续性能协议要求 materialization lag稳定并排空 |
| background GC干扰 | 所有 Nereus destructive GC关闭 |
| SeaweedFS额外服务干扰 | 关闭 WebDAV/Admin/Iceberg REST Catalog/telemetry |
| bucket不存在导致 Broker初始化失败 | `S3_BUCKET`预创建 + HeadBucket verify |

---

# 34. 最终结论

最终实现需要修改：

```text
Nereus v0.1.0 代码线
Nereus Pulsar fork 管理面 API
Helm Chart nereus 分支
Nereus/Pulsar 镜像构建产物
```

不需要修改：

```text
Nereus Pulsar Broker Java 数据路径
Nereus append/read/metadata/materialization 协议
```

对象存储最终固定为：

```text
SeaweedFS 4.29
weed mini
single StatefulSet
workload=apps
S3 :8333
Prometheus :9327
local persistent volume
replication=000
```

Nereus 版本最终仍写：

```text
v0.1.0
```

真实可复现身份必须写：

```text
v0.1.0@78a1544596af3c74ec1f3ce8b6194f015f6a2c9a
```
