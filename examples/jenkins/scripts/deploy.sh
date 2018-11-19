#!/usr/bin/env bash
set -e

# SKIP_CLUSTERS are clusters we should not perform deploys to. If you want to disable a deployment
# to a target cluster, add its identifier here!!!
SKIP_CLUSTERS=(
  bf2-DEVEL
)

# this label is appended to all resources managed by this deployment script
# so we can identify what configmaps to prune
id_label="tumblr.com/managed-configmap"
# this label is appended to all resources, with value $generation. We use this to
# prune all configmaps resources we manage, but have been removed from this repo
generation_label="tumblr.com/config-version"
generation="$(date +%s)"

# check for the output directory
manifest_directory="$(dirname $0)/../.generated"

# determine what target clusters are based on our generated path; we expect
# .generated/<az>/<CLUSTER>/<someyamls>
# TARGET_CLUSTERS will be a list of ("bf2-DEVEL" "bf2-PRODUCTION") etc, based on what configs
# are generated by the projector. Do NOT add any elements here manually! They will be intuited
# automatically by which manifests are on disk here under `<az>/<cluster>/*.yaml`!
TARGET_CLUSTERS=()
for d in $(find ${manifest_directory} -maxdepth 2 -mindepth 2 -type d) ; do
  # process the .generated directory to discover our deploy targets based on directory structure!
  _az="${d%/*}"
  az="${_az##*/}"
  cluster="${d##*/}"
  is_valid_target=1
  for skip_cluster in "${SKIP_CLUSTERS[@]}" ; do
    if [[ ${az}-${cluster} == $skip_cluster ]] ; then
      is_valid_target=0
      break
    fi
  done
  if [[ $is_valid_target -eq 1 ]] ; then
    TARGET_CLUSTERS+=("${az}-${cluster}")
  else
    echo "Skipping deployment to ${az}-${cluster}, due to explicit request to skip this cluster" >&2
  fi
done

for target in "${TARGET_CLUSTERS[@]}" ; do
  if [[ -r /etc/k8s-kubeconfig/kubeconfig-${target} ]] ; then
    export KUBECONFIG="/etc/k8s-kubeconfig/kubeconfig-${target}"
    echo "Setting KUBECONFIG=$KUBECONFIG"
  else
    echo "Changing to context $target"
    kubectl config use-context "$(echo "$target" | tr '[:upper:]' '[:lower:]')"
  fi

  path="${manifest_directory}/${target%-*}/${target#*-}"
  if [[ ! -d $path ]] ; then
    echo "$path is not a directory! This should have been created by generating ConfigMaps for the $target cluster. aborting"
    exit 1
  fi
  pushd $path
  echo "Deploying ConfigMaps in ${path} to ${target} with context $(kubectl config current-context)"
  for f in $(find . -name '*.yaml') ; do
    if kubectl get -f "$f" &>/dev/null ; then
      echo -n "  Replacing $f... "
      kubectl replace -f "$f"
    else
      echo -n "  Creating $f... "
      kubectl create -f "$f"
    fi
    # now, label the job we just created so we know _we_ created it (so we can know what to remove)
    echo -n "  Setting labels on job... "
    kubectl label -f "$f" --overwrite "${id_label}=true" "${generation_label}=${generation}"
  done

  # clean up all configmaps that are managed, but do not have our matching generation identifier
  cleanup_selector="${id_label}=true,${generation_label}"'!'"=${generation}"
  # will output a string like "ns1/foo ns2/bar ns3/baz"
  cleanup_jobs="$( \
    kubectl get configmaps \
      --no-headers=true \
      -o jsonpath="{range.items[*]}{.metadata.namespace}/{.metadata.name} {end}" \
      --all-namespaces \
      -l "${cleanup_selector}" \
  )"
  echo "Removing all configmaps matching ${cleanup_selector}"
  for j in $cleanup_jobs ; do
    name="${j##*/}"
    ns="${j%%/*}"
    echo -n "  Removing stale ConfigMap $name from namespace $ns ($j)... "
    kubectl delete "configmap/${name}" -n "${ns}"
  done

  popd
done

