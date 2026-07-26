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
with Oxia. The common values select Extensible only to keep the benchmark
variable fixed; the Chart does not reject either implementation.

## Frozen Source Identities

- Apache Pulsar: `8dae0236c0a0d405ed7f8303081080520fe91551`;
- Nereus Pulsar: `50fc70fe4620febcf0fd31d97ff7d2be447af3d4`;
- Nereus v0.1.0: `78a1544596af3c74ec1f3ce8b6194f015f6a2c9a`.

The planned Nereus broker and admin tags are
`5.0.0-m1-nereus-p50fc70fe-n78a15445-amd64` and
`v0.1.0-n78a15445-amd64`. They are source-qualified names, not proof that the
images have already been built. Keep the zero-valued tags in the example
values until the build manifest records the actual image IDs/digests, then
replace all placeholders from that manifest.

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
  --nereus-pulsar-ref 50fc70fe4620febcf0fd31d97ff7d2be447af3d4 \
  --nereus-source-ref 78a1544596af3c74ec1f3ce8b6194f015f6a2c9a \
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

SeaweedFS is a separate third-party image. Resolve `chrislusf/seaweedfs:4.29`
to a digest once, record that digest, tag it as
`nereus-benchmark/seaweedfs:4.29-amd64`, and either push it to the same registry
or import it on the node labeled `nereus-object-store=true`.

## 2. Replace campaign placeholders

Before deployment, replace these values with the build manifest and
campaign-specific identities:

- B–E broker image tag (`p50fc70fe-n78a15445`);
- Nereus admin image tag;
- `nereus.bookkeeperWal.providerScopeSha256`;
- `nereus.bookkeeperWal.ledgerIdNamespaceReservationId`;
- `nereus.admin.operatorEvidenceSha256`.

The deployment script renders first and refuses zero/SHA placeholders before
mutating the Helm release.

## 3. Prepare the two nodes

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
kubectl label node <APP_NODE> workload=app --overwrite
kubectl label node <APP_NODE> nereus-object-store=true --overwrite
```

Create the namespace and runtime secret. Do not commit the populated Secret:

```bash
kubectl create namespace pulsar --dry-run=client -o yaml | kubectl apply -f -
kubectl -n pulsar create secret generic pulsar-nereus-secrets \
  --from-literal=access-key='<SEAWEEDFS_ACCESS_KEY>' \
  --from-literal=secret-key='<SEAWEEDFS_SECRET_KEY>' \
  --from-literal=bookkeeper-password='<NEREUS_BK_PASSWORD>'
```

## 4. Preflight the Chart

Run all five positive renders, both supported load managers, and the negative
fail-closed matrix:

```bash
./scripts/test-nereus-render.sh
```

## 5. Deploy and gate each stage

Inspect the active context and name the expected target explicitly. Deployment
fails before any Kubernetes mutation when the values differ:

```bash
kubectl config current-context
export NEREUS_EXPECTED_CONTEXT='<EXACT_EXPECTED_CONTEXT>'
```

Stage A:

```bash
./scripts/deploy-nereus-stage.sh A
./scripts/verify-nereus-release.sh A
./scripts/collect-helm-evidence.sh
```

Stages B–E:

```bash
./scripts/deploy-nereus-stage.sh B
./scripts/activate-nereus-publications.sh B
./scripts/run-object-store-contract.sh
./scripts/verify-nereus-release.sh B
./scripts/collect-helm-evidence.sh
```

Repeat with `C`, `D`, and `E`. Activation reads broker-generated readiness,
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

Every script writes non-secret evidence below the deployment run directory.
The deployment run records the Kubernetes context; every later gate rejects a
different current context, release, or namespace. `collect-helm-evidence.sh`
packages the evidence and emits an archive SHA-256.
