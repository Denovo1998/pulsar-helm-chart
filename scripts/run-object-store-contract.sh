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
[[ "${STAGE}" != "A" ]] \
  || die "stage A does not render the Nereus admin image; run this gate in B-E"
release="${NEREUS_RELEASE:-${RELEASE}}"
namespace="${NEREUS_NAMESPACE:-${KUBERNETES_NAMESPACE}}"
[[ "${release}" == "${RELEASE}" ]] \
  || die "release override does not match deployment run: ${release}"
[[ "${namespace}" == "${KUBERNETES_NAMESPACE}" ]] \
  || die "namespace override does not match deployment run: ${namespace}"
wait_timeout="${NEREUS_WAIT_TIMEOUT:-20m}"
admin_timeout_seconds="${NEREUS_ADMIN_TIMEOUT_SECONDS:-600}"
[[ "${admin_timeout_seconds}" =~ ^[1-9][0-9]*$
    && "${admin_timeout_seconds}" -le 86400 ]] \
  || die "NEREUS_ADMIN_TIMEOUT_SECONDS must be between 1 and 86400"
job_deadline_seconds=$((admin_timeout_seconds + 120))
evidence_dir="${RUN_DIR}/object-store-contract"
mkdir -p "${evidence_dir}"

for command_name in helm kubectl jq od tr sed; do
  require_command "${command_name}"
done
recorded_context="${KUBERNETES_CONTEXT:-}"
[[ -n "${recorded_context}" ]] \
  || die "deployment run does not record KUBERNETES_CONTEXT"
current_context="$(kubectl config current-context)"
[[ "${current_context}" == "${recorded_context}" ]] \
  || die "Kubernetes context mismatch: expected ${recorded_context}, got ${current_context}"

values_json="$(helm -n "${namespace}" get values "${release}" --all -o json)"
admin_repository="$(jq -er '.nereus.admin.image.repository' <<<"${values_json}")"
admin_tag="$(jq -er '.nereus.admin.image.tag' <<<"${values_json}")"
admin_pull_policy="$(jq -er '.nereus.admin.image.pullPolicy' <<<"${values_json}")"
secret_name="$(jq -er '.nereus.secrets.existingSecret' <<<"${values_json}")"
access_key_key="$(jq -er '.nereus.secrets.accessKeyKey' <<<"${values_json}")"
secret_key_key="$(jq -er '.nereus.secrets.secretKeyKey' <<<"${values_json}")"
session_token_key="$(jq -r '.nereus.secrets.sessionTokenKey // ""' <<<"${values_json}")"
access_key_ref="$(jq -er '.nereus.secrets.accessKeyReference' <<<"${values_json}")"
secret_key_ref="$(jq -er '.nereus.secrets.secretKeyReference' <<<"${values_json}")"
session_token_ref="$(jq -r '.nereus.secrets.sessionTokenReference // ""' <<<"${values_json}")"
admin_image="${admin_repository}:${admin_tag}"

[[ "${admin_tag}" != *"n00000000"* ]] \
  || die "admin image tag is still a placeholder: ${admin_tag}"
[[ "${access_key_ref}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
  || die "access-key environment reference is invalid: ${access_key_ref}"
[[ "${secret_key_ref}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
  || die "secret-key environment reference is invalid: ${secret_key_ref}"
if [[ -n "${session_token_key}" || -n "${session_token_ref}" ]]; then
  [[ -n "${session_token_key}" && -n "${session_token_ref}" ]] \
    || die "session token key and reference must be configured together"
  [[ "${session_token_ref}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || die "session-token environment reference is invalid: ${session_token_ref}"
fi

run_id="$(od -An -N20 -tx1 /dev/urandom \
  | tr -d ' \n' \
  | tr '0123456789' 'abcdefghij')"
job_suffix="${run_id:0:12}"

run_admin_job() {
  local job_name="$1"
  local evidence_file="$2"
  shift 2
  local -a admin_args=("$@")
  admin_args+=(--output /dev/termination-log)
  local args_yaml=""
  local argument
  local job_pod_json
  for argument in "${admin_args[@]}"; do
    args_yaml+="            - $(printf '%s' "${argument}" | sed 's/\"/\\\"/g')"$'\n'
  done

  {
    cat <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: nereus-object-store-gate
    app.kubernetes.io/instance: ${release}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: ${job_deadline_seconds}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: nereus-object-store-gate
        app.kubernetes.io/instance: ${release}
    spec:
      restartPolicy: Never
      nodeSelector:
        workload: pulsar
      tolerations:
        - key: dedicated
          operator: Equal
          value: pulsar
          effect: NoSchedule
      containers:
        - name: nereus-admin
          image: "${admin_image}"
          imagePullPolicy: ${admin_pull_policy}
          command:
            - /opt/nereus-admin/bin/nereus-admin
          args:
${args_yaml}          env:
            - name: ${access_key_ref}
              valueFrom:
                secretKeyRef:
                  name: "${secret_name}"
                  key: "${access_key_key}"
            - name: ${secret_key_ref}
              valueFrom:
                secretKeyRef:
                  name: "${secret_name}"
                  key: "${secret_key_key}"
EOF
    if [[ -n "${session_token_key}" ]]; then
      cat <<EOF
            - name: ${session_token_ref}
              valueFrom:
                secretKeyRef:
                  name: "${secret_name}"
                  key: "${session_token_key}"
EOF
    fi
    cat <<EOF
          volumeMounts:
            - name: config
              mountPath: /etc/nereus-admin
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: ${release}-nereus-admin
EOF
  } | kubectl apply -f -

  if ! kubectl -n "${namespace}" wait \
      --for=condition=complete "job/${job_name}" --timeout="${wait_timeout}"; then
    kubectl -n "${namespace}" describe "job/${job_name}" >&2 || true
    kubectl -n "${namespace}" logs "job/${job_name}" --all-containers=true >&2 || true
    die "object-store gate failed: ${job_name}"
  fi
  job_pod_json="$(kubectl -n "${namespace}" get pods \
    -l "job-name=${job_name}" -o json)"
  jq -er '
    [.items[]
      | .status.containerStatuses[]?
      | select(.name == "nereus-admin")
      | .state.terminated.message]
    | map(select(. != null and . != ""))
    | last
  ' <<<"${job_pod_json}" > "${evidence_file}" \
    || die "object-store gate has no termination evidence: ${job_name}"
  jq -e '.overallSuccess == true' "${evidence_file}" >/dev/null \
    || die "admin evidence did not report overallSuccess=true: ${evidence_file}"
  kubectl -n "${namespace}" delete "job/${job_name}" --wait=true >/dev/null
}

run_admin_job \
  "nereus-contract-${job_suffix}" \
  "${evidence_dir}/contract.json" \
  object-store contract \
  --config /etc/nereus-admin/admin.properties \
  --timeout-seconds "${admin_timeout_seconds}"

run_admin_job \
  "nereus-persist-create-${job_suffix}" \
  "${evidence_dir}/persistence-create.json" \
  object-store persistence create \
  --config /etc/nereus-admin/admin.properties \
  --timeout-seconds "${admin_timeout_seconds}" \
  --run-id "${run_id}"

kubectl -n "${namespace}" rollout restart \
  "statefulset/${release}-seaweedfs" \
  > "${evidence_dir}/seaweedfs-rollout.txt"
kubectl -n "${namespace}" rollout status \
  "statefulset/${release}-seaweedfs" \
  --timeout="${wait_timeout}" \
  >> "${evidence_dir}/seaweedfs-rollout.txt"

run_admin_job \
  "nereus-persist-verify-${job_suffix}" \
  "${evidence_dir}/persistence-verify.json" \
  object-store persistence verify \
  --config /etc/nereus-admin/admin.properties \
  --timeout-seconds "${admin_timeout_seconds}" \
  --run-id "${run_id}"

run_admin_job \
  "nereus-persist-clean-${job_suffix}" \
  "${evidence_dir}/persistence-cleanup.json" \
  object-store persistence cleanup \
  --config /etc/nereus-admin/admin.properties \
  --timeout-seconds "${admin_timeout_seconds}" \
  --run-id "${run_id}"

echo "object-store contract and restart-persistence gate passed"
echo "evidence: ${evidence_dir}"
