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

# Nereus v0.1.0 Performance Baseline Deployment

The authoritative design is
`nereus-v0.1.0-helm-chart-code-level-design.md` at the repository root.
The workflow uses containerd/nerdctl; Docker is not required.

For the exact two-node server commands, use
[`SERVER-RUNBOOK.md`](SERVER-RUNBOOK.md). It freezes the operational identity
to Helm release `nereus`, Kubernetes namespace `pulsar`, and Pulsar cluster
`beijing-1-benchmark`.

## Stage Descriptions

| Stage | Broker/data path | Namespace storage class |
| --- | --- | --- |
| A | Apache Pulsar baseline | bookkeeper |
| B | Nereus dormant (stock BK WAL) | bookkeeper |
| C | Nereus BK primary WAL only | nereus |
| D | Nereus BK WAL + async object | nereus |
| E | Nereus BK WAL + sync object | nereus |

Each deployment run creates a fresh namespace, fixes persistence to `3/3/2`,
and records the selected storage class. B and C are therefore different even
though both use the `BOOKKEEPER_WAL_ONLY` profile: B routes topics through the
stock `bookkeeper` storage class; C routes them through `nereus`.

Both `ModularLoadManagerImpl` and `ExtensibleLoadManagerImpl` are supported
with Oxia. The common benchmark values select `ModularLoadManagerImpl`; the
Chart does not reject either implementation.

`values-common.yaml` is maintained from the complete text of the chart's
`values.yaml`, including comments and optional configuration examples, with
the benchmark overrides applied in place. This keeps the A-E control plane
explicit. When chart defaults change, copy the new chart values first, reapply
the benchmark-only differences, and update the recorded source checksum.
`scripts/test-nereus-render.sh` rejects a stale source checksum or a missing
chart values path.

## Frozen Source Identities

- Apache Pulsar: `8dae0236c0a0d405ed7f8303081080520fe91551`;
- Nereus Pulsar: `3667f1a5b51eeff8e7566353a92dc6e14e9bae56`;
- Nereus v0.1.0: `e06f03fbe7db89030454d1060f5947a74664ae70`.

The benchmark values are frozen to these three source-qualified local
containerd tags:

- `nereus-benchmark/pulsar:5.0.0-m1-apache-p8dae0236-amd64`;
- `nereus-benchmark/pulsar:5.0.0-m1-nereus-p3667f1a5-ne06f03fb-amd64`;
- `nereus-benchmark/nereus-admin:v0.1.0-ne06f03fb-amd64`.

The tag is only a readable identity. The checksummed build manifest and the
full image IDs recorded there remain the immutable source of truth. Import the
same archive on every schedulable node and retain the manifest beside the
deployment evidence.

## 1. Build immutable images

Do this only after the Nereus `v0.1.0` and Pulsar
`5.0.0-M1-nereus` changes have been committed. The build script deliberately
rejects dirty or untracked source because an uncommitted image cannot be
identified by a Git SHA.

On one build node:

```bash
cd /root/denovo/nereus/nereus

./scripts/build-pulsar-5.0.0-M1-images.sh \
  --pulsar-repo /root/denovo/nereus/pulsar \
  --worktree-root /root/denovo/nereus/pulsar-worktrees \
  --nereus-pulsar-ref 3667f1a5b51eeff8e7566353a92dc6e14e9bae56 \
  --nereus-source-ref e06f03fbe7db89030454d1060f5947a74664ae70 \
  --admin-base-image 'eclipse-temurin:21-jre-noble@sha256:<PINNED_DIGEST>'
```

The build produces:

- the Apache `8dae0236` Pulsar image;
- a Pulsar/Nereus image qualified by both final Git SHAs;
- a Nereus admin image qualified by the final Nereus SHA;
- image IDs, native inspect output, digest listings, all three Dockerfile
  SHA-256 identities, and a checksummed env manifest under
  `build/performance-images/`.

Build on either Kubernetes node. Building on one node does not make an image
visible in the other node's containerd content store. Prefer pushing the three
images to a registry reachable by both nodes. Without a registry, save once
and import the exact same archive on every node that may run Pulsar:

```bash
./scripts/containerd-transfer-pulsar-5.0.0-M1-images.sh save \
  build/performance-images/pulsar-5.0.0-M1-amd64.env \
  /srv/images/nereus-pulsar-v0.1.0-amd64.tar

CONTAINERD_USE_SUDO=true \
./scripts/containerd-transfer-pulsar-5.0.0-M1-images.sh load \
  /srv/images/nereus-pulsar-v0.1.0-amd64.tar \
  build/performance-images/pulsar-5.0.0-M1-amd64.env
```

Run the `load` command on both Kubernetes nodes when using
`imagePullPolicy: Never`.

Oxia is also an explicit benchmark dependency. It is not included in the
three-image Pulsar archive. The common values freeze
`oxia/oxia:0.16.7` with `imagePullPolicy: Never`, so import that image on every
node that can run `workload=pulsar` (or pre-pull it directly into the `k8s.io`
containerd namespace):

```bash
nerdctl --namespace k8s.io pull oxia/oxia:0.16.7
nerdctl --namespace k8s.io images --digests --no-trunc oxia/oxia:0.16.7
```

Record the same full Oxia image ID/digest on each eligible node. Deployment
evidence captures all four running Oxia containers and fails if they do not
resolve to one identical SHA-256 image identity.

SeaweedFS is a separate third-party image. It must exist in the `k8s.io`
containerd namespace on the node labeled `nereus-object-store=true`; importing
it only on the Pulsar node or into containerd's `default` namespace is
insufficient. Resolve `chrislusf/seaweedfs:4.29` once, record its digest, tag it
as `nereus-benchmark/seaweedfs:4.29-amd64`, and transfer that exact local image
when the apps node cannot pull from the registry. `SERVER-RUNBOOK.md` contains
both the direct-pull and offline-transfer commands.

## 2. Create one campaign identity

Do not edit the tracked common or stage values for each server run. Generate a
small untracked values layer from the checksummed image manifest instead.
First choose the short benchmark release, target Kubernetes namespace, and
Pulsar cluster name. The old `beijing-1` release must not run concurrently
with the benchmark because it would consume the same nodes and storage pool:

```bash
kubectl config current-context

export NEREUS_EXPECTED_CONTEXT='<EXACT_EXPECTED_CONTEXT>'
export NEREUS_RELEASE='nereus'
export NEREUS_NAMESPACE='pulsar'
export NEREUS_CLUSTER='beijing-1-benchmark'
export NEREUS_SECRET_NAME='pulsar-nereus-secrets'
export NEREUS_RESULTS_ROOT='/root/denovo/nereus-campaign/results'

mkdir -p /root/denovo/nereus-campaign
./scripts/prepare-nereus-campaign-values.sh \
  /root/denovo/nereus-campaign/values-campaign.yaml \
  /root/denovo/nereus/nereus/build/performance-images/pulsar-5.0.0-M1-amd64.env

export NEREUS_CAMPAIGN_VALUES=\
/root/denovo/nereus-campaign/values-campaign.yaml
export NEREUS_OPERATOR_EVIDENCE_FILE=\
/root/denovo/nereus-campaign/values-campaign.operator-evidence.txt
```

The helper verifies the manifest sidecar, exact source SHAs, image names, and
full image IDs. It derives a canonical BookKeeper/Oxia provider scope, creates
one reservation UUID, and writes a non-secret operator-evidence file next to
the values file. Stage A uses this evidence to check the running Apache image
ID. B–E also verify that the provider scope, reservation, and evidence SHA-256
rendered into the admin configuration match the same file, then check all
running Apache, Nereus broker, and Nereus admin image IDs.

`values-campaign.yaml` and
`values-campaign.operator-evidence.txt` are intentionally ignored by Git.
They are generated deployment inputs bound to one exact Kubernetes context,
release, namespace, cluster, image manifest, provider scope, and reservation;
they are not reusable source defaults. The evidence file contains no secret,
but committing either file would make it easy to reuse a physical-provider
identity accidentally. `values-campaign.example.yaml` is the tracked schema
and documentation; regenerate the ignored pair with the helper for the real
campaign.

The generated evidence is also the image source of truth. The deployment and
cold-reset scripts read the manifest-qualified image references from that
evidence and inject the stage-appropriate broker image into Helm, so a new
Nereus source SHA does not require editing server-side scripts or reusing a
stale hard-coded tag.

Use the same generated identity for B–E in this campaign. Do not regenerate it
between profiles, and never reuse its reservation UUID for another physical
BookKeeper provider scope. For an external/shared BookKeeper service, set
`NEREUS_BOOKKEEPER_PROVIDER_SCOPE_ID` to its canonical non-secret
metadata-service/ledger-root identity before running the helper.

## 3. Prepare the two nodes

The benchmark does not deploy ZooKeeper. Pulsar and BookKeeper metadata both
use Oxia. Each of the three Oxia server Pods requests a 47 Gi PVC from the
existing `local-zk` StorageClass. Oxia server and coordinator requests/limits
are intentionally synchronized with the former ZooKeeper benchmark envelope:
2 CPU and 2 Gi requested, 2 CPU and 2304 Mi limited.

Check the existing local storage before installing:

```bash
kubectl get storageclass local-zk -o wide
kubectl get pv \
  -o custom-columns='NAME:.metadata.name,CLASS:.spec.storageClassName,PHASE:.status.phase,CAPACITY:.spec.capacity.storage,NODE:.spec.nodeAffinity.required.nodeSelectorTerms[*].matchExpressions[*].values[*]'
```

For the first install with a `kubernetes.io/no-provisioner` StorageClass, at
least three suitable `Available` PVs must remain for Oxia. PVs already bound to
the old ZooKeeper cluster cannot be reused while that cluster remains
installed; add three new local PVs with class `local-zk` instead of deleting
the old cluster. Every A–E measurement is a cold install: the deploy preflight
rejects an existing release or residual benchmark data PVC and requires all
three Oxia PVs to be `Available`.

Create the local SeaweedFS storage class/PV after editing the example PV path:

```bash
kubectl apply \
  -f examples/nereus-benchmark/storage/local-seaweedfs-storage-class.yaml
kubectl apply \
  -f examples/nereus-benchmark/storage/local-seaweedfs-pv.example.yaml
```

Apply scheduling labels:

```bash
kubectl label node <PULSAR_NODE> workload=pulsar --overwrite
kubectl label node <APPS_NODE> workload=apps --overwrite
kubectl label node <APPS_NODE> nereus-object-store=true --overwrite
```

The benchmark topology is intentionally strict: exactly one schedulable Ready
node must match `workload=pulsar`, and exactly one different schedulable Ready
node must match both `workload=apps` and `nereus-object-store=true`. Brokers,
BookKeeper, AutoRecovery, Oxia, toolset, metadata/admin Jobs, and monitoring
run on the Pulsar node. Only the SeaweedFS object-store StatefulSet runs on the
apps node. The benchmark profile fixes SeaweedFS at 4 CPU and 4 GiB. On the
current 6-P-Core/4-E-Core apps node, kubelet static CPU Manager must reserve the
E-Core logical CPUs and enable `full-pcpus-only`, so the 4 CPU SeaweedFS
Guaranteed Pod receives two complete P-Cores.

If the nodes are tainted, use matching taints:

```bash
kubectl taint node <PULSAR_NODE> dedicated=pulsar:NoSchedule --overwrite
kubectl taint node <APPS_NODE> dedicated=apps:NoSchedule --overwrite
```

Verify the labels before installing:

```bash
kubectl get nodes -L workload,nereus-object-store -o wide
```

Create the namespace and runtime Secret once before Stage A. Do not rotate it
between stages and do not commit the populated Secret:

```bash
kubectl create namespace "${NEREUS_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -
SEAWEEDFS_ACCESS_KEY="nereus$(openssl rand -hex 8)"
SEAWEEDFS_SECRET_KEY="$(openssl rand -hex 32)"
NEREUS_BK_PASSWORD="$(openssl rand -hex 32)"
kubectl -n "${NEREUS_NAMESPACE}" create secret generic pulsar-nereus-secrets \
  --from-literal=access-key="${SEAWEEDFS_ACCESS_KEY}" \
  --from-literal=secret-key="${SEAWEEDFS_SECRET_KEY}" \
  --from-literal=bookkeeper-password="${NEREUS_BK_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
unset SEAWEEDFS_ACCESS_KEY SEAWEEDFS_SECRET_KEY NEREUS_BK_PASSWORD
```

## 4. Preflight the Chart

Run all five positive renders, both supported load managers, and the negative
fail-closed matrix:

```bash
./scripts/test-nereus-render.sh
```

## 5. Deploy, measure, and cold-reset each stage

Keep the exports from section 2 in the same shell. Deployment fails before any
Kubernetes mutation if the context differs, the campaign identity/evidence is
missing, an image/identity placeholder remains, the Helm release still exists,
or a data PVC from the previous stage remains.

```bash
kubectl config current-context
```

Stage A:

```bash
./scripts/deploy-nereus-stage.sh A
./scripts/verify-nereus-release.sh A

# Run the manual A performance workload here, then stop every load client.

./scripts/verify-nereus-release.sh A
./scripts/collect-helm-evidence.sh

# First command is read-only and prints the exact PVC/PV reset plan.
./scripts/reset-nereus-benchmark-stage.sh A

# The plan prints this exact confirmation value.
NEREUS_COLD_RESET_CONFIRM='pulsar/nereus/A' \
  ./scripts/reset-nereus-benchmark-stage.sh A --execute
```

Stage B:

```bash
./scripts/deploy-nereus-stage.sh B
./scripts/activate-nereus-publications.sh B
./scripts/run-object-store-contract.sh
./scripts/verify-nereus-release.sh B

# Run the manual B performance workload here, then stop every load client.

./scripts/verify-nereus-release.sh B
./scripts/collect-helm-evidence.sh
./scripts/reset-nereus-benchmark-stage.sh B
NEREUS_COLD_RESET_CONFIRM='pulsar/nereus/B' \
  ./scripts/reset-nereus-benchmark-stage.sh B --execute
```

Repeat the Stage B block with `C`, `D`, and `E`, including activation,
contract, verification, evidence collection, and the matching reset
confirmation suffix. Activation reads broker-generated readiness,
activates all BookKeeper publication capabilities against the initial
generation-capable broker set, runs generation registration backfill, and
restarts brokers. Once the restarted brokers advertise their durable
BookKeeper binding, the script must rebind activation to the stronger
BookKeeper readiness identity and rerun backfill against the new generation
identity. The verification gate requires the final activation epoch and digest
to equal the live BookKeeper readiness. The object-store gate runs the full S3
contract, leaves one exact marker, restarts SeaweedFS, verifies the same marker,
then conditionally removes it. B–E verification fails closed when any contract
or restart-persistence evidence file is absent or unsuccessful.

The benchmark deliberately keeps Pulsar's inactive-topic cleanup policy
enabled. Because an empty A/B smoke topic can be removed after 60 seconds
without subscriptions, the B activation gate and A/B release verification
idempotently ensure that recorded smoke topic immediately before collecting
its stats. C–E do not create a smoke topic: their Nereus storage profile does
not support this stock topic feature, and the formal workload creates its own
topic. This does not change the stage storage class or workload topic behavior.

Every script writes non-secret evidence below the deployment run directory.
The deployment run records the Kubernetes context; every later gate rejects a
different current context, release, or namespace. `collect-helm-evidence.sh`
packages the evidence and emits an archive SHA-256.

The reset script refuses to run until the evidence archive and its checksum
exist. It uninstalls Helm, mounts every release-owned data PVC through a
short-lived root cleaner Pod using the already imported Apache image, verifies
that each filesystem is empty, deletes all 16 PVCs (Oxia 3, BookKeeper 12,
SeaweedFS 1), and returns `Retain` PVs to `Available`. A failed wipe leaves the
PVC in place and stops; rerunning the same command resumes from the recorded
PVC/PV map. It does not delete the namespace, runtime Secret, campaign values,
or results archive.

After every reset, verify the storage pool before installing the next stage:

```bash
helm -n "${NEREUS_NAMESPACE}" list --all
kubectl -n "${NEREUS_NAMESPACE}" get pvc
kubectl get pv \
  -o custom-columns='NAME:.metadata.name,CLASS:.spec.storageClassName,PHASE:.status.phase,CAPACITY:.spec.capacity.storage'
```

There must be no `nereus` Helm release and no benchmark data PVC.
All static PVs needed by Oxia, BookKeeper, and SeaweedFS must be `Available`.
The next `deploy-nereus-stage.sh` invocation performs a new `helm install`,
therefore Oxia metadata, BookKeeper ledgers/journals/indexes, SeaweedFS
objects, and Pulsar metadata all start empty.

If local PV manifests are deliberately deleted and recreated between stages,
do that only after the reset script has wiped and deleted the PVCs. Deleting a
`Retain` PV object does not erase its local path. Do not mix a bare
`helm uninstall` plus `kubectl delete -f <pv.yaml>` with the reset script:
either let the reset return the existing PVs to `Available`, or additionally
delete/re-apply the PV manifests after the reset has completed. In the latter
case, verify every backing directory is empty before re-applying
`bookie_index_pv.yaml`, `ledger_pv.yaml`, `zk_pv.yaml`, `journal_pv.yaml`, and
the SeaweedFS PV manifest. Reset the monitoring PV too only when monitoring is
part of the measured Helm release and its historical samples must not cross
stage boundaries.

The `pulsar` namespace is shared infrastructure in this campaign. Do not
delete it after Stage E; the reset removes only the `nereus` release and its
benchmark data.
