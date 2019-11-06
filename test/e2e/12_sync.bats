#!/usr/bin/env bats

load lib/env
load lib/install
load lib/poll
load lib/defer

git_port_forward_pid=""
clone_dir=""

function setup() {
  kubectl create namespace "$FLUX_NAMESPACE"
  # Install flux and the git server, allowing external access
  install_git_srv flux-git-deploy git_srv_result
  # shellcheck disable=SC2154
  git_ssh_cmd="${git_srv_result[0]}"
  export GIT_SSH_COMMAND="$git_ssh_cmd"
  # shellcheck disable=SC2154
  git_port_forward_pid="${git_srv_result[1]}"
  install_flux_with_fluxctl
  # Clone the repo and
  clone_dir="$(mktemp -d)"
  git clone -b master ssh://git@localhost/git-server/repos/cluster.git "$clone_dir"
  # shellcheck disable=SC2164
  cd "$clone_dir"
}

@test "Basic sync test" {
  # Wait until flux deploys the workloads
  poll_until_true 'workload podinfo' 'kubectl -n demo describe deployment/podinfo'

  # Check the sync tag
  git pull -f --tags
  local sync_tag_hash
  sync_tag_hash=$(git rev-list -n 1 flux)
  local head_hash
  head_hash=$(git rev-list -n 1 HEAD)
  [ "$head_hash" = "$sync_tag_hash" ]

  # Add a change, wait for it to happen and check the sync tag again
  sed -i'.bak' 's%stefanprodan/podinfo:.*%stefanprodan/podinfo:3.1.5%' "${clone_dir}/workloads/podinfo-dep.yaml"
  git -c 'user.email=foo@bar.com' -c 'user.name=Foo' commit -am "Bump podinfo"
  head_hash=$(git rev-list -n 1 HEAD)
  git push
  poll_until_equals "podinfo image" "stefanprodan/podinfo:3.1.5" "kubectl get pod -n demo -l app=podinfo -o\"jsonpath={['items'][0]['spec']['containers'][0]['image']}\""
  git pull -f --tags
  sync_tag_hash=$(git rev-list -n 1 flux)
  [ "$head_hash" = "$sync_tag_hash" ]
}

@test "Sync fails on duplicate resource" {
  # Wait until flux deploys the workloads
  poll_until_true 'workload podinfo' 'kubectl -n demo describe deployment/podinfo'

  # Check the sync tag
  git pull -f --tags
  local sync_tag_hash
  sync_tag_hash=$(git rev-list -n 1 flux)
  local head_hash
  head_hash=$(git rev-list -n 1 HEAD)
  [ "$head_hash" = "$sync_tag_hash" ]
  podinfo_image=$(kubectl get pod -n demo -l app=podinfo -o"jsonpath={['items'][0]['spec']['containers'][0]['image']}")

  # Bump the image of podinfo, duplicate the resource definition (to cause a sync failure)
  # and make sure the sync doesn't go through
  sed -i'.bak' 's%stefanprodan/podinfo:.*%stefanprodan/podinfo:3.1.5%' "${clone_dir}/workloads/podinfo-dep.yaml"
  cp "${clone_dir}/workloads/podinfo-dep.yaml" "${clone_dir}/workloads/podinfo-dep-2.yaml"
  git add "${clone_dir}/workloads/podinfo-dep-2.yaml"
  git -c 'user.email=foo@bar.com' -c 'user.name=Foo' commit -am "Bump podinfo and duplicate it to cause an error"
  git push
  # Wait until we find the duplicate failure in the logs
  poll_until_true "duplicate resource in Flux logs" "kubectl logs -n $FLUX_NAMESPACE -l name=flux | grep -q \"duplicate definition of 'demo:deployment/podinfo'\""
  # Make sure that the version of podinfo wasn't bumped
  local podinfo_image_now
  podinfo_image_now=$(kubectl get pod -n demo -l app=podinfo -o"jsonpath={['items'][0]['spec']['containers'][0]['image']}")
  [ "$podinfo_image" = "$podinfo_image_now" ]
  # Make sure that the Flux sync tag remains untouched
  git pull -f --tags
  sync_tag_hash=$(git rev-list -n 1 flux)
  [ "$head_hash" = "$sync_tag_hash" ]
}

function teardown() {
  rm -rf "$clone_dir"
  # Teardown the created port-forward to gitsrv and restore Git settings.
  kill "$git_port_forward_pid"
  unset GIT_SSH_COMMAND
  # Uninstall Flux and the global resources it installs.
  uninstall_flux_with_fluxctl
  # Removing the namespace also takes care of removing gitsrv.
  kubectl delete namespace "$FLUX_NAMESPACE"
  # Only remove the demo workloads after Flux, so that they cannot be recreated.
  kubectl delete namespace "$DEMO_NAMESPACE"
}