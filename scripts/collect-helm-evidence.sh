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

record_git_identity() {
  local label="$1"
  local path="$2"
  if [[ -d "${path}/.git" || -f "${path}/.git" ]]; then
    {
      printf 'label=%s\n' "${label}"
      printf 'path=%s\n' "${path}"
      printf 'branch=%s\n' "$(git -C "${path}" branch --show-current)"
      printf 'head=%s\n' "$(git -C "${path}" rev-parse HEAD)"
      printf 'status_begin\n'
      git -C "${path}" status --short
      printf 'status_end\n'
    } > "${evidence_dir}/source-${label}.txt"
  fi
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
results_root="${NEREUS_RESULTS_ROOT:-${repo_root}/results}"
run_env="${NEREUS_RUN_ENV:-${results_root}/deploy/latest.env}"
[[ -r "${run_env}" ]] || die "deployment run file is not readable: ${run_env}"

# shellcheck disable=SC1090
source "${run_env}"
release="${NEREUS_RELEASE:-${RELEASE}}"
namespace="${NEREUS_NAMESPACE:-${KUBERNETES_NAMESPACE}}"
[[ "${release}" == "${RELEASE}" ]] \
  || die "release override does not match deployment run: ${release}"
[[ "${namespace}" == "${KUBERNETES_NAMESPACE}" ]] \
  || die "namespace override does not match deployment run: ${namespace}"
evidence_dir="${RUN_DIR}/final-evidence"
archive="${RUN_DIR}/nereus-stage-${STAGE}-evidence.tar.gz"
mkdir -p "${evidence_dir}"

for command_name in git helm kubectl tar awk; do
  require_command "${command_name}"
done
recorded_context="${KUBERNETES_CONTEXT:-}"
[[ -n "${recorded_context}" ]] \
  || die "deployment run does not record KUBERNETES_CONTEXT"
current_context="$(kubectl config current-context)"
[[ "${current_context}" == "${recorded_context}" ]] \
  || die "Kubernetes context mismatch: expected ${recorded_context}, got ${current_context}"

helm -n "${namespace}" status "${release}" \
  > "${evidence_dir}/helm-status.txt"
helm -n "${namespace}" get values "${release}" --all \
  > "${evidence_dir}/helm-values.yaml"
helm -n "${namespace}" get manifest "${release}" \
  > "${evidence_dir}/helm-manifest.yaml"
helm -n "${namespace}" history "${release}" \
  > "${evidence_dir}/helm-history.txt"

kubectl config current-context > "${evidence_dir}/kube-context.txt"
kubectl get nodes -o wide > "${evidence_dir}/nodes.txt"
kubectl get nodes -o json > "${evidence_dir}/nodes.json"
kubectl -n "${namespace}" get pods -o wide > "${evidence_dir}/pods.txt"
kubectl -n "${namespace}" get pods -o json > "${evidence_dir}/pods.json"
kubectl -n "${namespace}" get pvc -o wide > "${evidence_dir}/pvcs.txt"
kubectl get pv -o wide > "${evidence_dir}/pvs.txt"
kubectl -n "${namespace}" get statefulset,deployment,job,service,configmap \
  -o yaml > "${evidence_dir}/workloads.yaml"
kubectl -n "${namespace}" get events \
  --sort-by=.metadata.creationTimestamp > "${evidence_dir}/events.txt"
kubectl -n "${namespace}" get pods \
  -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,IMAGE:.spec.containers[*].image,IMAGE_ID:.status.containerStatuses[*].imageID,INIT_IMAGE:.spec.initContainers[*].image,INIT_IMAGE_ID:.status.initContainerStatuses[*].imageID' \
  > "${evidence_dir}/images-and-ids.txt"

record_git_identity "helm" "${NEREUS_HELM_SOURCE_REPO:-${repo_root}}"
if [[ -n "${NEREUS_SOURCE_REPO:-}" ]]; then
  record_git_identity "nereus" "${NEREUS_SOURCE_REPO}"
fi
if [[ -n "${NEREUS_PULSAR_SOURCE_REPO:-}" ]]; then
  record_git_identity "pulsar" "${NEREUS_PULSAR_SOURCE_REPO}"
fi

{
  find "${RUN_DIR}" -type f \
      ! -path "${evidence_dir}/sha256sums.txt" \
      ! -path "${archive}" \
      ! -path "${archive}.sha256" \
      -print0 \
    | sort -z \
    | while IFS= read -r -d '' file; do
        printf '%s  %s\n' "$(sha256_file "${file}")" \
          "${file#${RUN_DIR}/}"
      done
} > "${evidence_dir}/sha256sums.txt"

tar -C "${RUN_DIR}" \
  --exclude="$(basename "${archive}")" \
  --exclude="$(basename "${archive}").sha256" \
  -czf "${archive}" .
printf '%s  %s\n' "$(sha256_file "${archive}")" "${archive}" \
  > "${archive}.sha256"

echo "evidence archive: ${archive}"
echo "archive SHA-256: $(sha256_file "${archive}")"
