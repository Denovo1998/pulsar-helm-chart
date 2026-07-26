{{/*
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
*/}}

{{- define "pulsar.nereus.validate" -}}

{{- $reservedOxiaNamespaces := list "default" "broker" "bookkeeper" }}
{{- $seenOxiaNamespaces := dict }}
{{- range $index, $namespace := .Values.oxia.extraNamespaces }}
{{- $name := required (printf "oxia.extraNamespaces[%d].name is required" $index) $namespace.name }}
{{- if has $name $reservedOxiaNamespaces }}
{{- fail (printf "oxia.extraNamespaces cannot redefine reserved namespace %q" $name) }}
{{- end }}
{{- if hasKey $seenOxiaNamespaces $name }}
{{- fail (printf "oxia.extraNamespaces contains duplicate namespace %q" $name) }}
{{- end }}
{{- $_ := set $seenOxiaNamespaces $name true }}
{{- end }}

{{- if .Values.nereus.enabled }}

{{- if not .Values.components.oxia }}
{{- fail "Nereus requires components.oxia=true" }}
{{- end }}

{{- if not .Values.components.bookkeeper }}
{{- fail "Nereus requires components.bookkeeper=true" }}
{{- end }}

{{- if not .Values.components.broker }}
{{- fail "Nereus requires components.broker=true" }}
{{- end }}

{{- if not (hasKey $seenOxiaNamespaces .Values.nereus.oxia.namespace) }}
{{- fail (printf "oxia.extraNamespaces must contain the Nereus namespace %q" .Values.nereus.oxia.namespace) }}
{{- end }}

{{- $profiles := list "OBJECT_WAL_ASYNC_OBJECT" "OBJECT_WAL_SYNC_OBJECT" "BOOKKEEPER_WAL_ONLY" "BOOKKEEPER_WAL_ASYNC_OBJECT" "BOOKKEEPER_WAL_SYNC_OBJECT" }}
{{- if not (has .Values.nereus.defaultStorageProfile $profiles) }}
{{- fail "unsupported Nereus storage profile" }}
{{- end }}
{{- if and (hasPrefix "BOOKKEEPER_WAL_" .Values.nereus.defaultStorageProfile) (not .Values.nereus.bookkeeperWal.enabled) }}
{{- fail "BookKeeper WAL profiles require nereus.bookkeeperWal.enabled=true" }}
{{- end }}

{{- $_ := required "nereus.secrets.existingSecret is required" .Values.nereus.secrets.existingSecret }}
{{- $_ := required "nereus.secrets.accessKeyKey is required" .Values.nereus.secrets.accessKeyKey }}
{{- $_ := required "nereus.secrets.secretKeyKey is required" .Values.nereus.secrets.secretKeyKey }}
{{- $_ := required "nereus.secrets.accessKeyReference is required" .Values.nereus.secrets.accessKeyReference }}
{{- $_ := required "nereus.secrets.secretKeyReference is required" .Values.nereus.secrets.secretKeyReference }}
{{- $_ := required "nereus.secrets.bookKeeperPasswordReference is required" .Values.nereus.secrets.bookKeeperPasswordReference }}
{{- $_ := required "nereus.admin.image.tag is required" .Values.nereus.admin.image.tag }}

{{- $seenEnvironmentReferences := dict }}
{{- range $reference := list
    .Values.nereus.secrets.accessKeyReference
    .Values.nereus.secrets.secretKeyReference
    .Values.nereus.secrets.bookKeeperPasswordReference }}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]*$" $reference) }}
{{- fail (printf "Nereus secret environment reference %q is invalid" $reference) }}
{{- end }}
{{- if hasKey $seenEnvironmentReferences $reference }}
{{- fail (printf "Nereus secret environment reference %q is duplicated" $reference) }}
{{- end }}
{{- $_ := set $seenEnvironmentReferences $reference true }}
{{- end }}

{{- if eq .Values.nereus.secrets.resolverClassName "com.nereusstream.objectstore.NoopObjectStoreSecretResolver" }}
{{- fail "benchmark Nereus runtime cannot use NoopObjectStoreSecretResolver" }}
{{- end }}

{{- if or .Values.nereus.secrets.sessionTokenKey .Values.nereus.secrets.sessionTokenReference }}
{{- $_ := required "nereus.secrets.sessionTokenKey is required when sessionTokenReference is set" .Values.nereus.secrets.sessionTokenKey }}
{{- $_ := required "nereus.secrets.sessionTokenReference is required when sessionTokenKey is set" .Values.nereus.secrets.sessionTokenReference }}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]*$" .Values.nereus.secrets.sessionTokenReference) }}
{{- fail (printf "Nereus secret environment reference %q is invalid" .Values.nereus.secrets.sessionTokenReference) }}
{{- end }}
{{- if hasKey $seenEnvironmentReferences .Values.nereus.secrets.sessionTokenReference }}
{{- fail (printf "Nereus secret environment reference %q is duplicated" .Values.nereus.secrets.sessionTokenReference) }}
{{- end }}
{{- end }}

{{- $reservedBrokerKeys := list
    "managedLedgerStorageClassName"
    "nereusEnabled"
    "nereusRuntimeProviderClassName"
    "nereusOxiaServiceAddress"
    "nereusOxiaNamespace"
    "nereusObjectStoreProviderClassName"
    "nereusObjectStoreEndpoint"
    "nereusObjectStoreRegion"
    "nereusObjectStoreBucket"
    "nereusObjectStorePrefix"
    "nereusObjectStorePathStyleAccess"
    "nereusObjectStoreRequestTimeoutSeconds"
    "nereusObjectStoreMaxConnections"
    "nereusObjectStoreSecretResolverClassName"
    "nereusObjectStoreAccessKeySecretRef"
    "nereusObjectStoreSecretKeySecretRef"
    "nereusObjectStoreSessionTokenSecretRef"
    "nereusDefaultStorageProfile"
    "nereusGenerationProtocolEnabled"
    "nereusMaterializationStagingDirectory"
    "nereusPhysicalGcEnabled"
    "nereusPhysicalGcDryRun"
    "nereusBookKeeperPrimaryWalEnabled"
    "nereusBookKeeperDeploymentId"
    "nereusBookKeeperProviderScopeSha256"
    "nereusBookKeeperLedgerIdPrefixBits"
    "nereusBookKeeperLedgerIdPrefixValue"
    "nereusBookKeeperLedgerIdNamespaceReservationId"
    "nereusBookKeeperEnsembleSize"
    "nereusBookKeeperWriteQuorumSize"
    "nereusBookKeeperAckQuorumSize"
    "nereusBookKeeperDigestType"
    "nereusBookKeeperPasswordSecretRef"
    "nereusBookKeeperPasswordIdentityVersion"
    "nereusBookKeeperMaxEntriesPerLedger"
    "nereusBookKeeperMaxBytesPerLedger"
    "nereusBookKeeperMaxAppendRangesPerLedger"
    "nereusBookKeeperProtectionSlotsPerRange"
    "nereusBookKeeperMaxReaderLeasesPerLedger"
    "nereusBookKeeperMaxUncertainAllocations"
    "nereusBookKeeperMaxLedgerAgeSeconds"
    "nereusBookKeeperMaxWritesInFlight"
    "nereusBookKeeperMaxReadsInFlight"
    "nereusBookKeeperMaxReadBytesInFlight"
    "nereusBookKeeperOperationTimeoutSeconds"
    "nereusBookKeeperAllocationTimeoutSeconds"
    "nereusBookKeeperSealTimeoutSeconds"
    "nereusBookKeeperDeleteTimeoutSeconds"
    "nereusBookKeeperReaderLeaseSeconds"
    "nereusBookKeeperReaderLeaseRenewSeconds"
    "nereusBookKeeperRetentionScanIntervalSeconds"
    "nereusBookKeeperRetentionScanPageSize"
    "nereusBookKeeperMaxConcurrentDeletes"
    "nereusBookKeeperMaxClockSkewSeconds"
    "nereusBookKeeperGcDrainGraceSeconds"
    "nereusBookKeeperLateCreateAuditGraceSeconds"
    "nereusBookKeeperGcEnabled"
    "nereusBookKeeperGcDryRun" }}
{{- range $key := $reservedBrokerKeys }}
{{- if hasKey $.Values.broker.configData $key }}
{{- fail (printf "broker.configData cannot override Nereus-managed key %q" $key) }}
{{- end }}
{{- if hasKey $.Values.nereus.configData $key }}
{{- fail (printf "nereus.configData cannot override Nereus-managed key %q" $key) }}
{{- end }}
{{- end }}

{{- $stagingTypes := list "emptyDir" "existingClaim" "hostPath" }}
{{- if not (has .Values.nereus.staging.volume.type $stagingTypes) }}
{{- fail "nereus.staging.volume.type must be emptyDir, existingClaim, or hostPath" }}
{{- end }}
{{- if eq .Values.nereus.staging.volume.type "existingClaim" }}
{{- $_ := required "nereus.staging.volume.existingClaim is required" .Values.nereus.staging.volume.existingClaim }}
{{- end }}
{{- if eq .Values.nereus.staging.volume.type "hostPath" }}
{{- $_ := required "nereus.staging.volume.hostPath is required" .Values.nereus.staging.volume.hostPath }}
{{- end }}

{{- if .Values.nereus.bookkeeperWal.enabled }}

{{- $_ := required "bookkeeperWal.deploymentId is required" .Values.nereus.bookkeeperWal.deploymentId }}
{{- $_ := required "nereus.secrets.bookKeeperPasswordKey is required" .Values.nereus.secrets.bookKeeperPasswordKey }}

{{- $scope := required "bookkeeperWal.providerScopeSha256 is required" .Values.nereus.bookkeeperWal.providerScopeSha256 }}
{{- if not (regexMatch "^[0-9a-f]{64}$" $scope) }}
{{- fail "providerScopeSha256 must be 64 lowercase hex" }}
{{- end }}

{{- $_ := required "ledgerIdNamespaceReservationId is required" .Values.nereus.bookkeeperWal.ledgerIdNamespaceReservationId }}

{{- $operatorEvidence := required "nereus.admin.operatorEvidenceSha256 is required" .Values.nereus.admin.operatorEvidenceSha256 }}
{{- if not (regexMatch "^[0-9a-f]{64}$" $operatorEvidence) }}
{{- fail "operatorEvidenceSha256 must be 64 lowercase hex" }}
{{- end }}

{{- if lt (int .Values.nereus.bookkeeperWal.ensembleSize) (int .Values.nereus.bookkeeperWal.writeQuorumSize) }}
{{- fail "ensembleSize must be >= writeQuorumSize" }}
{{- end }}

{{- if lt (int .Values.nereus.bookkeeperWal.writeQuorumSize) (int .Values.nereus.bookkeeperWal.ackQuorumSize) }}
{{- fail "writeQuorumSize must be >= ackQuorumSize" }}
{{- end }}

{{- end }}

{{- if and (not .Values.nereus.objectStore.seaweedfs.enabled) (not .Values.nereus.objectStore.endpoint) }}
{{- fail "nereus.objectStore.endpoint is required when SeaweedFS is disabled" }}
{{- end }}

{{- end }}

{{- if .Values.nereus.objectStore.seaweedfs.enabled }}

{{- $_ := required "nereus.secrets.existingSecret is required for SeaweedFS" .Values.nereus.secrets.existingSecret }}
{{- $_ := required "nereus.secrets.accessKeyKey is required for SeaweedFS" .Values.nereus.secrets.accessKeyKey }}
{{- $_ := required "nereus.secrets.secretKeyKey is required for SeaweedFS" .Values.nereus.secrets.secretKeyKey }}

{{- if ne (int .Values.nereus.objectStore.seaweedfs.replicaCount) 1 }}
{{- fail "weed mini benchmark mode requires replicaCount=1" }}
{{- end }}

{{- $_ := required "SeaweedFS image tag is required" .Values.nereus.objectStore.seaweedfs.image.tag }}

{{- if and (not .Values.nereus.objectStore.seaweedfs.persistence.enabled) (not .Values.nereus.objectStore.seaweedfs.persistence.existingClaim) }}
{{- fail "SeaweedFS requires persistent storage" }}
{{- end }}

{{- end }}
{{- end -}}
