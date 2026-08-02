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

readonly EXPECTED_DATA_PVC_COUNT=16

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 \
    || die "required command is unavailable: $1"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

is_release_data_pvc() {
  local pvc="$1"
  [[ "${pvc}" =~ -[0-9]+$ ]] || return 1
  case "${pvc}" in
    "${release}-oxia-data-${release}-oxia-server-"* | \
    "${release}-bookie-journal-${release}-bookie-"* | \
    "${release}-bookie-ledgers-${release}-bookie-"* | \
    "${release}-bookie-index-${release}-bookie-"* | \
    "data-${release}-seaweedfs-"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

release_exists() {
  helm -n "${namespace}" status "${release}" >/dev/null 2>&1
}

wait_for_pv_phase() {
  local pv="$1"
  local expected_phase="$2"
  local deadline=$((SECONDS + reset_timeout_seconds))
  local phase=""
  while (( SECONDS < deadline )); do
    phase="$(kubectl get "persistentvolume/${pv}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [[ "${phase}" == "${expected_phase}" ]]; then
      return 0
    fi
    sleep 2
  done
  die "persistentvolume/${pv} did not reach ${expected_phase}; last phase=${phase:-missing}"
}

stage="${1:?usage: reset-nereus-benchmark-stage.sh A|B|C|D|E [--execute]}"
mode="${2:-}"
case "${stage}" in
  A|B|C|D|E) ;;
  *) die "invalid stage: ${stage}" ;;
esac
case "${mode}" in
  ""|--execute) ;;
  *) die "invalid mode: ${mode}; expected --execute or no second argument" ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
results_root="${NEREUS_RESULTS_ROOT:-${repo_root}/results}"
run_env="${NEREUS_RUN_ENV:-${results_root}/deploy/latest.env}"
[[ -r "${run_env}" ]] || die "deployment run file is not readable: ${run_env}"

# shellcheck disable=SC1090
source "${run_env}"
[[ "${stage}" == "${STAGE}" ]] \
  || die "requested stage ${stage} does not match deployed stage ${STAGE}"
release="${NEREUS_RELEASE:-${RELEASE}}"
namespace="${NEREUS_NAMESPACE:-${KUBERNETES_NAMESPACE}}"
[[ "${release}" == "${RELEASE}" ]] \
  || die "release override does not match deployment run: ${release}"
[[ "${namespace}" == "${KUBERNETES_NAMESPACE}" ]] \
  || die "namespace override does not match deployment run: ${namespace}"
wipe_image="${APACHE_IMAGE:-}"
[[ -n "${wipe_image}" ]] \
  || die "deployment run does not record APACHE_IMAGE for the cold-wipe helper"

wait_timeout="${NEREUS_RESET_TIMEOUT:-20m}"
reset_timeout_seconds="${NEREUS_RESET_TIMEOUT_SECONDS:-1200}"
[[ "${reset_timeout_seconds}" =~ ^[1-9][0-9]*$ ]] \
  || die "NEREUS_RESET_TIMEOUT_SECONDS must be a positive integer"
expected_confirmation="${namespace}/${release}/${stage}"
reset_dir="${RUN_DIR}/cold-reset"
map_file="${reset_dir}/pvc-pv-map.tsv"
pods_file="${reset_dir}/pods-before-uninstall.json"
completion_file="${reset_dir}/completed.txt"
mkdir -p "${reset_dir}"

for command_name in helm kubectl jq awk sed sort; do
  require_command "${command_name}"
done

recorded_context="${KUBERNETES_CONTEXT:-}"
[[ -n "${recorded_context}" ]] \
  || die "deployment run does not record KUBERNETES_CONTEXT"
current_context="$(kubectl config current-context)"
[[ "${current_context}" == "${recorded_context}" ]] \
  || die "Kubernetes context mismatch: expected ${recorded_context}, got ${current_context}"

if release_exists; then
  kubectl -n "${namespace}" get pods \
    -l "release=${release}" -o json > "${pods_file}"
  data_pvcs=()
  while IFS= read -r pvc; do
    data_pvcs+=("${pvc}")
  done < <(
    jq -r '
      .items[]
      | .spec.volumes[]?
      | .persistentVolumeClaim.claimName? // empty
    ' "${pods_file}" | sort -u
  )
  [[ "${#data_pvcs[@]}" -eq "${EXPECTED_DATA_PVC_COUNT}" ]] \
    || die "expected ${EXPECTED_DATA_PVC_COUNT} mounted data PVCs, found ${#data_pvcs[@]}"

  printf 'pvc\tpv\tstorageClass\treclaimPolicy\tvolumeSource\n' > "${map_file}"
  for pvc in "${data_pvcs[@]}"; do
    is_release_data_pvc "${pvc}" \
      || die "refusing unexpected PVC mounted by the release: ${pvc}"
    pvc_json="$(kubectl -n "${namespace}" get "persistentvolumeclaim/${pvc}" -o json)"
    pv="$(jq -er '.spec.volumeName | select(length > 0)' <<<"${pvc_json}")" \
      || die "PVC ${pvc} is not bound to a PV"
    storage_class="$(jq -r '.spec.storageClassName // ""' <<<"${pvc_json}")"
    pv_json="$(kubectl get "persistentvolume/${pv}" -o json)"
    reclaim_policy="$(jq -er '.spec.persistentVolumeReclaimPolicy' <<<"${pv_json}")"
    volume_source="$(jq -c '
      if .spec.local then {type: "local", path: .spec.local.path}
      elif .spec.hostPath then {type: "hostPath", path: .spec.hostPath.path}
      elif .spec.csi then {type: "csi", driver: .spec.csi.driver}
      else {type: "other"}
      end
    ' <<<"${pv_json}")"
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "${pvc}" "${pv}" "${storage_class}" "${reclaim_policy}" "${volume_source}" \
      >> "${map_file}"
  done
elif [[ ! -r "${map_file}" ]]; then
  die "Helm release ${namespace}/${release} does not exist and no resumable reset map was found"
fi

echo "cold-reset target: ${expected_confirmation}"
column -t -s $'\t' "${map_file}" 2>/dev/null || sed -n '1,200p' "${map_file}"

if [[ "${mode}" != "--execute" ]]; then
  echo
  echo "PLAN ONLY: no Kubernetes resource or data was changed."
  echo "After collecting stage evidence, execute:"
  echo "NEREUS_COLD_RESET_CONFIRM='${expected_confirmation}' \\"
  echo "  ${script_dir}/reset-nereus-benchmark-stage.sh ${stage} --execute"
  exit 0
fi

[[ "${NEREUS_COLD_RESET_CONFIRM:-}" == "${expected_confirmation}" ]] \
  || die "set NEREUS_COLD_RESET_CONFIRM=${expected_confirmation} to authorize this exact reset"

evidence_archive="${RUN_DIR}/nereus-stage-${stage}-evidence.tar.gz"
evidence_sidecar="${evidence_archive}.sha256"
[[ -r "${evidence_archive}" && -r "${evidence_sidecar}" ]] \
  || die "collect-helm-evidence.sh must succeed before cold reset"
expected_evidence_sha="$(awk 'NR == 1 {print $1}' "${evidence_sidecar}")"
[[ "${expected_evidence_sha}" =~ ^[0-9a-f]{64}$ ]] \
  || die "invalid evidence archive checksum sidecar: ${evidence_sidecar}"
[[ "$(sha256_file "${evidence_archive}")" == "${expected_evidence_sha}" ]] \
  || die "evidence archive checksum does not match: ${evidence_archive}"

if release_exists; then
  echo "uninstalling ${namespace}/${release}"
  helm uninstall "${release}" \
    --namespace "${namespace}" \
    --wait \
    --timeout "${wait_timeout}"
fi
kubectl -n "${namespace}" wait \
  --for=delete pod \
  -l "release=${release}" \
  --timeout="${wait_timeout}" >/dev/null 2>&1 || true

index=0
while IFS=$'\t' read -r pvc pv storage_class reclaim_policy volume_source; do
  [[ "${pvc}" != "pvc" ]] || continue
  is_release_data_pvc "${pvc}" \
    || die "refusing unexpected PVC in reset map: ${pvc}"
  if ! kubectl -n "${namespace}" get "persistentvolumeclaim/${pvc}" \
      >/dev/null 2>&1; then
    echo "PVC already absent, skipping wipe: ${pvc}"
    continue
  fi

  index=$((index + 1))
  cleaner_prefix="${release:0:40}-cold-wipe"
  cleaner_name="$(printf '%s-%02d' "${cleaner_prefix}" "${index}")"
  kubectl -n "${namespace}" delete "pod/${cleaner_name}" \
    --ignore-not-found --wait=true >/dev/null

  echo "wiping ${pvc} through pod/${cleaner_name}"
  kubectl -n "${namespace}" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${cleaner_name}
  labels:
    app.kubernetes.io/managed-by: nereus-cold-reset
    benchmark.nereusstream.com/release: ${release}
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  containers:
    - name: wipe
      image: ${wipe_image}
      imagePullPolicy: Never
      securityContext:
        runAsUser: 0
        runAsGroup: 0
        allowPrivilegeEscalation: false
      command:
        - /bin/bash
        - -ec
      args:
        - |
          find /wipe-target -mindepth 1 -maxdepth 1 -exec rm -rf -- '{}' '+'
          test -z "\$(find /wipe-target -mindepth 1 -maxdepth 1 -print -quit)"
      volumeMounts:
        - name: target
          mountPath: /wipe-target
  volumes:
    - name: target
      persistentVolumeClaim:
        claimName: ${pvc}
EOF

  if ! kubectl -n "${namespace}" wait \
      --for=jsonpath='{.status.phase}'=Succeeded \
      "pod/${cleaner_name}" --timeout="${wait_timeout}"; then
    kubectl -n "${namespace}" describe "pod/${cleaner_name}" >&2 || true
    kubectl -n "${namespace}" logs "pod/${cleaner_name}" >&2 || true
    die "data wipe failed for PVC ${pvc}; the PVC was not deleted"
  fi
  kubectl -n "${namespace}" logs "pod/${cleaner_name}" \
    > "${reset_dir}/wipe-${index}-${pvc}.log"
  kubectl -n "${namespace}" delete "pod/${cleaner_name}" \
    --wait=true --timeout="${wait_timeout}" >/dev/null
done < "${map_file}"

mapped_pvcs=()
while IFS= read -r pvc; do
  mapped_pvcs+=("${pvc}")
done < <(awk -F $'\t' 'NR > 1 {print $1}' "${map_file}")
for pvc in "${mapped_pvcs[@]}"; do
  kubectl -n "${namespace}" delete "persistentvolumeclaim/${pvc}" \
    --ignore-not-found --wait=false
done
for pvc in "${mapped_pvcs[@]}"; do
  kubectl -n "${namespace}" wait \
    --for=delete "persistentvolumeclaim/${pvc}" \
    --timeout="${wait_timeout}" >/dev/null 2>&1 \
    || die "PVC did not delete: ${pvc}"
done

while IFS=$'\t' read -r pvc pv storage_class reclaim_policy volume_source; do
  [[ "${pvc}" != "pvc" ]] || continue
  case "${reclaim_policy}" in
    Retain)
      if ! kubectl get "persistentvolume/${pv}" >/dev/null 2>&1; then
        die "Retain PV unexpectedly disappeared: ${pv}"
      fi
      if [[ -n "$(kubectl get "persistentvolume/${pv}" \
          -o jsonpath='{.spec.claimRef}' 2>/dev/null)" ]]; then
        kubectl patch "persistentvolume/${pv}" --type=json \
          -p='[{"op":"remove","path":"/spec/claimRef"}]' >/dev/null
      fi
      wait_for_pv_phase "${pv}" "Available"
      ;;
    Delete)
      kubectl wait --for=delete "persistentvolume/${pv}" \
        --timeout="${wait_timeout}" >/dev/null 2>&1 \
        || die "Delete-policy PV did not disappear: ${pv}"
      ;;
    Recycle)
      wait_for_pv_phase "${pv}" "Available"
      ;;
    *)
      die "unsupported PV reclaim policy ${reclaim_policy} for ${pv}"
      ;;
  esac
done < "${map_file}"

release_exists \
  && die "Helm release still exists after reset: ${namespace}/${release}"
for pvc in "${mapped_pvcs[@]}"; do
  if kubectl -n "${namespace}" get "persistentvolumeclaim/${pvc}" \
      >/dev/null 2>&1; then
    die "PVC still exists after reset: ${pvc}"
  fi
done

{
  printf 'schema=NEREUS_BENCHMARK_COLD_RESET_V1\n'
  printf 'completedAt=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'kubernetesContext=%s\n' "${current_context}"
  printf 'kubernetesNamespace=%s\n' "${namespace}"
  printf 'helmRelease=%s\n' "${release}"
  printf 'stage=%s\n' "${stage}"
  printf 'wipedPvcCount=%s\n' "${#mapped_pvcs[@]}"
  printf 'evidenceArchiveSha256=%s\n' "${expected_evidence_sha}"
  printf 'pvcPvMapSha256=%s\n' "$(sha256_file "${map_file}")"
} > "${completion_file}"
printf '%s  %s\n' "$(sha256_file "${completion_file}")" "${completion_file}" \
  > "${completion_file}.sha256"

echo "cold reset completed: ${namespace}/${release}/${stage}"
echo "all mapped data PVCs were wiped and removed"
echo "Retain PVs were returned to Available; Delete PVs were removed"
echo "reset evidence: ${completion_file}"
