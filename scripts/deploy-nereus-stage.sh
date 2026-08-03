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

run_nerdctl() {
  local -a global_args=(--namespace "${containerd_namespace}")
  if [[ -n "${containerd_address}" ]]; then
    global_args+=(--address "${containerd_address}")
  fi
  "${nerdctl_bin}" "${global_args[@]}" "$@"
}

resolve_runtime_config_id() {
  local image="$1"
  local expected_target_digest="$2"
  local label="$3"
  local image_listing
  local target_digest
  local config_id

  image_listing="$(
    run_nerdctl images \
      --digests \
      --no-trunc \
      --format '{{json .}}' \
      "${image}"
  )" || die "could not list the local ${label} OCI target: ${image}"
  target_digest="$(
    jq -Rser '
      [
        split("\n")[]
        | select(test("\\S"))
        | fromjson
        | (.Digest // .digest // .DIGEST // empty)
        | select(type == "string")
      ]
      | unique
      | if length == 1
          and (.[0] | test("^sha256:[0-9a-f]{64}$"))
        then .[0]
        else empty
        end
    ' <<<"${image_listing}"
  )" || die "local ${label} image has no unique OCI target digest: ${image}"
  [[ "${target_digest}" == "${expected_target_digest}" ]] \
    || die "local ${label} OCI target digest ${target_digest} does not match frozen digest ${expected_target_digest}"

  config_id="$(
    run_nerdctl image inspect "${image}" \
      | jq -er '
          .[0].Id
          | select(test("^sha256:[0-9a-f]{64}$"))
        '
  )" || die "local ${label} image has no runtime config ID: ${image}"
  printf '%s\n' "${config_id}"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

evidence_value() {
  local evidence_file="$1"
  local key="$2"
  sed -n "s/^${key}=//p" "${evidence_file}" | tail -n 1
}

wait_rollout() {
  local resource="$1"
  echo "waiting for ${resource}"
  kubectl -n "${namespace}" rollout status "${resource}" --timeout="${wait_timeout}"
}

wait_job() {
  local job_name="$1"
  echo "waiting for job/${job_name}"
  if ! kubectl -n "${namespace}" wait \
      --for=condition=complete "job/${job_name}" --timeout="${wait_timeout}"; then
    kubectl -n "${namespace}" describe "job/${job_name}" >&2 || true
    kubectl -n "${namespace}" logs "job/${job_name}" --all-containers=true >&2 || true
    die "job did not complete: ${job_name}"
  fi
}

stage="${1:?usage: deploy-nereus-stage.sh A|B|C|D|E [--resume]}"
mode="${2:-}"
case "${stage}" in
  A|B|C|D|E) ;;
  *) die "invalid stage: ${stage}" ;;
esac
case "${mode}" in
  ""|--resume) ;;
  *) die "invalid mode: ${mode}; expected --resume or no second argument" ;;
esac
resume=false
if [[ "${mode}" == "--resume" ]]; then
  resume=true
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
chart="${repo_root}/charts/pulsar"
common="${repo_root}/examples/nereus-benchmark/values-common.yaml"
case "${stage}" in
  A)
    overlay="${repo_root}/examples/nereus-benchmark/values-stage-a-apache.yaml"
    storage_class="bookkeeper"
    ;;
  B)
    overlay="${repo_root}/examples/nereus-benchmark/values-stage-b-dormant.yaml"
    storage_class="bookkeeper"
    ;;
  C)
    overlay="${repo_root}/examples/nereus-benchmark/values-stage-c-bk-only.yaml"
    storage_class="nereus"
    ;;
  D)
    overlay="${repo_root}/examples/nereus-benchmark/values-stage-d-bk-async-object.yaml"
    storage_class="nereus"
    ;;
  E)
    overlay="${repo_root}/examples/nereus-benchmark/values-stage-e-bk-sync-object.yaml"
    storage_class="nereus"
    ;;
esac

release="${NEREUS_RELEASE:-nereus}"
namespace="${NEREUS_NAMESPACE:-pulsar}"
cluster="${NEREUS_CLUSTER:-beijing-1}"
wait_timeout="${NEREUS_WAIT_TIMEOUT:-20m}"
results_root="${NEREUS_RESULTS_ROOT:-${repo_root}/results}"
oxia_storage_class="local-zk"
oxia_server_replicas=3
secret_name="${NEREUS_SECRET_NAME:-pulsar-nereus-secrets}"
access_key_key="${NEREUS_ACCESS_KEY_KEY:-access-key}"
secret_key_key="${NEREUS_SECRET_KEY_KEY:-secret-key}"
bookkeeper_password_key="${NEREUS_BOOKKEEPER_PASSWORD_KEY:-bookkeeper-password}"
access_key_reference="${NEREUS_ACCESS_KEY_REFERENCE:-NEREUS_S3_ACCESS_KEY}"
secret_key_reference="${NEREUS_SECRET_KEY_REFERENCE:-NEREUS_S3_SECRET_KEY}"
bookkeeper_password_reference="${NEREUS_BOOKKEEPER_PASSWORD_REFERENCE:-NEREUS_BK_PASSWORD}"
session_token_key="${NEREUS_SESSION_TOKEN_KEY:-}"
session_token_reference="${NEREUS_SESSION_TOKEN_REFERENCE:-}"
containerd_namespace="${NEREUS_CONTAINERD_NAMESPACE:-k8s.io}"
containerd_address="${NEREUS_CONTAINERD_ADDRESS:-}"
nerdctl_bin="${NEREUS_NERDCTL_BIN:-nerdctl}"
expected_context="${NEREUS_EXPECTED_CONTEXT:-}"
[[ -n "${expected_context}" ]] \
  || die "NEREUS_EXPECTED_CONTEXT must name the exact Kubernetes context"
campaign_values="${NEREUS_CAMPAIGN_VALUES:-}"
if [[ -n "${campaign_values}" ]]; then
  [[ -f "${campaign_values}" && -r "${campaign_values}" ]] \
    || die "NEREUS_CAMPAIGN_VALUES is not a readable file: ${campaign_values}"
  campaign_values="$(
    cd "$(dirname "${campaign_values}")"
    printf '%s/%s\n' "$(pwd)" "$(basename "${campaign_values}")"
  )"
else
  die "NEREUS_CAMPAIGN_VALUES is required for stages A-E"
fi
operator_evidence_file="${NEREUS_OPERATOR_EVIDENCE_FILE:-}"
if [[ -n "${campaign_values}" && -z "${operator_evidence_file}" ]]; then
  case "${campaign_values}" in
    *.yaml)
      candidate_operator_evidence="${campaign_values%.yaml}.operator-evidence.txt"
      ;;
    *)
      candidate_operator_evidence="${campaign_values}.operator-evidence.txt"
      ;;
  esac
  if [[ -f "${candidate_operator_evidence}" ]]; then
    operator_evidence_file="${candidate_operator_evidence}"
  fi
fi
if [[ -n "${operator_evidence_file}" ]]; then
  [[ -f "${operator_evidence_file}" && -r "${operator_evidence_file}" ]] \
    || die "NEREUS_OPERATOR_EVIDENCE_FILE is not readable: ${operator_evidence_file}"
  operator_evidence_file="$(
    cd "$(dirname "${operator_evidence_file}")"
    printf '%s/%s\n' "$(pwd)" "$(basename "${operator_evidence_file}")"
  )"
else
  die "operator evidence is required for stages A-E; use prepare-nereus-campaign-values.sh"
fi
if [[ "${resume}" == true && -n "${NEREUS_RESUME_RUN_STAMP:-}" ]]; then
  run_stamp="${NEREUS_RESUME_RUN_STAMP}"
else
  run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
fi
[[ "${run_stamp}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] \
  || die "run stamp must use UTC format YYYYMMDDTHHMMSSZ: ${run_stamp}"
stage_lower="$(printf '%s' "${stage}" | tr '[:upper:]' '[:lower:]')"
tenant="${NEREUS_BENCHMARK_TENANT:-nereus-perf}"
benchmark_namespace="${NEREUS_BENCHMARK_NAMESPACE:-stage-${stage_lower}-${run_stamp}}"
topic="persistent://${tenant}/${benchmark_namespace}/smoke"
run_dir="${results_root}/deploy/${stage}/${run_stamp}"
preflight_dir="${results_root}/preflight/${stage}/${run_stamp}"
manifest="${preflight_dir}/manifest.yaml"

for command_name in helm kubectl jq awk grep sed "${nerdctl_bin}"; do
  require_command "${command_name}"
done

current_context="$(kubectl config current-context)"
[[ "${current_context}" == "${expected_context}" ]] \
  || die "Kubernetes context mismatch: expected ${expected_context}, got ${current_context}"
mkdir -p "${run_dir}" "${preflight_dir}"
printf '%s\n' "${current_context}" > "${run_dir}/kube-context.txt"

helm_values_args=(
  -f "${common}"
  -f "${overlay}"
)
campaign_values_sha256=""
if [[ -n "${campaign_values}" ]]; then
  helm_values_args+=(-f "${campaign_values}")
  campaign_values_sha256="$(sha256_file "${campaign_values}")"
fi
operator_evidence_sha256=""
provider_scope_sha256=""
reservation_id=""
apache_image_id=""
nereus_image_id=""
nereus_admin_image_id=""
apache_image_config_id=""
nereus_image_config_id=""
nereus_admin_image_config_id=""
if [[ -n "${operator_evidence_file}" ]]; then
  operator_evidence_sha256="$(sha256_file "${operator_evidence_file}")"
fi
if [[ -n "${operator_evidence_file}" ]]; then
  apache_image="$(evidence_value "${operator_evidence_file}" apacheImage)"
  nereus_image="$(evidence_value "${operator_evidence_file}" nereusImage)"
  nereus_admin_image="$(evidence_value "${operator_evidence_file}" nereusAdminImage)"
  apache_source_sha="$(evidence_value "${operator_evidence_file}" apacheSourceSha)"
  nereus_pulsar_source_sha="$(evidence_value "${operator_evidence_file}" nereusPulsarSourceSha)"
  nereus_source_sha="$(evidence_value "${operator_evidence_file}" nereusSourceSha)"
  [[ "$(evidence_value "${operator_evidence_file}" schema)" \
      == "NEREUS_BENCHMARK_CAMPAIGN_V1" ]] \
    || die "unsupported operator evidence schema: ${operator_evidence_file}"
  [[ "$(evidence_value "${operator_evidence_file}" kubernetesContext)" \
      == "${current_context}" ]] \
    || die "operator evidence Kubernetes context does not match ${current_context}"
  [[ "$(evidence_value "${operator_evidence_file}" kubernetesNamespace)" \
      == "${namespace}" ]] \
    || die "operator evidence namespace does not match ${namespace}"
  [[ "$(evidence_value "${operator_evidence_file}" helmRelease)" == "${release}" ]] \
    || die "operator evidence Helm release does not match ${release}"
  [[ "$(evidence_value "${operator_evidence_file}" pulsarCluster)" == "${cluster}" ]] \
    || die "operator evidence Pulsar cluster does not match ${cluster}"
  [[ "$(evidence_value "${operator_evidence_file}" apacheImage)" == "${apache_image}" ]] \
    || die "operator evidence does not identify the frozen Apache image"
  [[ "$(evidence_value "${operator_evidence_file}" nereusImage)" == "${nereus_image}" ]] \
    || die "operator evidence does not identify the frozen Nereus image"
  [[ "$(evidence_value "${operator_evidence_file}" nereusAdminImage)" \
      == "${nereus_admin_image}" ]] \
    || die "operator evidence does not identify the frozen Nereus admin image"
  provider_scope_sha256="$(
    evidence_value "${operator_evidence_file}" bookKeeperProviderScopeSha256
  )"
  reservation_id="$(
    evidence_value "${operator_evidence_file}" ledgerIdNamespaceReservationId
  )"
  apache_image_id="$(evidence_value "${operator_evidence_file}" apacheImageId)"
  nereus_image_id="$(evidence_value "${operator_evidence_file}" nereusImageId)"
  nereus_admin_image_id="$(
    evidence_value "${operator_evidence_file}" nereusAdminImageId
  )"
  [[ "${provider_scope_sha256}" =~ ^[0-9a-f]{64}$ ]] \
    || die "operator evidence has an invalid BookKeeper provider-scope SHA-256"
  [[ "${reservation_id}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || die "operator evidence has an invalid reservation UUID"
  for image_id in \
    "${apache_image_id}" "${nereus_image_id}" "${nereus_admin_image_id}"; do
    [[ "${image_id}" =~ ^sha256:[0-9a-f]{64}$ ]] \
      || die "operator evidence has an invalid image ID: ${image_id:-<empty>}"
  done
fi

for image in "${apache_image}" "${nereus_image}" "${nereus_admin_image}"; do
  [[ "${image}" == *:* && "${image}" != *@* ]] \
    || die "operator evidence has an invalid image reference: ${image:-<empty>}"
done
for source_sha in \
  "${apache_source_sha}" "${nereus_pulsar_source_sha}" "${nereus_source_sha}"; do
  [[ "${source_sha}" =~ ^[0-9a-f]{40}$ ]] \
    || die "operator evidence has an invalid source Git SHA: ${source_sha:-<empty>}"
done

apache_image_repository="${apache_image%:*}"
apache_image_tag="${apache_image##*:}"
nereus_image_repository="${nereus_image%:*}"
nereus_image_tag="${nereus_image##*:}"
nereus_admin_image_repository="${nereus_admin_image%:*}"
nereus_admin_image_tag="${nereus_admin_image##*:}"

apache_image_config_id="$(
  resolve_runtime_config_id \
    "${apache_image}" "${apache_image_id}" "Apache Pulsar"
)"
if [[ "${stage}" != "A" ]]; then
  nereus_image_config_id="$(
    resolve_runtime_config_id \
      "${nereus_image}" "${nereus_image_id}" "Nereus Pulsar"
  )"
  nereus_admin_image_config_id="$(
    resolve_runtime_config_id \
      "${nereus_admin_image}" "${nereus_admin_image_id}" "Nereus admin"
  )"
fi
jq -n \
  --arg apacheImage "${apache_image}" \
  --arg apacheTargetDigest "${apache_image_id}" \
  --arg apacheConfigId "${apache_image_config_id}" \
  --arg nereusImage "${nereus_image}" \
  --arg nereusTargetDigest "${nereus_image_id}" \
  --arg nereusConfigId "${nereus_image_config_id}" \
  --arg nereusAdminImage "${nereus_admin_image}" \
  --arg nereusAdminTargetDigest "${nereus_admin_image_id}" \
  --arg nereusAdminConfigId "${nereus_admin_image_config_id}" '
    {
      apache: {
        image: $apacheImage,
        targetDigest: $apacheTargetDigest,
        runtimeConfigId: $apacheConfigId
      },
      nereus: {
        image: $nereusImage,
        targetDigest: $nereusTargetDigest,
        runtimeConfigId: $nereusConfigId
      },
      nereusAdmin: {
        image: $nereusAdminImage,
        targetDigest: $nereusAdminTargetDigest,
        runtimeConfigId: $nereusAdminConfigId
      }
    }
  ' > "${run_dir}/image-identity-map.json"

helm_overrides=(
  --set-string "namespace=${namespace}"
  --set-string "fullnameOverride=${release}"
  --set-string "clusterName=${cluster}"
  --set-string "nereus.secrets.existingSecret=${secret_name}"
  --set-string "nereus.secrets.accessKeyKey=${access_key_key}"
  --set-string "nereus.secrets.secretKeyKey=${secret_key_key}"
  --set-string "nereus.secrets.bookKeeperPasswordKey=${bookkeeper_password_key}"
  --set-string "nereus.secrets.accessKeyReference=${access_key_reference}"
  --set-string "nereus.secrets.secretKeyReference=${secret_key_reference}"
  --set-string "nereus.secrets.bookKeeperPasswordReference=${bookkeeper_password_reference}"
  --set-string "nereus.secrets.sessionTokenKey=${session_token_key}"
  --set-string "nereus.secrets.sessionTokenReference=${session_token_reference}"
  --set-string "defaultPulsarImageRepository=${apache_image_repository}"
  --set-string "defaultPulsarImageTag=${apache_image_tag}"
  --set-string "defaultPullPolicy=Never"
  --set-string "images.bookie.repository=${apache_image_repository}"
  --set-string "images.bookie.tag=${apache_image_tag}"
  --set-string "images.bookie.pullPolicy=Never"
  --set-string "images.autorecovery.repository=${apache_image_repository}"
  --set-string "images.autorecovery.tag=${apache_image_tag}"
  --set-string "images.autorecovery.pullPolicy=Never"
  --set-string "images.toolset.repository=${apache_image_repository}"
  --set-string "images.toolset.tag=${apache_image_tag}"
  --set-string "images.toolset.pullPolicy=Never"
  --set-string "nereus.admin.image.repository=${nereus_admin_image_repository}"
  --set-string "nereus.admin.image.tag=${nereus_admin_image_tag}"
  --set-string "nereus.admin.image.pullPolicy=Never"
)
if [[ "${stage}" == "A" ]]; then
  helm_overrides+=(
    --set-string "images.broker.repository=${apache_image_repository}"
    --set-string "images.broker.tag=${apache_image_tag}"
    --set-string "images.broker.pullPolicy=Never"
  )
else
  helm_overrides+=(
    --set-string "images.broker.repository=${nereus_image_repository}"
    --set-string "images.broker.tag=${nereus_image_tag}"
    --set-string "images.broker.pullPolicy=Never"
  )
fi

# The VictoriaMetrics dependency installs its admission webhook in the same
# Helm transaction as the VMAgent/VMRule/VMSingle resources that call it. A
# cold install can therefore race the operator startup and fail with a
# connection-refused webhook error. Bootstrap only the operator and the core
# Pulsar resources first; after its deployment is Ready, upgrade to the full
# monitoring values below.
monitoring_bootstrap_overrides=(
  --set "victoria-metrics-k8s-stack.defaultRules.create=false"
  --set "victoria-metrics-k8s-stack.defaultDashboards.enabled=false"
  --set "victoria-metrics-k8s-stack.vmsingle.enabled=false"
  --set "victoria-metrics-k8s-stack.vmagent.enabled=false"
  --set "victoria-metrics-k8s-stack.vmalert.enabled=false"
  --set "victoria-metrics-k8s-stack.alertmanager.enabled=false"
  --set "victoria-metrics-k8s-stack.vmcluster.enabled=false"
  --set "victoria-metrics-k8s-stack.vmauth.enabled=false"
  --set "victoria-metrics-k8s-stack.grafana.enabled=false"
  --set "victoria-metrics-k8s-stack.prometheus-node-exporter.enabled=false"
  --set "victoria-metrics-k8s-stack.kube-state-metrics.enabled=false"
  --set "victoria-metrics-k8s-stack.kubelet.enabled=false"
  --set "victoria-metrics-k8s-stack.kubeApiServer.enabled=false"
  --set "victoria-metrics-k8s-stack.kubeControllerManager.enabled=false"
  --set "victoria-metrics-k8s-stack.coreDns.enabled=false"
  --set "victoria-metrics-k8s-stack.kubeEtcd.enabled=false"
  --set "victoria-metrics-k8s-stack.kubeScheduler.enabled=false"
  --set "victoria-metrics-k8s-stack.victoria-metrics-operator.serviceMonitor.enabled=false"
  --set "oxia.coordinator.podMonitor.enabled=false"
  --set "oxia.server.podMonitor.enabled=false"
  --set "bookkeeper.podMonitor.enabled=false"
  --set "autorecovery.podMonitor.enabled=false"
  --set "broker.podMonitor.enabled=false"
  --set "proxy.podMonitor.enabled=false"
  --set "zookeeper.podMonitor.enabled=false"
  --set "function_worker.podMonitor.enabled=false"
  --set "nereus.objectStore.seaweedfs.podMonitor.enabled=false"
)

echo "linting stage ${stage}"
helm lint "${chart}" \
  "${helm_values_args[@]}" \
  "${helm_overrides[@]}"

echo "rendering stage ${stage}"
helm template "${release}" "${chart}" \
  --namespace "${namespace}" \
  "${helm_values_args[@]}" \
  "${helm_overrides[@]}" \
  > "${manifest}"

if grep -Eq \
    '(<FINAL_|n00000000|p00000000|00000000-0000-0000-0000-000000000000|0000000000000000000000000000000000000000000000000000000000000000)' \
    "${manifest}"; then
  die "rendered manifest contains an unresolved image or identity placeholder: ${manifest}"
fi
if grep -Eq \
    'bookkeeper\.(maxBytesPerLedger|maxReadBytesInFlight)=[^[:space:]]*[eE][+-]?[0-9]+|nereusBookKeeper(MaxBytesPerLedger|MaxReadBytesInFlight):[[:space:]]*"?[0-9.]+[eE][+-]?[0-9]+"?' \
    "${manifest}"; then
  die "rendered Nereus admin or broker properties contain scientific notation for a Java long: ${manifest}"
fi
if [[ "${stage}" != "A" ]] \
    && ! grep -F \
      'PULSAR_PREFIX_nereusBookKeeperPrimaryWalEnabled: "true"' \
      "${manifest}" >/dev/null; then
  die "rendered broker ConfigMap does not expose the Nereus BookKeeper runtime flag: ${manifest}"
fi
grep -F \
  "metadataStoreUrl: \"oxia://${release}-oxia-svc:6648/broker\"" \
  "${manifest}" >/dev/null \
  || die "rendered Pulsar metadata path is not Oxia"
grep -F \
  "bookkeeperMetadataServiceUri: \"metadata-store:oxia://${release}-oxia-svc:6648/bookkeeper\"" \
  "${manifest}" >/dev/null \
  || die "rendered BookKeeper metadata path is not Oxia"
oxia_image_occurrences="$(
  grep -Fc 'image: "oxia/oxia:0.16.7"' "${manifest}" || true
)"
[[ "${oxia_image_occurrences}" == "2" ]] \
  || die "rendered Oxia workloads do not use the frozen oxia/oxia:0.16.7 image"
if grep -Eq \
    "^[[:space:]]*(name: ${release}-zookeeper|component: zookeeper|metadataStoreUrl: \"zk|bookkeeperMetadataServiceUri: \"zk)" \
    "${manifest}"; then
  die "rendered manifest contains a ZooKeeper resource or metadata URL"
fi
grep -F "storageClassName: ${oxia_storage_class}" "${manifest}" >/dev/null \
  || die "rendered Oxia PVC does not use ${oxia_storage_class}"
grep -F "storage: 47Gi" "${manifest}" >/dev/null \
  || die "rendered Oxia PVC does not request the frozen 47Gi size"
if [[ "${stage}" != "A" ]] \
    && ! grep -F \
      "operatorEvidenceSha256=${operator_evidence_sha256}" "${manifest}" >/dev/null; then
  die "rendered operatorEvidenceSha256 does not identify ${operator_evidence_file}"
fi
if [[ "${stage}" != "A" ]] \
    && ! grep -F \
      "bookkeeper.providerScopeSha256=${provider_scope_sha256}" \
      "${manifest}" >/dev/null; then
  die "rendered providerScopeSha256 does not match ${operator_evidence_file}"
fi
if [[ "${stage}" != "A" ]] \
    && ! grep -F \
      "bookkeeper.reservationId=${reservation_id}" "${manifest}" >/dev/null; then
  die "rendered reservationId does not match ${operator_evidence_file}"
fi

kubectl get namespace "${namespace}" >/dev/null 2>&1 \
  || die "target namespace ${namespace} must exist before deployment"
if [[ "${resume}" == true ]]; then
  helm -n "${namespace}" status "${release}" >/dev/null 2>&1 \
    || die "resume requires an existing Helm release: ${namespace}/${release}"
  broker_statefulset_json="$(kubectl -n "${namespace}" get \
    "statefulset/${release}-broker" -o json)"
  jq -e \
    --arg stage "${stage}" \
    --arg storageClass "${storage_class}" \
    '.spec.template.metadata.annotations["benchmark.nereusstream.com/stage"] == $stage
      and .spec.template.metadata.annotations["benchmark.nereusstream.com/managed-ledger-storage-class"] == $storageClass' \
    <<<"${broker_statefulset_json}" >/dev/null \
    || die "existing release does not match the requested resumed stage ${stage}/${storage_class}"
else
  if helm -n "${namespace}" status "${release}" >/dev/null 2>&1; then
    die "cold-start deployment requires no existing Helm release: ${namespace}/${release}; run reset-nereus-benchmark-stage.sh first"
  fi
fi
kubectl get nodes -l workload=pulsar -o json \
  > "${run_dir}/pulsar-nodes-before.json"
jq -e '
  [.items[]
    | select(.spec.unschedulable != true)
    | select(any(.status.conditions[]?;
        .type == "Ready" and .status == "True"))]
  | length == 1
' "${run_dir}/pulsar-nodes-before.json" >/dev/null \
  || die "benchmark requires exactly one schedulable Ready workload=pulsar node"
kubectl get nodes -l 'workload=apps,nereus-object-store=true' -o json \
  > "${run_dir}/object-store-nodes-before.json"
jq -e '
  [.items[]
    | select(.spec.unschedulable != true)
    | select(any(.status.conditions[]?;
        .type == "Ready" and .status == "True"))]
  | length == 1
' "${run_dir}/object-store-nodes-before.json" >/dev/null \
  || die "benchmark requires exactly one schedulable Ready workload=apps,nereus-object-store=true node"
pulsar_node="$(
  jq -r '
    .items[]
    | select(.spec.unschedulable != true)
    | select(any(.status.conditions[]?;
        .type == "Ready" and .status == "True"))
    | .metadata.name
  ' "${run_dir}/pulsar-nodes-before.json"
)"
object_store_node="$(
  jq -r '
    .items[]
    | select(.spec.unschedulable != true)
    | select(any(.status.conditions[]?;
        .type == "Ready" and .status == "True"))
    | .metadata.name
  ' "${run_dir}/object-store-nodes-before.json"
)"
[[ "${pulsar_node}" != "${object_store_node}" ]] \
  || die "Pulsar and object-store workloads must use different nodes"
kubectl get storageclass "${oxia_storage_class}" -o json \
  > "${run_dir}/oxia-storage-class.json" 2>/dev/null \
  || die "required Oxia StorageClass does not exist: ${oxia_storage_class}"
kubectl -n "${namespace}" get persistentvolumeclaims -o json \
  > "${run_dir}/oxia-pvcs-before.json"
if [[ "${resume}" != true ]]; then
  existing_release_data_pvcs="$(
    jq -r \
      --arg release "${release}" '
        def is_release_data_pvc($r):
          startswith($r + "-oxia-data-" + $r + "-oxia-server-")
          or startswith($r + "-bookie-journal-" + $r + "-bookie-")
          or startswith($r + "-bookie-ledgers-" + $r + "-bookie-")
          or startswith($r + "-bookie-index-" + $r + "-bookie-")
          or startswith("data-" + $r + "-seaweedfs-");
        [.items[]
          | .metadata.name
          | select(is_release_data_pvc($release))]
        | .[]
      ' "${run_dir}/oxia-pvcs-before.json"
  )"
  [[ -z "${existing_release_data_pvcs}" ]] \
    || die "cold-start deployment found residual data PVCs; run reset-nereus-benchmark-stage.sh first: ${existing_release_data_pvcs//$'\n'/,}"
fi
oxia_pvc_prefix="${release}-oxia-data-${release}-oxia-server-"
oxia_storage_provisioner="$(
  jq -r '.provisioner' "${run_dir}/oxia-storage-class.json"
)"
if [[ "${resume}" != true && "${oxia_storage_provisioner}" == "kubernetes.io/no-provisioner" ]]; then
  kubectl get persistentvolumes -o json \
    > "${run_dir}/persistent-volumes-before.json"
  available_oxia_pvs="$(
    jq \
      --arg storageClass "${oxia_storage_class}" \
      '[.items[]
        | select(.spec.storageClassName == $storageClass)
        | select(.status.phase == "Available")]
      | length' \
      "${run_dir}/persistent-volumes-before.json"
  )"
  required_oxia_pvs="${oxia_server_replicas}"
  (( available_oxia_pvs >= required_oxia_pvs )) \
    || die "StorageClass ${oxia_storage_class} needs ${required_oxia_pvs} additional Available PVs for Oxia; found ${available_oxia_pvs}"
fi
secret_json="$(kubectl -n "${namespace}" get secret "${secret_name}" -o json 2>/dev/null)" \
  || die "required Secret ${namespace}/${secret_name} does not exist"
required_secret_keys=(
  "${access_key_key}"
  "${secret_key_key}"
)
if [[ "${stage}" != "A" ]]; then
  required_secret_keys+=("${bookkeeper_password_key}")
fi
if [[ -n "${session_token_key}" ]]; then
  required_secret_keys+=("${session_token_key}")
fi
for secret_key in "${required_secret_keys[@]}"; do
  jq -e --arg key "${secret_key}" \
    '(.data[$key] // "") | length > 0' \
    <<<"${secret_json}" >/dev/null \
    || die "Secret ${namespace}/${secret_name} has no non-empty ${secret_key} value"
done

{
  printf '%s  %s\n' "$(sha256_file "${common}")" "${common}"
  printf '%s  %s\n' "$(sha256_file "${overlay}")" "${overlay}"
  if [[ -n "${campaign_values}" ]]; then
    printf '%s  %s\n' "${campaign_values_sha256}" "${campaign_values}"
  fi
  if [[ -n "${operator_evidence_file}" ]]; then
    printf '%s  %s\n' "${operator_evidence_sha256}" "${operator_evidence_file}"
  fi
  printf '%s  %s\n' "$(sha256_file "${manifest}")" "${manifest}"
} > "${preflight_dir}/sha256sums.txt"

if [[ "${resume}" == true ]]; then
  echo "resuming stage ${stage} without changing the existing Helm release"
  printf '%s\n' \
    'resume-existing-release=true' \
    'helm-install-upgrade=skipped' \
    > "${run_dir}/monitoring-bootstrap.txt"
else
  echo "deploying stage ${stage}"
  printf '%s\n' \
    'operator-bootstrap=VictoriaMetrics CR-producing resources disabled' \
    'operator-ready=required before full monitoring upgrade' \
    > "${run_dir}/monitoring-bootstrap.txt"
  helm install "${release}" "${chart}" \
    --namespace "${namespace}" \
    "${helm_values_args[@]}" \
    "${monitoring_bootstrap_overrides[@]}" \
    "${helm_overrides[@]}" \
    --timeout "${wait_timeout}"

  wait_rollout "deployment/${release}-victoria-metrics-operator"
  printf 'operator-ready-at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >> "${run_dir}/monitoring-bootstrap.txt"
  helm upgrade "${release}" "${chart}" \
    --namespace "${namespace}" \
    "${helm_values_args[@]}" \
    "${helm_overrides[@]}" \
    --timeout "${wait_timeout}"
  printf 'full-monitoring-upgrade-complete-at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >> "${run_dir}/monitoring-bootstrap.txt"
fi

wait_rollout "deployment/${release}-oxia-coordinator"
wait_rollout "statefulset/${release}-oxia-server"
kubectl -n "${namespace}" get persistentvolumeclaims -o json \
  > "${run_dir}/oxia-pvcs.json"
jq -e \
  --arg prefix "${oxia_pvc_prefix}" \
  --arg storageClass "${oxia_storage_class}" \
  --argjson replicas "${oxia_server_replicas}" '
    [.items[]
      | select(.metadata.name | startswith($prefix))]
    | (length == $replicas
      and all(.[];
        .spec.storageClassName == $storageClass
        and .spec.resources.requests.storage == "47Gi"
        and .status.phase == "Bound"))
  ' "${run_dir}/oxia-pvcs.json" >/dev/null \
  || die "Oxia PVCs do not match the frozen local-zk/47Gi/Bound topology"
wait_job "${release}-bookie-init"
wait_rollout "statefulset/${release}-bookie"
wait_job "${release}-pulsar-init"
wait_rollout "statefulset/${release}-recovery"
wait_rollout "statefulset/${release}-seaweedfs"

if [[ "${stage}" != "A" ]]; then
  bootstrap_job="$(kubectl -n "${namespace}" get jobs \
    -l "release=${release},component=nereus-bk-bootstrap" \
    --sort-by=.metadata.creationTimestamp \
    -o name \
    | sed -n "s#^job.batch/\\(${release}-nereus-bk-bootstrap-[a-f0-9]\\{8\\}\\)\$#\\1#p" \
    | tail -n 1)"
  [[ -n "${bootstrap_job}" ]] \
    || die "Nereus BookKeeper bootstrap Job was not rendered"
  wait_job "${bootstrap_job}"
  bootstrap_pod_json="$(kubectl -n "${namespace}" get pods \
    -l "job-name=${bootstrap_job}" -o json)"
  jq -er '
    [.items[]
      | .status.containerStatuses[]?
      | select(.name == "bootstrap")
      | .state.terminated.message]
    | map(select(. != null and . != ""))
    | last
  ' <<<"${bootstrap_pod_json}" \
    > "${run_dir}/bookkeeper-namespace-bootstrap.json" \
    || die "BookKeeper bootstrap Job has no termination evidence"
  jq -e \
    --arg cluster "${cluster}" \
    '.command == "bookkeeper namespace ensure"
      and .status == "ACTIVE"
      and .cluster == $cluster
      and .metadataVersion >= 0
      and (.providerScopeSha256 | test("^[0-9a-f]{64}$"))
      and (.ledgerIdNamespaceSha256 | test("^[0-9a-f]{64}$"))' \
    "${run_dir}/bookkeeper-namespace-bootstrap.json" >/dev/null \
    || die "BookKeeper bootstrap termination evidence is invalid"
fi

wait_rollout "statefulset/${release}-broker"
wait_rollout "statefulset/${release}-toolset"

toolset_pod="$(kubectl -n "${namespace}" get pods \
  -l "release=${release},component=toolset" \
  -o jsonpath='{.items[0].metadata.name}')"
[[ -n "${toolset_pod}" ]] || die "toolset Pod was not found"

pulsar_admin() {
  kubectl -n "${namespace}" exec "${toolset_pod}" -- bin/pulsar-admin "$@"
}

if ! pulsar_admin tenants get "${tenant}" > "${run_dir}/tenant-before.json" 2>/dev/null; then
  pulsar_admin tenants create "${tenant}" --allowed-clusters "${cluster}"
fi
pulsar_admin namespaces create "${tenant}/${benchmark_namespace}"
pulsar_admin namespaces set-persistence \
  --bookkeeper-ensemble 3 \
  --bookkeeper-write-quorum 3 \
  --bookkeeper-ack-quorum 2 \
  --ml-storage-class "${storage_class}" \
  "${tenant}/${benchmark_namespace}"
pulsar_admin namespaces get-persistence \
  "${tenant}/${benchmark_namespace}" \
  > "${run_dir}/namespace-persistence.json"

if [[ "${stage}" == "A" || "${stage}" == "B" ]]; then
  pulsar_admin topics create "${topic}"
  pulsar_admin topics stats "${topic}" > "${run_dir}/smoke-topic-stats.json"
fi

{
  printf 'STAGE=%q\n' "${stage}"
  printf 'RELEASE=%q\n' "${release}"
  printf 'KUBERNETES_NAMESPACE=%q\n' "${namespace}"
  printf 'KUBERNETES_CONTEXT=%q\n' "${current_context}"
  printf 'CLUSTER=%q\n' "${cluster}"
  printf 'BENCHMARK_TENANT=%q\n' "${tenant}"
  printf 'BENCHMARK_NAMESPACE=%q\n' "${benchmark_namespace}"
  printf 'BENCHMARK_TOPIC=%q\n' "${topic}"
  printf 'MANAGED_LEDGER_STORAGE_CLASS=%q\n' "${storage_class}"
  printf 'CAMPAIGN_VALUES=%q\n' "${campaign_values}"
  printf 'CAMPAIGN_VALUES_SHA256=%q\n' "${campaign_values_sha256}"
  printf 'OPERATOR_EVIDENCE_FILE=%q\n' "${operator_evidence_file}"
  printf 'OPERATOR_EVIDENCE_SHA256=%q\n' "${operator_evidence_sha256}"
  printf 'APACHE_IMAGE=%q\n' "${apache_image}"
  printf 'NEREUS_IMAGE=%q\n' "${nereus_image}"
  printf 'NEREUS_ADMIN_IMAGE=%q\n' "${nereus_admin_image}"
  printf 'APACHE_SOURCE_SHA=%q\n' "${apache_source_sha}"
  printf 'NEREUS_PULSAR_SOURCE_SHA=%q\n' "${nereus_pulsar_source_sha}"
  printf 'NEREUS_SOURCE_SHA=%q\n' "${nereus_source_sha}"
  printf 'OXIA_STORAGE_CLASS=%q\n' "${oxia_storage_class}"
  printf 'OXIA_STORAGE_PROVISIONER=%q\n' "${oxia_storage_provisioner}"
  printf 'OXIA_STORAGE_SIZE=%q\n' "47Gi"
  printf 'APACHE_IMAGE_TARGET_DIGEST=%q\n' "${apache_image_id}"
  printf 'APACHE_IMAGE_CONFIG_ID=%q\n' "${apache_image_config_id}"
  printf 'NEREUS_IMAGE_TARGET_DIGEST=%q\n' "${nereus_image_id}"
  printf 'NEREUS_IMAGE_CONFIG_ID=%q\n' "${nereus_image_config_id}"
  printf 'NEREUS_ADMIN_IMAGE_TARGET_DIGEST=%q\n' "${nereus_admin_image_id}"
  printf 'NEREUS_ADMIN_IMAGE_CONFIG_ID=%q\n' "${nereus_admin_image_config_id}"
  printf 'RUN_DIR=%q\n' "${run_dir}"
} > "${run_dir}/run.env"

helm -n "${namespace}" get values "${release}" --all \
  > "${run_dir}/helm-values.yaml"
kubectl -n "${namespace}" get pods \
  -l "release=${release}" -o wide > "${run_dir}/pods.txt"
kubectl -n "${namespace}" get pods \
  -l "release=${release}" -o json > "${run_dir}/pods.json"
kubectl -n "${namespace}" get pods \
  -l "release=${release}" \
  -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,IMAGE:.spec.containers[*].image,IMAGE_ID:.status.containerStatuses[*].imageID' \
  > "${run_dir}/images.txt"

capture_image_ids() {
  local image="$1"
  local evidence_name="$2"
  local evidence_file="${run_dir}/image-id-${evidence_name}.json"
  jq \
    --arg image "${image}" '
        [
          .items[] as $pod
          | ((($pod.spec.initContainers // [])
              + ($pod.spec.containers // []))[]) as $container
          | select($container.image == $image)
          | ((($pod.status.initContainerStatuses // [])
              + ($pod.status.containerStatuses // []))[]
              | select(.name == $container.name)) as $status
          | {
              pod: $pod.metadata.name,
              container: $container.name,
              imageID: ($status.imageID // "")
            }
        ]
      ' "${run_dir}/pods.json" > "${evidence_file}"
}

verify_image_id() {
  local image="$1"
  local expected_target_digest="$2"
  local expected_config_id="$3"
  local evidence_name="$4"
  local label="$5"
  local evidence_file="${run_dir}/image-id-${evidence_name}.json"
  capture_image_ids "${image}" "${evidence_name}"
  if ! jq -e \
      --arg expectedConfigId "${expected_config_id}" \
      '(length > 0
        and all(.[]; (.imageID | endswith($expectedConfigId))))' \
      "${evidence_file}" >/dev/null; then
    die "${label} Pods do not all use runtime config ID ${expected_config_id} mapped from frozen OCI target ${expected_target_digest}; failed run: ${run_dir}/run.env"
  fi
}

verify_consistent_image_id() {
  local image="$1"
  local evidence_name="$2"
  local label="$3"
  local minimum_containers="$4"
  local evidence_file="${run_dir}/image-id-${evidence_name}.json"
  capture_image_ids "${image}" "${evidence_name}"
  if ! jq -e \
      --argjson minimumContainers "${minimum_containers}" '
        (length >= $minimumContainers
          and ([.[].imageID] | unique | length) == 1
          and (.[0].imageID | test("sha256:[0-9a-f]{64}$")))
      ' "${evidence_file}" >/dev/null; then
    die "${label} containers do not all use one immutable image ID"
  fi
}

verify_image_id \
  "${apache_image}" "${apache_image_id}" "${apache_image_config_id}" \
  "apache-pulsar" "Apache Pulsar"
if [[ "${stage}" != "A" ]]; then
  verify_image_id \
    "${nereus_image}" "${nereus_image_id}" "${nereus_image_config_id}" \
    "nereus-pulsar" "Nereus Pulsar"
  verify_image_id \
    "${nereus_admin_image}" "${nereus_admin_image_id}" \
    "${nereus_admin_image_config_id}" "nereus-admin" "Nereus admin"
fi
verify_consistent_image_id "oxia/oxia:0.16.7" "oxia" "Oxia" 4

cp "${run_dir}/run.env" "${results_root}/deploy/latest.env"

echo "stage ${stage} infrastructure is ready"
echo "evidence: ${run_dir}"
if [[ "${stage}" != "A" ]]; then
  echo "next: ${script_dir}/activate-nereus-publications.sh ${stage}"
else
  echo "next: ${script_dir}/verify-nereus-release.sh ${stage}"
fi
