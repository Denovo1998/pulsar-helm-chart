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

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
results_root="${NEREUS_RESULTS_ROOT:-${repo_root}/results}"
run_env="${NEREUS_RUN_ENV:-${results_root}/deploy/latest.env}"
[[ -r "${run_env}" ]] || die "deployment run file is not readable: ${run_env}"

# shellcheck disable=SC1090
source "${run_env}"
[[ -n "${APACHE_IMAGE:-}" && -n "${NEREUS_IMAGE:-}" && -n "${NEREUS_ADMIN_IMAGE:-}" ]] \
  || die "deployment run does not record the manifest-qualified benchmark images"
stage="${1:-${STAGE}}"
[[ "${stage}" == "${STAGE}" ]] \
  || die "requested stage ${stage} does not match deployed stage ${STAGE}"
release="${NEREUS_RELEASE:-${RELEASE}}"
namespace="${NEREUS_NAMESPACE:-${KUBERNETES_NAMESPACE}}"
[[ "${release}" == "${RELEASE}" ]] \
  || die "release override does not match deployment run: ${release}"
[[ "${namespace}" == "${KUBERNETES_NAMESPACE}" ]] \
  || die "namespace override does not match deployment run: ${namespace}"
admin_timeout_seconds="${NEREUS_ADMIN_TIMEOUT_SECONDS:-600}"
[[ "${admin_timeout_seconds}" =~ ^[1-9][0-9]*$
    && "${admin_timeout_seconds}" -le 86400 ]] \
  || die "NEREUS_ADMIN_TIMEOUT_SECONDS must be between 1 and 86400"
verification_dir="${RUN_DIR}/verification"
mkdir -p "${verification_dir}"

for command_name in helm kubectl jq grep; do
  require_command "${command_name}"
done
recorded_context="${KUBERNETES_CONTEXT:-}"
[[ -n "${recorded_context}" ]] \
  || die "deployment run does not record KUBERNETES_CONTEXT"
current_context="$(kubectl config current-context)"
[[ "${current_context}" == "${recorded_context}" ]] \
  || die "Kubernetes context mismatch: expected ${recorded_context}, got ${current_context}"

kubectl -n "${namespace}" get pods \
  -l "release=${release}" -o json \
  > "${verification_dir}/pods.json"
kubectl -n "${namespace}" get pvc -o json \
  > "${verification_dir}/pvcs.json"
kubectl -n "${namespace}" get statefulset,deployment,job -o json \
  > "${verification_dir}/workloads.json"
helm -n "${namespace}" get values "${release}" --all -o json \
  > "${verification_dir}/helm-values.json"

jq -e '
  (.items | length) > 0
  and all(.items[];
    (.status.phase == "Running" or .status.phase == "Succeeded")
    and
    (if .status.phase == "Running"
     then all((.status.containerStatuses // [])[]; .ready == true)
     else true
     end))
' "${verification_dir}/pods.json" >/dev/null \
  || die "one or more Pods are failed, pending, or not Ready"

jq -e '(.items | length) > 0 and all(.items[]; .status.phase == "Bound")' \
  "${verification_dir}/pvcs.json" >/dev/null \
  || die "one or more PVCs are not Bound"

jq -e '
  all(.items[];
    all(((.status.containerStatuses // [])
      + (.status.initContainerStatuses // []))[];
      (.imageID // "") != ""))
' "${verification_dir}/pods.json" >/dev/null \
  || die "one or more container image IDs are missing"

if jq -r '
    .items[]
    | ((.status.containerStatuses // []) + (.status.initContainerStatuses // []))[]
    | [.image, .imageID]
    | @tsv
  ' "${verification_dir}/pods.json" \
  | grep -Eq \
      '(<FINAL_|n00000000|p00000000|0000000000000000000000000000000000000000000000000000000000000000)'; then
  die "running workload still contains an unresolved image or identity placeholder"
fi

pulsar_node="$(kubectl get nodes -l workload=pulsar -o json | jq -er '
  [.items[]
    | select(.spec.unschedulable != true)
    | select(any(.status.conditions[]?;
        .type == "Ready" and .status == "True"))
    | .metadata.name]
  | select(length == 1)
  | .[0]
')" || die "expected exactly one schedulable Ready workload=pulsar node"
apps_node="$(kubectl get nodes \
  -l 'workload=apps,nereus-object-store=true' -o json | jq -er '
  [.items[]
    | select(.spec.unschedulable != true)
    | select(any(.status.conditions[]?;
        .type == "Ready" and .status == "True"))
    | .metadata.name]
  | select(length == 1)
  | .[0]
')" || die "expected exactly one schedulable Ready workload=apps,nereus-object-store=true node"
[[ "${pulsar_node}" != "${apps_node}" ]] \
  || die "Pulsar and object-store workloads must use different nodes"

while IFS=$'\t' read -r pod_name node_name component; do
  case "${component}" in
    seaweedfs)
      [[ "${node_name}" == "${apps_node}" ]] \
        || die "${pod_name} is not scheduled on object-store node ${apps_node}"
      [[ "$(kubectl get node "${node_name}" \
          -o jsonpath='{.metadata.labels.workload}')" == "apps" ]] \
        || die "${pod_name} is not scheduled on workload=apps"
      [[ "$(kubectl get node "${node_name}" \
          -o jsonpath='{.metadata.labels.nereus-object-store}')" == "true" ]] \
        || die "${pod_name} is not scheduled on nereus-object-store=true"
      ;;
    broker|bookie|recovery|toolset|oxia*)
      [[ "${node_name}" == "${pulsar_node}" ]] \
        || die "${pod_name} is not scheduled on Pulsar node ${pulsar_node}"
      [[ "$(kubectl get node "${node_name}" \
          -o jsonpath='{.metadata.labels.workload}')" == "pulsar" ]] \
        || die "${pod_name} is not scheduled on workload=pulsar"
      ;;
  esac
done < <(jq -r '
  .items[]
  | select(.status.phase == "Running")
  | [.metadata.name, .spec.nodeName, (.metadata.labels.component // "")]
  | @tsv
' "${verification_dir}/pods.json")

kubectl -n "${namespace}" get pods -o json \
  > "${verification_dir}/namespace-pods.json"
monitoring_pod_count="$(
  jq \
    --arg release "${release}" '
      [.items[]
        | select(.status.phase == "Running")
        | select(
            .metadata.labels["app.kubernetes.io/instance"] == $release
            or (.metadata.name | startswith("vmagent-" + $release + "-"))
            or (.metadata.name | startswith("vmsingle-" + $release + "-")))]
      | length
    ' "${verification_dir}/namespace-pods.json"
)"
(( monitoring_pod_count >= 4 )) \
  || die "expected at least four running monitoring Pods for release ${release}"
while IFS=$'\t' read -r pod_name node_name; do
  [[ "${node_name}" == "${pulsar_node}" ]] \
    || die "monitoring Pod ${pod_name} is not scheduled on Pulsar node ${pulsar_node}"
done < <(jq -r \
  --arg release "${release}" '
    .items[]
    | select(.status.phase == "Running")
    | select(
        .metadata.labels["app.kubernetes.io/instance"] == $release
        or (.metadata.name | startswith("vmagent-" + $release + "-"))
        or (.metadata.name | startswith("vmsingle-" + $release + "-")))
    | [.metadata.name, .spec.nodeName]
    | @tsv
  ' "${verification_dir}/namespace-pods.json")

toolset_pod="$(jq -er '
  .items[]
  | select(.metadata.labels.component == "toolset")
  | .metadata.name
' "${verification_dir}/pods.json" | head -n 1)"
pulsar_admin() {
  kubectl -n "${namespace}" exec "${toolset_pod}" -- bin/pulsar-admin "$@"
}

pulsar_admin namespaces get-persistence \
  "${BENCHMARK_TENANT}/${BENCHMARK_NAMESPACE}" \
  > "${verification_dir}/namespace-persistence.json"
jq -e \
  --arg expected "${MANAGED_LEDGER_STORAGE_CLASS}" \
  '(.managedLedgerStorageClassName
      // .managedLedgerStorageClass
      // "") == $expected
    and .bookkeeperEnsemble == 3
    and .bookkeeperWriteQuorum == 3
    and .bookkeeperAckQuorum == 2' \
  "${verification_dir}/namespace-persistence.json" >/dev/null \
  || die "namespace persistence policy does not match the stage"

broker_statefulset="$(kubectl -n "${namespace}" get \
  "statefulset/${release}-broker" -o json)"
broker_image="$(jq -er '.spec.template.spec.containers[0].image' \
  <<<"${broker_statefulset}")"
rendered_stage="$(jq -er \
  '.spec.template.metadata.annotations["benchmark.nereusstream.com/stage"]' \
  <<<"${broker_statefulset}")"
rendered_storage_class="$(jq -er \
  '.spec.template.metadata.annotations["benchmark.nereusstream.com/managed-ledger-storage-class"]' \
  <<<"${broker_statefulset}")"
[[ "${rendered_stage}" == "${stage}" ]] \
  || die "Broker evidence annotation has stage ${rendered_stage}, expected ${stage}"
[[ "${rendered_storage_class}" == "${MANAGED_LEDGER_STORAGE_CLASS}" ]] \
  || die "Broker evidence annotation has storage class ${rendered_storage_class}, expected ${MANAGED_LEDGER_STORAGE_CLASS}"
case "${stage}" in
  A)
    [[ "${broker_image}" == "${APACHE_IMAGE}" ]] \
      || die "stage A is not running the manifest-qualified Apache baseline image"
    if kubectl -n "${namespace}" get \
        "configmap/${release}-nereus-admin" >/dev/null 2>&1; then
      die "stage A unexpectedly rendered the Nereus admin ConfigMap"
    fi
    kubectl -n "${namespace}" get \
      "statefulset/${release}-seaweedfs" >/dev/null
    ;;
  B|C|D|E)
    [[ "${broker_image}" == "${NEREUS_IMAGE}" ]] \
      || die "stage ${stage} is not running the manifest-qualified Nereus image"
    kubectl -n "${namespace}" get \
      "configmap/${release}-nereus-admin" >/dev/null
    kubectl -n "${namespace}" get \
      "statefulset/${release}-seaweedfs" >/dev/null
    ;;
esac

broker_config="${verification_dir}/broker-config.json"
kubectl -n "${namespace}" get "configmap/${release}-broker" -o json \
  > "${broker_config}"
load_manager="$(jq -r '.data.loadManagerClassName // ""' "${broker_config}")"
[[ -n "${load_manager}" ]] \
  || die "benchmark load manager is missing from the Broker ConfigMap"
printf '%s\n' "${load_manager}" > "${verification_dir}/load-manager.txt"

if [[ "${stage}" != "A" ]]; then
  case "${stage}" in
    B|C) expected_profile="BOOKKEEPER_WAL_ONLY" ;;
    D) expected_profile="BOOKKEEPER_WAL_ASYNC_OBJECT" ;;
    E) expected_profile="BOOKKEEPER_WAL_SYNC_OBJECT" ;;
  esac
  jq -e \
    --arg profile "${expected_profile}" \
    '.data.nereusDefaultStorageProfile == $profile
      and .data.nereusBookKeeperEnsembleSize == "3"
      and .data.nereusBookKeeperWriteQuorumSize == "3"
      and .data.nereusBookKeeperAckQuorumSize == "2"
      and .data.nereusPhysicalGcEnabled == "false"
      and .data.nereusPhysicalGcDryRun == "true"
      and .data.nereusBookKeeperGcEnabled == "false"
      and .data.nereusBookKeeperGcDryRun == "true"' \
    "${broker_config}" >/dev/null \
    || die "rendered Nereus broker configuration does not match stage ${stage}"

  api_base="${NEREUS_BROKER_ADMIN_URL:-http://${release}-broker:8080/admin/v2/brokers}"
  kubectl -n "${namespace}" exec "${toolset_pod}" -- \
    curl -fsS --max-time "${admin_timeout_seconds}" \
      "${api_base}/bookkeeper-primary-wal/readiness" \
    > "${verification_dir}/bookkeeper-readiness.json"
  jq -e \
    --argjson expected "$(kubectl -n "${namespace}" get \
      "statefulset/${release}-broker" -o jsonpath='{.spec.replicas}')" \
    '.brokerReadinessEpoch > 0
      and .persistentBrokerCount == $expected
      and (.brokerReadinessSha256 | test("^[0-9a-f]{64}$"))' \
    "${verification_dir}/bookkeeper-readiness.json" >/dev/null \
    || die "BookKeeper readiness does not cover every broker"
  kubectl -n "${namespace}" exec "${toolset_pod}" -- \
    curl -fsS --max-time "${admin_timeout_seconds}" \
      "${api_base}/bookkeeper-primary-wal/activation?timeoutSeconds=${admin_timeout_seconds}" \
    > "${verification_dir}/bookkeeper-activation.json"
  jq -e \
    --slurpfile readiness "${verification_dir}/bookkeeper-readiness.json" \
    '.lifecycle == "ACTIVE"
      and .walOnlyPublicationEnabled == true
      and .asyncPublicationEnabled == true
      and .syncPublicationEnabled == true
      and (.publicationActivationSha256 | test("^[0-9a-f]{64}$"))
      and .brokerReadinessEpoch == $readiness[0].brokerReadinessEpoch
      and .brokerReadinessSha256 == $readiness[0].brokerReadinessSha256' \
    "${verification_dir}/bookkeeper-activation.json" >/dev/null \
    || die "BookKeeper activation is not bound to current strongest readiness"
  kubectl -n "${namespace}" exec "${toolset_pod}" -- \
    curl -fsS --max-time "${admin_timeout_seconds}" \
      "${api_base}/generation-protocol/readiness" \
    > "${verification_dir}/generation-readiness.json"
  jq -e \
    --argjson expected "$(kubectl -n "${namespace}" get \
      "statefulset/${release}-broker" -o jsonpath='{.spec.replicas}')" \
    '.brokerReadinessEpoch > 0
      and .persistentBrokerCount == $expected
      and (.brokerReadinessSha256 | test("^[0-9a-f]{64}$"))' \
    "${verification_dir}/generation-readiness.json" >/dev/null \
    || die "generation readiness does not cover every broker"
fi

if [[ "${stage}" != "A" && ! -d "${RUN_DIR}/object-store-contract" ]]; then
  die "B-E release verification requires object-store contract and restart-persistence evidence"
fi
if [[ -d "${RUN_DIR}/object-store-contract" ]]; then
  for evidence in \
    contract.json \
    persistence-create.json \
    persistence-verify.json \
    persistence-cleanup.json; do
    jq -e '.overallSuccess == true' \
      "${RUN_DIR}/object-store-contract/${evidence}" >/dev/null \
      || die "object-store evidence is incomplete: ${evidence}"
  done
fi

pulsar_admin topics stats "${BENCHMARK_TOPIC}" \
  > "${verification_dir}/smoke-topic-stats.json"
kubectl -n "${namespace}" get pods \
  -l "release=${release}" -o wide \
  > "${verification_dir}/pods.txt"
kubectl -n "${namespace}" get pods \
  -l "release=${release}" \
  -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,IMAGE:.spec.containers[*].image,IMAGE_ID:.status.containerStatuses[*].imageID' \
  > "${verification_dir}/images.txt"

echo "stage ${stage} release verification passed"
echo "evidence: ${verification_dir}"
