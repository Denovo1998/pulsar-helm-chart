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
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/nereus-render.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT

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

for overlay in "${repo_root}"/examples/nereus-benchmark/values-stage-*.yaml; do
  name="$(basename "${overlay}" .yaml)"
  helm lint "${chart}" -f "${common}" -f "${overlay}"
  helm template pulsar "${chart}" \
    --namespace pulsar \
    -f "${common}" \
    -f "${overlay}" \
    > "${temporary_dir}/${name}.yaml"
done

stage_a_manifest="${temporary_dir}/values-stage-a-apache.yaml"
stage_b_manifest="${temporary_dir}/values-stage-b-dormant.yaml"
if grep -Eq 'pulsar-nereus-admin|nereusEnabled:' \
    "${stage_a_manifest}"; then
  die "stage A unexpectedly renders Nereus admin or Broker configuration"
fi
grep -F 'component: seaweedfs' "${stage_a_manifest}" >/dev/null \
  || die "stage A did not render the common SeaweedFS topology"
grep -F 'component: seaweedfs' "${stage_b_manifest}" >/dev/null \
  || die "stage B did not render SeaweedFS"
grep -F 'pulsar-nereus-admin' "${stage_b_manifest}" >/dev/null \
  || die "stage B did not render the Nereus admin ConfigMap"
grep -F -- '- /dev/termination-log' "${stage_b_manifest}" >/dev/null \
  || die "stage B bootstrap does not preserve termination evidence"

for load_manager in \
  org.apache.pulsar.broker.loadbalance.impl.ModularLoadManagerImpl \
  org.apache.pulsar.broker.loadbalance.extensions.ExtensibleLoadManagerImpl \
  com.example.CustomMetadataStoreLoadManager; do
  helm template pulsar "${chart}" \
    --namespace pulsar \
    -f "${common}" \
    -f "${repo_root}/examples/nereus-benchmark/values-stage-b-dormant.yaml" \
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

echo "Nereus Helm render matrix passed"
