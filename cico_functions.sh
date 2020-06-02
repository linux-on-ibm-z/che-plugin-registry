#!/bin/bash
#
# Copyright (c) 2018-2020 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#

# Output command before executing
set -x

# Exit on error
set -e

# Source environment variables of the jenkins slave
# that might interest this worker.
function load_jenkins_vars() {
  if [ -e "jenkins-env.json" ]; then
    eval "$(./env-toolkit load -f jenkins-env.json \
            DEVSHIFT_TAG_LEN \
            QUAY_USERNAME \
            QUAY_PASSWORD \
            QUAY_ECLIPSE_CHE_USERNAME \
            QUAY_ECLIPSE_CHE_PASSWORD \
            JENKINS_URL \
            GIT_BRANCH \
            GIT_COMMIT \
            BUILD_NUMBER \
            ghprbSourceBranch \
            ghprbActualCommit \
            BUILD_URL \
            ghprbPullId)"
  fi
}

function install_deps() {
  # We need to disable selinux for now, XXX
  /usr/sbin/setenforce 0  || true

  # Get all the deps in
  yum install -d1 -y yum-utils device-mapper-persistent-data lvm2
  yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  yum install -d1 -y docker-ce \
    git

  service docker start
  echo 'CICO: Dependencies installed'
  
  export DOCKER_BUILD_KIT=1
  export DOCKER_CLI_EXPERIMENTAL=enabled

  docker_version="$(docker --version | cut -d' ' -f3 | tr -cd '0-9.')"
  if [[ "$(version "$docker_version")" < "$(version '19.03')" ]]; then
    echo "Docker $docker_version greater than or equal to 19.03 is required."
  fi

  docker_experimental="$(docker version | \
                         awk '/^ *Experimental:/ {print $2 ; exit}')"
  if [[ "$docker_experimental" != 'true' ]]; then
    echo "Docker experimental flag not enabled:"\
          "Set with 'export DOCKER_CLI_EXPERIMENTAL=enabled'"
  else
    echo "Docker $docker_version supports buildx experimental feature."
  fi

  # Kernel
  kernel_version="$(uname -r)"
  if [[ "$(version "$kernel_version")" < "$(version '4.8')" ]]; then
    echo "Kernel $kernel_version too old - need >= 4.8." \
          " Install a newer kernel."
    exit 1
  else
    echo "kernel $kernel_version has binfmt_misc fix-binary (F) support."
  fi

  #Enable qemu and binfmt support
  docker run --rm --privileged docker/binfmt:66f9012c56a8316f9244ffd7622d7c21c1f6f28d
  docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
}

function set_release_tag() {
  # Let's obtain the tag based on the 
  # version defined in the 'VERSION' file
  TAG=$(head -n 1 VERSION)
  export TAG
}

function set_nightly_tag() {
  # Let's set the tag as nightly
  export TAG="nightly"
}

function set_git_commit_tag() {
  # Let's obtain the tag based on the 
  # git commit hash
  GIT_COMMIT_TAG=$(echo "$GIT_COMMIT" | cut -c1-"${DEVSHIFT_TAG_LEN}")
  export GIT_COMMIT_TAG
}

function tag_push() {
  local TARGET=$1
  docker tag "${IMAGE}" "$TARGET"
  docker push "$TARGET" | cat
}

function build_and_push() {
  TARGET=${TARGET:-"centos"}
  REGISTRY="quay.io"

  if [ "$TARGET" == "rhel" ]; then
    DOCKERFILE="rhel.Dockerfile"
    ORGANIZATION="openshiftio"
    IMAGE="rhel-che-plugin-registry"
  else
    DOCKERFILE="Dockerfile"
    ORGANIZATION="eclipse"
    IMAGE="che-plugin-registry"
    # For pushing to quay.io 'eclipse' organization we need to use different credentials
    QUAY_USERNAME=${QUAY_ECLIPSE_CHE_USERNAME}
    QUAY_PASSWORD=${QUAY_ECLIPSE_CHE_PASSWORD}
  fi

  if [ -n "${QUAY_USERNAME}" ] && [ -n "${QUAY_PASSWORD}" ]; then
    docker login -u "${QUAY_USERNAME}" -p "${QUAY_PASSWORD}" "${REGISTRY}"
  else
    echo "Could not login, missing credentials for pushing to the '${ORGANIZATION}' organization"
  fi
  
  # Create a new builder instance using buildx  
  docker buildx create --name devfile_builder
  docker buildx use devfile_builder
  docker buildx inspect --bootstrap
  docker buildx ls

  set_git_commit_tag
  
  # If additional tag is set (e.g. "nightly"), let's build the image accordingly and also push to 'quay.io'
  if [ -n "${TAG}" ]; then
    docker buildx build --platform=linux/amd64,linux/s390x -t ${REGISTRY}/${ORGANIZATION}/${IMAGE}:${TAG} -f ./build/dockerfiles/${DOCKERFILE} --target registry . --push --progress plain --no-cache
    echo "CICO: '${TAG}'  version of images pushed to '${REGISTRY}/${ORGANIZATION}' organization"
  else
    # Let's build and push image to 'quay.io' using git commit hash as tag first 
    docker buildx build --platform=linux/amd64,linux/s390x -t ${REGISTRY}/${ORGANIZATION}/${IMAGE}:${GIT_COMMIT_TAG} -f ./build/dockerfiles/${DOCKERFILE} --target registry . --push --progress plain --no-cache
    echo "CICO: '${GIT_COMMIT_TAG}' version of images pushed to '${REGISTRY}/${ORGANIZATION}' organization"
  fi
}
