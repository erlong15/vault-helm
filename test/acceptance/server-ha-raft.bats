#!/usr/bin/env bats

load _helpers

@test "server/ha-raft: testing deployment" {
  cd `chart_dir`

  helm install --name="$(name_prefix)" \
    -f ./test/acceptance/values-raft.yaml .
  wait_for_running $(name_prefix)-0

  # Sealed, not initialized
  local sealed_status=$(kubectl exec "$(name_prefix)-0" -- vault status -format=json |
    jq -r '.sealed' )
  [ "${sealed_status}" == "true" ]

  local init_status=$(kubectl exec "$(name_prefix)-0" -- vault status -format=json |
    jq -r '.initialized')
  [ "${init_status}" == "false" ]

  # Replicas
  local replicas=$(kubectl get statefulset "$(name_prefix)" --output json |
    jq -r '.spec.replicas')
  [ "${replicas}" == "3" ]

  # Volume Mounts
  local volumeCount=$(kubectl get statefulset "$(name_prefix)" --output json |
    jq -r '.spec.template.spec.containers[0].volumeMounts | length')
  [ "${volumeCount}" == "2" ]

  # Volumes
  local volumeCount=$(kubectl get statefulset "$(name_prefix)" --output json |
    jq -r '.spec.template.spec.volumes | length')
  [ "${volumeCount}" == "1" ]

  local volume=$(kubectl get statefulset "$(name_prefix)" --output json |
    jq -r '.spec.template.spec.volumes[0].configMap.name')
  [ "${volume}" == "$(name_prefix)-config" ]

  local privileged=$(kubectl get statefulset "$(name_prefix)" --output json |
    jq -r '.spec.template.spec.containers[0].securityContext.privileged')
  [ "${privileged}" == "true" ]

  # Service
  local service=$(kubectl get service "$(name_prefix)" --output json |
    jq -r '.spec.clusterIP')
  [ "${service}" != "None" ]

  local service=$(kubectl get service "$(name_prefix)" --output json |
    jq -r '.spec.type')
  [ "${service}" == "ClusterIP" ]

  local ports=$(kubectl get service "$(name_prefix)" --output json |
    jq -r '.spec.ports | length')
  [ "${ports}" == "2" ]

  local ports=$(kubectl get service "$(name_prefix)" --output json |
    jq -r '.spec.ports[0].port')
  [ "${ports}" == "8200" ]

  local ports=$(kubectl get service "$(name_prefix)" --output json |
    jq -r '.spec.ports[1].port')
  [ "${ports}" == "8201" ]

  # Service Headless
  local service=$(kubectl get service "$(name_prefix)-headless" --output json |
    jq -r '.spec.clusterIP')
  [ "${service}" = "None" ]

  local ports=$(kubectl get service "$(name_prefix)-headless" --output json |
    jq -r '.spec.ports | length')
  [ "${ports}" == "2" ]

  local ports=$(kubectl get service "$(name_prefix)-headless" --output json |
    jq -r '.spec.ports[0].port')
  [ "${ports}" == "8200" ]

  local ports=$(kubectl get service "$(name_prefix)-headless" --output json |
    jq -r '.spec.ports[1].port')
  [ "${ports}" == "8201" ]

  # Vault Init
  local token=$(kubectl exec -ti "$(name_prefix)-0" -- \
    vault operator init -format=json -n 1 -t 1 | \
    jq -r '.unseal_keys_b64[0]')
  [ "${token}" != "" ]
   
  kubectl exec -ti "$(name_prefix)-0" -- vault operator unseal ${token}
  wait_for_ready "$(name_prefix)-0"

  # Vault Raft Join
  local pods=($(kubectl get pods --selector='app.kubernetes.io/name=vault' -o json | jq -r '.items[].metadata.name'))
  for pod in "${pods[@]}"
  do
      if [[ ${pod?} != "$(name_prefix)-0" ]]
      then
          kubectl exec -ti ${pod} -- vault operator raft join http://$(name_prefix)-0.$(name_prefix)-headless:8200
          sleep 5
          kubectl exec -ti ${pod} -- vault operator unseal ${token}
      fi
  done

  # Sealed, not initialized
  local sealed_status=$(kubectl exec "$(name_prefix)-0" -- vault status -format=json |
    jq -r '.sealed' )
  [ "${sealed_status}" == "false" ]

  local init_status=$(kubectl exec "$(name_prefix)-0" -- vault status -format=json |
    jq -r '.initialized')
  [ "${init_status}" == "true" ]
}

#cleanup
teardown() {
  helm delete --purge vault
  kubectl delete --all pvc
}