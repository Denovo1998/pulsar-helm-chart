#!/usr/bin/env bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

set -euo pipefail

die() {
  echo "ERROR: $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
chart="${repo_root}/charts/pulsar"
common="${repo_root}/examples/nereus-benchmark/values-common.yaml"
expected_apache_image="$(sed -n 's/^defaultPulsarImageTag: //p' "${common}")"
expected_nereus_image="$(sed -n 's/^    tag: //p' "${repo_root}/examples/nereus-benchmark/values-stage-b-dormant.yaml")"
expected_admin_image="$(sed -n 's/^      tag: //p' "${common}")"
[[ -n "${expected_apache_image}" && -n "${expected_nereus_image}" \
    && -n "${expected_admin_image}" ]] \
  || die "benchmark image defaults are incomplete"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/nereus-render.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT
positive_identity_args=(
  --set-string "nereus.bookkeeperWal.providerScopeSha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  --set-string "nereus.bookkeeperWal.ledgerIdNamespaceReservationId=11111111-1111-4111-8111-111111111111"
  --set-string "nereus.admin.operatorEvidenceSha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
)

expect_failure() {
  local name="$1"
  local expected="$2"
  shift 2
  local output="${temporary_dir}/${name}.txt"
  if helm template pulsar "${chart}" \
      --namespace pulsar \
      -f "${common}" \
      -f "${repo_root}/examples/nereus-benchmark/values-stage-b-dormant.yaml" \
      "$@" >"${output}" 2>&1; then
    die "negative render unexpectedly succeeded: ${name}"
  fi
  grep -F "${expected}" "${output}" >/dev/null \
    || die "negative render ${name} failed for the wrong reason; see ${output}"
}

expect_source_contains() {
  local manifest="$1"
  local source="$2"
  local expected="$3"
  local label="$4"
  if ! awk -v marker="# Source: ${source}" '
      $0 == marker {
        capture = 1
      }
      capture {
        print
      }
      capture && /^---$/ {
        exit
      }
    ' "${manifest}" | grep -F "${expected}" >/dev/null; then
    die "${label} did not render ${expected}"
  fi
}

for overlay in "${repo_root}"/examples/nereus-benchmark/values-stage-*.yaml; do
  name="$(basename "${overlay}" .yaml)"
  helm lint "${chart}" \
    -f "${common}" \
    -f "${overlay}" \
    "${positive_identity_args[@]}"
  helm template pulsar "${chart}" \
    --namespace pulsar \
    -f "${common}" \
    -f "${overlay}" \
    "${positive_identity_args[@]}" \
    > "${temporary_dir}/${name}.yaml"
done

stage_a_manifest="${temporary_dir}/values-stage-a-apache.yaml"
stage_b_manifest="${temporary_dir}/values-stage-b-dormant.yaml"
oxia_server_manifest="${temporary_dir}/oxia-server.yaml"
oxia_coordinator_manifest="${temporary_dir}/oxia-coordinator.yaml"
seaweedfs_manifest="${temporary_dir}/seaweedfs.yaml"
awk '
  /^# Source: pulsar\/templates\/oxia-server-statefulset.yaml$/ {
    capture = 1
  }
  capture {
    print
  }
  capture && /^---$/ {
    exit
  }
' "${stage_a_manifest}" > "${oxia_server_manifest}"
awk '
  /^# Source: pulsar\/templates\/oxia-coordinator-deployment.yaml$/ {
    capture = 1
  }
  capture {
    print
  }
  capture && /^---$/ {
    exit
  }
' "${stage_a_manifest}" > "${oxia_coordinator_manifest}"
awk '
  /^# Source: pulsar\/templates\/nereus-seaweedfs-statefulset.yaml$/ {
    capture = 1
  }
  capture {
    print
  }
  capture && /^---$/ {
    exit
  }
' "${stage_a_manifest}" > "${seaweedfs_manifest}"
if grep -Eq 'pulsar-nereus-admin|nereusEnabled:' \
    "${stage_a_manifest}"; then
  die "stage A unexpectedly renders Nereus admin or Broker configuration"
fi
grep -F 'component: seaweedfs' "${stage_a_manifest}" >/dev/null \
  || die "stage A did not render the common SeaweedFS topology"
grep -F 'component: seaweedfs' "${stage_b_manifest}" >/dev/null \
  || die "stage B did not render SeaweedFS"
grep -F 'workload: apps' "${seaweedfs_manifest}" >/dev/null \
  || die "SeaweedFS is not pinned to workload=apps"
grep -F 'nereus-object-store: "true"' "${seaweedfs_manifest}" >/dev/null \
  || die "SeaweedFS is not pinned to the object-store node"
if grep -Eq '^[[:space:]]*workload: app$' "${seaweedfs_manifest}"; then
  die "SeaweedFS still renders the obsolete workload=app selector"
fi
grep -F 'pulsar-nereus-admin' "${stage_b_manifest}" >/dev/null \
  || die "stage B did not render the Nereus admin ConfigMap"
grep -F 'PULSAR_PREFIX_nereusBookKeeperPrimaryWalEnabled: "true"' \
  "${stage_b_manifest}" >/dev/null \
  || die "stage B did not expose the Nereus BookKeeper runtime flag"
grep -F 'PULSAR_PREFIX_nereusBookKeeperEnsembleSize: "3"' \
  "${stage_b_manifest}" >/dev/null \
  || die "stage B did not expose the Nereus BookKeeper quorum settings"
grep -F -- '- /dev/termination-log' "${stage_b_manifest}" >/dev/null \
  || die "stage B bootstrap does not preserve termination evidence"
grep -F \
  "${expected_apache_image}" \
  "${stage_a_manifest}" >/dev/null \
  || die "stage A did not render the configured Apache Pulsar image"
grep -F \
  "${expected_nereus_image}" \
  "${stage_b_manifest}" >/dev/null \
  || die "stage B did not render the configured Nereus Pulsar image"
grep -F \
  "${expected_admin_image}" \
  "${stage_b_manifest}" >/dev/null \
  || die "stage B did not render the configured Nereus admin image"
grep -F 'metadataStoreUrl: "oxia://pulsar-oxia-svc:6648/broker"' \
  "${stage_a_manifest}" >/dev/null \
  || die "the Pulsar metadata path is not using Oxia"
grep -F \
  'bookkeeperMetadataServiceUri: "metadata-store:oxia://pulsar-oxia-svc:6648/bookkeeper"' \
  "${stage_a_manifest}" >/dev/null \
  || die "the BookKeeper metadata path is not using Oxia"
if grep -Eq \
    '^[[:space:]]*(name: pulsar-zookeeper|component: zookeeper|metadataStoreUrl: "zk|bookkeeperMetadataServiceUri: "zk)' \
    "${stage_a_manifest}"; then
  die "stage A unexpectedly rendered a ZooKeeper resource or metadata URL"
fi
for pulsar_source in \
  pulsar/templates/oxia-coordinator-deployment.yaml \
  pulsar/templates/oxia-server-statefulset.yaml \
  pulsar/templates/bookkeeper-statefulset.yaml \
  pulsar/templates/autorecovery-statefulset.yaml \
  pulsar/templates/broker-statefulset.yaml \
  pulsar/templates/toolset-statefulset.yaml \
  pulsar/templates/bookkeeper-cluster-initialize.yaml \
  pulsar/templates/pulsar-cluster-initialize.yaml \
  pulsar/charts/victoria-metrics-k8s-stack/charts/grafana/templates/deployment.yaml \
  pulsar/charts/victoria-metrics-k8s-stack/charts/kube-state-metrics/templates/deployment.yaml \
  pulsar/charts/victoria-metrics-k8s-stack/charts/prometheus-node-exporter/templates/daemonset.yaml \
  pulsar/charts/victoria-metrics-k8s-stack/charts/victoria-metrics-operator/templates/deployment.yaml \
  pulsar/charts/victoria-metrics-k8s-stack/templates/victoria-metrics-operator/vmagent/vmagent.yaml \
  pulsar/charts/victoria-metrics-k8s-stack/templates/victoria-metrics-operator/vmsingle/vmsingle.yml; do
  expect_source_contains \
    "${stage_a_manifest}" "${pulsar_source}" \
    "workload: pulsar" "${pulsar_source}"
done
expect_source_contains \
  "${stage_b_manifest}" \
  pulsar/templates/nereus-bookkeeper-bootstrap-job.yaml \
  "workload: pulsar" "Nereus BookKeeper bootstrap Job"
grep -F 'storageClassName: local-zk' "${oxia_server_manifest}" >/dev/null \
  || die "Oxia did not reuse the local-zk storage class"
grep -F 'storage: 47Gi' "${oxia_server_manifest}" >/dev/null \
  || die "Oxia storage size is not synchronized with ZooKeeper"
for oxia_manifest in "${oxia_server_manifest}" "${oxia_coordinator_manifest}"; do
  grep -F 'workload: pulsar' "${oxia_manifest}" >/dev/null \
    || die "Oxia is not pinned to workload=pulsar"
  grep -F 'image: "oxia/oxia:0.16.7"' "${oxia_manifest}" >/dev/null \
    || die "Oxia did not render the frozen image tag"
  grep -F 'imagePullPolicy: "Never"' "${oxia_manifest}" >/dev/null \
    || die "Oxia image pull policy is not immutable/local"
  grep -F 'cpu: 2' "${oxia_manifest}" >/dev/null \
    || die "Oxia CPU resources are not synchronized with ZooKeeper"
  grep -F 'memory: 2Gi' "${oxia_manifest}" >/dev/null \
    || die "Oxia memory requests are not synchronized with ZooKeeper"
  grep -F 'memory: 2304Mi' "${oxia_manifest}" >/dev/null \
    || die "Oxia memory limits are not synchronized with ZooKeeper"
done

helm template pulsar "${chart}" \
  --namespace pulsar-benchmark \
  -f "${common}" \
  -f "${repo_root}/examples/nereus-benchmark/values-stage-a-apache.yaml" \
  "${positive_identity_args[@]}" \
  > "${temporary_dir}/namespace-override.yaml"
grep -Eq '^[[:space:]]*namespace: pulsar-benchmark$' \
  "${temporary_dir}/namespace-override.yaml" \
  || die "the release namespace was not propagated to rendered resources"
if grep -Eq '^[[:space:]]*namespace: pulsar$' \
    "${temporary_dir}/namespace-override.yaml"; then
  die "values-common.yaml still pins rendered resources to the pulsar namespace"
fi

for load_manager in \
  org.apache.pulsar.broker.loadbalance.impl.ModularLoadManagerImpl \
  org.apache.pulsar.broker.loadbalance.extensions.ExtensibleLoadManagerImpl \
  com.example.CustomMetadataStoreLoadManager; do
  helm template pulsar "${chart}" \
    --namespace pulsar \
    -f "${common}" \
    -f "${repo_root}/examples/nereus-benchmark/values-stage-b-dormant.yaml" \
    "${positive_identity_args[@]}" \
    --set-string "broker.configData.loadManagerClassName=${load_manager}" \
    > "${temporary_dir}/load-manager-$(basename "${load_manager}")"
done

expect_failure \
  no-oxia \
  "Nereus requires components.oxia=true" \
  --set components.oxia=false
expect_failure \
  missing-nereus-oxia-namespace \
  'oxia.extraNamespaces must contain the Nereus namespace "missing"' \
  --set-string nereus.oxia.namespace=missing
expect_failure \
  unsupported-profile \
  "unsupported Nereus storage profile" \
  --set-string nereus.defaultStorageProfile=INVALID
expect_failure \
  legacy-object-wal-profile \
  "unsupported Nereus storage profile" \
  --set-string nereus.defaultStorageProfile=OBJECT_WAL
expect_failure \
  bookkeeper-profile-without-runtime \
  "BookKeeper WAL profiles require nereus.bookkeeperWal.enabled=true" \
  --set nereus.bookkeeperWal.enabled=false
expect_failure \
  noop-secret-resolver \
  "benchmark Nereus runtime cannot use NoopObjectStoreSecretResolver" \
  --set-string nereus.secrets.resolverClassName=com.nereusstream.objectstore.NoopObjectStoreSecretResolver
expect_failure \
  missing-secret \
  "nereus.secrets.existingSecret is required" \
  --set-string nereus.secrets.existingSecret=
expect_failure \
  missing-secret-key \
  "nereus.secrets.accessKeyKey is required" \
  --set-string nereus.secrets.accessKeyKey=
expect_failure \
  invalid-secret-environment-reference \
  'Nereus secret environment reference "not-valid" is invalid' \
  --set-string nereus.secrets.accessKeyReference=not-valid
expect_failure \
  duplicate-secret-environment-reference \
  'Nereus secret environment reference "NEREUS_S3_ACCESS_KEY" is duplicated' \
  --set-string nereus.secrets.secretKeyReference=NEREUS_S3_ACCESS_KEY
expect_failure \
  missing-provider-scope \
  "bookkeeperWal.providerScopeSha256 is required" \
  --set-string nereus.bookkeeperWal.providerScopeSha256=
expect_failure \
  invalid-provider-scope \
  "providerScopeSha256 must be 64 lowercase hex" \
  --set-string nereus.bookkeeperWal.providerScopeSha256=invalid
expect_failure \
  missing-reservation \
  "ledgerIdNamespaceReservationId is required" \
  --set-string nereus.bookkeeperWal.ledgerIdNamespaceReservationId=
expect_failure \
  ensemble-below-write \
  "ensembleSize must be >= writeQuorumSize" \
  --set nereus.bookkeeperWal.ensembleSize=2
expect_failure \
  write-below-ack \
  "writeQuorumSize must be >= ackQuorumSize" \
  --set nereus.bookkeeperWal.writeQuorumSize=1
expect_failure \
  missing-admin-tag \
  "nereus.admin.image.tag is required" \
  --set-string nereus.admin.image.tag=
expect_failure \
  reserved-broker-key \
  "broker.configData cannot override Nereus-managed key" \
  --set-string broker.configData.nereusEnabled=false
expect_failure \
  invalid-staging-type \
  "nereus.staging.volume.type must be emptyDir, existingClaim, or hostPath" \
  --set-string nereus.staging.volume.type=invalid
expect_failure \
  missing-staging-claim \
  "nereus.staging.volume.existingClaim is required" \
  --set-string nereus.staging.volume.type=existingClaim \
  --set-string nereus.staging.volume.existingClaim=
expect_failure \
  invalid-seaweed-replicas \
  "weed mini benchmark mode requires replicaCount=1" \
  --set nereus.objectStore.seaweedfs.replicaCount=2
expect_failure \
  seaweed-persistence-disabled \
  "SeaweedFS requires persistent storage" \
  --set nereus.objectStore.seaweedfs.persistence.enabled=false \
  --set-string nereus.objectStore.seaweedfs.persistence.existingClaim=

for deployment_identity_guard in \
  'run_nerdctl images' \
  '--digests' \
  "--format '{{json .}}'" \
  'APACHE_IMAGE_CONFIG_ID' \
  '-l "release=${release}" -o json'; do
  grep -F -- "${deployment_identity_guard}" \
    "${repo_root}/scripts/deploy-nereus-stage.sh" >/dev/null \
    || die "deployment image identity guard is missing: ${deployment_identity_guard}"
done
if grep -F -- 'image inspect --mode native' \
    "${repo_root}/scripts/deploy-nereus-stage.sh" >/dev/null; then
  die "deployment image identity guard still depends on unstable native inspect output"
fi

campaign_preflight_output="${temporary_dir}/missing-campaign.txt"
if NEREUS_EXPECTED_CONTEXT=not-used \
    NEREUS_CAMPAIGN_VALUES= \
    NEREUS_OPERATOR_EVIDENCE_FILE= \
    "${repo_root}/scripts/deploy-nereus-stage.sh" A \
    >"${campaign_preflight_output}" 2>&1; then
  die "deployment preflight unexpectedly accepted a missing campaign identity"
fi
grep -F "NEREUS_CAMPAIGN_VALUES is required for stages A-E" \
  "${campaign_preflight_output}" >/dev/null \
  || die "deployment preflight failed for the wrong missing-campaign reason"

echo "Nereus Helm render matrix passed"
