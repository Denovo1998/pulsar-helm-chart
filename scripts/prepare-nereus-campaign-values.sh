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

readonly APACHE_PULSAR_SHA="8dae0236c0a0d405ed7f8303081080520fe91551"
readonly NEREUS_PULSAR_SHA="0718b565f82e71a3ace2e28a3962c8c1385908c7"

usage() {
  cat <<'EOF'
Create one non-secret, immutable identity/evidence layer for stages A-E.

Usage:
  prepare-nereus-campaign-values.sh OUTPUT.yaml IMAGE_MANIFEST.env

Required environment:
  NEREUS_EXPECTED_CONTEXT   Exact kubectl context for the campaign.

Optional environment:
  NEREUS_RELEASE            Helm release (default: nereus).
  NEREUS_NAMESPACE          Kubernetes namespace (default: pulsar).
  NEREUS_CLUSTER            Pulsar cluster name (default: beijing-1).
  NEREUS_CLUSTER_DOMAIN     Kubernetes DNS domain (default: cluster.local).
  NEREUS_BOOKKEEPER_PROVIDER_SCOPE_ID
                            Canonical non-secret BookKeeper metadata-service
                            and ledger-root identity. By default it is derived
                            from the rendered Oxia BookKeeper URI and expanded
                            to an in-cluster FQDN.

The script verifies the checksummed image manifest and its three frozen image
identities, derives the provider-scope SHA-256, creates a new reservation UUID,
and writes an operator-evidence file beside OUTPUT.yaml. Stage A uses it to
verify the Apache image ID; stages B-E additionally bind the BookKeeper
identity. The script never reads or writes credentials and refuses to
overwrite either artifact.
EOF
}

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

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  fi
}

manifest_value() {
  local manifest="$1"
  local key="$2"
  sed -n "s/^${key}=//p" "${manifest}" | tail -n 1
}

verify_manifest_value() {
  local manifest="$1"
  local key="$2"
  local expected="$3"
  local actual
  actual="$(manifest_value "${manifest}" "${key}")"
  [[ "${actual}" == "${expected}" ]] \
    || die "${key} mismatch in ${manifest}: expected ${expected}, got ${actual:-<empty>}"
}

if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  usage
  exit 0
fi

[[ $# -eq 2 ]] || {
  usage >&2
  exit 1
}

output_values="$1"
image_manifest="$2"
expected_context="${NEREUS_EXPECTED_CONTEXT:-}"
release="${NEREUS_RELEASE:-nereus}"
namespace="${NEREUS_NAMESPACE:-pulsar}"
cluster="${NEREUS_CLUSTER:-beijing-1}"
cluster_domain="${NEREUS_CLUSTER_DOMAIN:-cluster.local}"
provider_scope_id="${NEREUS_BOOKKEEPER_PROVIDER_SCOPE_ID:-}"

[[ -n "${expected_context}" ]] \
  || die "NEREUS_EXPECTED_CONTEXT must name the exact Kubernetes context"
[[ -n "${release}" && -n "${namespace}" && -n "${cluster}" ]] \
  || die "release, namespace, and cluster must be non-empty"
[[ -n "${cluster_domain}" ]] || die "NEREUS_CLUSTER_DOMAIN must be non-empty"
[[ -f "${image_manifest}" && -r "${image_manifest}" ]] \
  || die "image manifest is not a readable file: ${image_manifest}"
[[ -f "${image_manifest}.sha256" ]] \
  || die "image manifest checksum is missing: ${image_manifest}.sha256"

for command_name in \
  helm kubectl awk sed grep tr tail date mkdir mktemp mv rm wc dirname basename; do
  require_command "${command_name}"
done
if ! command -v sha256sum >/dev/null 2>&1; then
  require_command shasum
fi

image_manifest="$(
  cd "$(dirname "${image_manifest}")"
  printf '%s/%s\n' "$(pwd)" "$(basename "${image_manifest}")"
)"
output_parent="$(dirname "${output_values}")"
mkdir -p "${output_parent}"
output_parent="$(cd "${output_parent}" && pwd)"
output_values="${output_parent}/$(basename "${output_values}")"
case "${output_values}" in
  *.yaml) operator_evidence="${output_values%.yaml}.operator-evidence.txt" ;;
  *) operator_evidence="${output_values}.operator-evidence.txt" ;;
esac
[[ ! -e "${output_values}" ]] \
  || die "refusing to overwrite campaign values: ${output_values}"
[[ ! -e "${operator_evidence}" ]] \
  || die "refusing to overwrite operator evidence: ${operator_evidence}"

expected_manifest_sha256="$(awk 'NR == 1 {print $1}' "${image_manifest}.sha256")"
actual_manifest_sha256="$(sha256_file "${image_manifest}")"
[[ "${actual_manifest_sha256}" == "${expected_manifest_sha256}" ]] \
  || die "image manifest checksum mismatch: expected ${expected_manifest_sha256}, got ${actual_manifest_sha256}"

verify_manifest_value "${image_manifest}" TARGET_PLATFORM linux/amd64
verify_manifest_value "${image_manifest}" APACHE_PULSAR_SHA "${APACHE_PULSAR_SHA}"
verify_manifest_value "${image_manifest}" NEREUS_PULSAR_SHA "${NEREUS_PULSAR_SHA}"
nereus_sha="$(manifest_value "${image_manifest}" NEREUS_SHA)"
apache_image="$(manifest_value "${image_manifest}" APACHE_IMAGE)"
nereus_image="$(manifest_value "${image_manifest}" NEREUS_IMAGE)"
nereus_admin_image="$(manifest_value "${image_manifest}" NEREUS_ADMIN_IMAGE)"
[[ "${nereus_sha}" =~ ^[0-9a-f]{40}$ ]] \
  || die "NEREUS_SHA is not a full Git SHA in ${image_manifest}"
[[ "${apache_image}" =~ ^nereus-benchmark/pulsar:[^:]+$ ]] \
  || die "APACHE_IMAGE is not a supported benchmark image reference: ${apache_image:-<empty>}"
[[ "${nereus_image}" =~ ^nereus-benchmark/pulsar:[^:]+$ ]] \
  || die "NEREUS_IMAGE is not a supported benchmark image reference: ${nereus_image:-<empty>}"
[[ "${nereus_admin_image}" =~ ^nereus-benchmark/nereus-admin:[^:]+$ ]] \
  || die "NEREUS_ADMIN_IMAGE is not a supported benchmark image reference: ${nereus_admin_image:-<empty>}"
expected_apache_image="nereus-benchmark/pulsar:5.0.0-m1-apache-p${APACHE_PULSAR_SHA:0:8}-amd64"
expected_nereus_image="nereus-benchmark/pulsar:5.0.0-m1-nereus-p${NEREUS_PULSAR_SHA:0:8}-n${nereus_sha:0:8}-amd64"
expected_nereus_admin_image="nereus-benchmark/nereus-admin:v0.1.0-n${nereus_sha:0:8}-amd64"
[[ "${apache_image}" == "${expected_apache_image}" ]] \
  || die "APACHE_IMAGE does not match the frozen source-qualified tag: expected ${expected_apache_image}, got ${apache_image}"
[[ "${nereus_image}" == "${expected_nereus_image}" ]] \
  || die "NEREUS_IMAGE does not match the manifest source SHAs: expected ${expected_nereus_image}, got ${nereus_image}"
[[ "${nereus_admin_image}" == "${expected_nereus_admin_image}" ]] \
  || die "NEREUS_ADMIN_IMAGE does not match NEREUS_SHA: expected ${expected_nereus_admin_image}, got ${nereus_admin_image}"
for image_id_key in APACHE_IMAGE_ID NEREUS_IMAGE_ID NEREUS_ADMIN_IMAGE_ID; do
  image_id="$(manifest_value "${image_manifest}" "${image_id_key}")"
  [[ "${image_id}" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || die "${image_id_key} is not a full sha256 image ID in ${image_manifest}"
done

current_context="$(kubectl config current-context)"
[[ "${current_context}" == "${expected_context}" ]] \
  || die "Kubernetes context mismatch: expected ${expected_context}, got ${current_context}"

if [[ -z "${provider_scope_id}" ]]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/.." && pwd)"
  rendered_stage_a="$(
    helm template "${release}" "${repo_root}/charts/pulsar" \
      --namespace "${namespace}" \
      -f "${repo_root}/examples/nereus-benchmark/values-common.yaml" \
      -f "${repo_root}/examples/nereus-benchmark/values-stage-a-apache.yaml" \
      --set-string "namespace=${namespace}" \
      --set-string "fullnameOverride=${release}" \
      --set-string "clusterName=${cluster}"
  )"
  metadata_service_uri="$(
    sed -n \
      's/^[[:space:]]*bookkeeperMetadataServiceUri: "\(.*\)"$/\1/p' \
      <<<"${rendered_stage_a}" \
      | awk '!seen[$0]++'
  )"
  [[ -n "${metadata_service_uri}" \
      && "$(printf '%s\n' "${metadata_service_uri}" | wc -l | tr -d '[:space:]')" == "1" ]] \
    || die "could not derive one BookKeeper metadata-service URI from the rendered Chart"
  [[ "${metadata_service_uri}" == metadata-store:oxia://* ]] \
    || die "benchmark BookKeeper metadata path must use Oxia: ${metadata_service_uri}"
  [[ "${metadata_service_uri}" == *"://"*/* ]] \
    || die "rendered BookKeeper metadata-service URI is not canonical: ${metadata_service_uri}"
  uri_scheme="${metadata_service_uri%%://*}"
  uri_remainder="${metadata_service_uri#*://}"
  uri_authority="${uri_remainder%%/*}"
  uri_root="/${uri_remainder#*/}"
  [[ "${uri_authority}" == *:* ]] \
    || die "rendered BookKeeper metadata-service URI has no port: ${metadata_service_uri}"
  uri_host="${uri_authority%:*}"
  uri_port="${uri_authority##*:}"
  if [[ "${uri_host}" == *.* ]]; then
    provider_host="${uri_host}"
  else
    provider_host="${uri_host}.${namespace}.svc.${cluster_domain}"
  fi
  provider_scope_id="${uri_scheme}://${provider_host}:${uri_port}${uri_root}"
fi
[[ "${provider_scope_id}" != *$'\n'* ]] \
  || die "BookKeeper provider scope identity must be one line"
provider_scope_sha256="$(sha256_text "${provider_scope_id}")"

if [[ -r /proc/sys/kernel/random/uuid ]]; then
  reservation_id="$(tr '[:upper:]' '[:lower:]' < /proc/sys/kernel/random/uuid)"
else
  require_command uuidgen
  reservation_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
fi
[[ "${reservation_id}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  || die "generated reservation identity is not a canonical UUID: ${reservation_id}"

temporary_dir="$(mktemp -d "${output_parent}/.nereus-campaign.XXXXXX")"
trap 'rm -rf -- "${temporary_dir}"' EXIT
temporary_evidence="${temporary_dir}/operator-evidence.txt"
temporary_values="${temporary_dir}/values.yaml"
{
  printf 'schema=NEREUS_BENCHMARK_CAMPAIGN_V1\n'
  printf 'createdAtUtc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'kubernetesContext=%s\n' "${current_context}"
  printf 'kubernetesNamespace=%s\n' "${namespace}"
  printf 'helmRelease=%s\n' "${release}"
  printf 'pulsarCluster=%s\n' "${cluster}"
  printf 'bookKeeperProviderScopeId=%s\n' "${provider_scope_id}"
  printf 'bookKeeperProviderScopeSha256=%s\n' "${provider_scope_sha256}"
  printf 'ledgerIdNamespaceReservationId=%s\n' "${reservation_id}"
  printf 'imageManifest=%s\n' "${image_manifest}"
  printf 'imageManifestSha256=%s\n' "${actual_manifest_sha256}"
  printf 'apacheSourceSha=%s\n' "${APACHE_PULSAR_SHA}"
  printf 'nereusPulsarSourceSha=%s\n' "${NEREUS_PULSAR_SHA}"
  printf 'nereusSourceSha=%s\n' "${nereus_sha}"
  printf 'apacheImage=%s\n' "${apache_image}"
  printf 'apacheImageId=%s\n' "$(manifest_value "${image_manifest}" APACHE_IMAGE_ID)"
  printf 'nereusImage=%s\n' "${nereus_image}"
  printf 'nereusImageId=%s\n' "$(manifest_value "${image_manifest}" NEREUS_IMAGE_ID)"
  printf 'nereusAdminImage=%s\n' "${nereus_admin_image}"
  printf 'nereusAdminImageId=%s\n' "$(manifest_value "${image_manifest}" NEREUS_ADMIN_IMAGE_ID)"
} > "${temporary_evidence}"
operator_evidence_sha256="$(sha256_file "${temporary_evidence}")"

{
  printf '# Generated by prepare-nereus-campaign-values.sh; contains no secrets.\n'
  printf '# Keep this file and its operator-evidence file together for stages A-E.\n\n'
  printf 'nereus:\n'
  printf '  bookkeeperWal:\n'
  printf '    providerScopeSha256: "%s"\n' "${provider_scope_sha256}"
  printf '    ledgerIdNamespaceReservationId: "%s"\n' "${reservation_id}"
  printf '  admin:\n'
  printf '    operatorEvidenceSha256: "%s"\n' "${operator_evidence_sha256}"
} > "${temporary_values}"

mv "${temporary_evidence}" "${operator_evidence}"
mv "${temporary_values}" "${output_values}"

echo "created campaign values: ${output_values}"
echo "created operator evidence: ${operator_evidence}"
echo "provider scope: ${provider_scope_id}"
echo "provider scope sha256: ${provider_scope_sha256}"
echo "operator evidence sha256: ${operator_evidence_sha256}"
printf 'export NEREUS_CAMPAIGN_VALUES=%q\n' "${output_values}"
