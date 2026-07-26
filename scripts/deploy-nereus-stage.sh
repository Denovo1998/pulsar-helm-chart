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

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
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

stage="${1:?usage: deploy-nereus-stage.sh A|B|C|D|E}"
case "${stage}" in
  A|B|C|D|E) ;;
  *) die "invalid stage: ${stage}" ;;
esac

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

release="${NEREUS_RELEASE:-pulsar}"
namespace="${NEREUS_NAMESPACE:-pulsar}"
cluster="${NEREUS_CLUSTER:-beijing-1}"
wait_timeout="${NEREUS_WAIT_TIMEOUT:-20m}"
results_root="${NEREUS_RESULTS_ROOT:-${repo_root}/results}"
secret_name="${NEREUS_SECRET_NAME:-pulsar-nereus-secrets}"
access_key_key="${NEREUS_ACCESS_KEY_KEY:-access-key}"
secret_key_key="${NEREUS_SECRET_KEY_KEY:-secret-key}"
bookkeeper_password_key="${NEREUS_BOOKKEEPER_PASSWORD_KEY:-bookkeeper-password}"
access_key_reference="${NEREUS_ACCESS_KEY_REFERENCE:-NEREUS_S3_ACCESS_KEY}"
secret_key_reference="${NEREUS_SECRET_KEY_REFERENCE:-NEREUS_S3_SECRET_KEY}"
bookkeeper_password_reference="${NEREUS_BOOKKEEPER_PASSWORD_REFERENCE:-NEREUS_BK_PASSWORD}"
session_token_key="${NEREUS_SESSION_TOKEN_KEY:-}"
session_token_reference="${NEREUS_SESSION_TOKEN_REFERENCE:-}"
expected_context="${NEREUS_EXPECTED_CONTEXT:-}"
[[ -n "${expected_context}" ]] \
  || die "NEREUS_EXPECTED_CONTEXT must name the exact Kubernetes context"
run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
stage_lower="$(printf '%s' "${stage}" | tr '[:upper:]' '[:lower:]')"
tenant="${NEREUS_BENCHMARK_TENANT:-nereus-perf}"
benchmark_namespace="${NEREUS_BENCHMARK_NAMESPACE:-stage-${stage_lower}-${run_stamp}}"
topic="persistent://${tenant}/${benchmark_namespace}/smoke"
run_dir="${results_root}/deploy/${stage}/${run_stamp}"
preflight_dir="${results_root}/preflight/${stage}/${run_stamp}"
manifest="${preflight_dir}/manifest.yaml"

for command_name in helm kubectl jq awk grep sed; do
  require_command "${command_name}"
done

current_context="$(kubectl config current-context)"
[[ "${current_context}" == "${expected_context}" ]] \
  || die "Kubernetes context mismatch: expected ${expected_context}, got ${current_context}"
mkdir -p "${run_dir}" "${preflight_dir}"
printf '%s\n' "${current_context}" > "${run_dir}/kube-context.txt"

helm_overrides=(
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
)

echo "linting stage ${stage}"
helm lint "${chart}" \
  -f "${common}" \
  -f "${overlay}" \
  "${helm_overrides[@]}"

echo "rendering stage ${stage}"
helm template "${release}" "${chart}" \
  --namespace "${namespace}" \
  -f "${common}" \
  -f "${overlay}" \
  "${helm_overrides[@]}" \
  > "${manifest}"

if grep -Eq \
    '(<FINAL_|n00000000|p00000000|00000000-0000-0000-0000-000000000000|0000000000000000000000000000000000000000000000000000000000000000)' \
    "${manifest}"; then
  die "rendered manifest contains an unresolved image or identity placeholder: ${manifest}"
fi

kubectl get namespace "${namespace}" >/dev/null 2>&1 \
  || die "target namespace ${namespace} must exist before deployment"
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
  printf '%s  %s\n' "$(sha256_file "${manifest}")" "${manifest}"
} > "${preflight_dir}/sha256sums.txt"

echo "deploying stage ${stage}"
helm upgrade --install "${release}" "${chart}" \
  --namespace "${namespace}" \
  -f "${common}" \
  -f "${overlay}" \
  "${helm_overrides[@]}" \
  --timeout "${wait_timeout}" \
  --history-max 20

wait_rollout "deployment/${release}-oxia-coordinator"
wait_rollout "statefulset/${release}-oxia-server"
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

helm -n "${namespace}" get values "${release}" --all \
  > "${run_dir}/helm-values.yaml"
kubectl -n "${namespace}" get pods -o wide > "${run_dir}/pods.txt"
kubectl -n "${namespace}" get pods \
  -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,IMAGE:.spec.containers[*].image,IMAGE_ID:.status.containerStatuses[*].imageID' \
  > "${run_dir}/images.txt"

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
  printf 'RUN_DIR=%q\n' "${run_dir}"
} > "${run_dir}/run.env"
cp "${run_dir}/run.env" "${results_root}/deploy/latest.env"

echo "stage ${stage} infrastructure is ready"
echo "evidence: ${run_dir}"
if [[ "${stage}" != "A" ]]; then
  echo "next: ${script_dir}/activate-nereus-publications.sh ${stage}"
else
  echo "next: ${script_dir}/verify-nereus-release.sh ${stage}"
fi
