#!/usr/bin/env bash

set -e
set -o pipefail

HELP_MSG="
Usage: single_host.sh COMMAND

Commands
    Build and prepare images for running
        build [--client=<trusttunnel_client_repo_url>]

    Clean build artifacts
        clean [all]
          all - if specified, the checked out repositories and built images are also removed

    Run the benchmark
        run [--remote_ip=<ipaddr>]
            [--middle_ip=<ipaddr>]
            [--tunnel_type=none|wg|ag|all]
"

SELF_DIR_PATH=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

COMMON_IMAGE="bench-common"
REMOTE_IMAGE="bench-rs"
MIDDLE_AG_RUST_IMAGE="bench-mb-agrs"
MIDDLE_WG_IMAGE="bench-mb-wg"
LOCAL_IMAGE="bench-ls"
LOCAL_AG_IMAGE="bench-ls-ag"
LOCAL_WG_IMAGE="bench-ls-wg"
ENDPOINT_DIR="trusttunnel-endpoint"
CLIENT_DIR="trusttunnel-client"
NETWORK_NAME="bench-network"
ENDPOINT_HOSTNAME="endpoint.bench"
RESULTS_DIR="results"
REMOTE_HOSTNAME="server.bench"
DEFAULT_CLIENT_URL="https://github.com/TrustTunnel/TrustTunnelClient.git"

build() {
  local trusttunnel_client_url

  for arg in "$@"; do
    if [[ "$arg" == --client=* ]]; then
      trusttunnel_client_url=${arg#--client=}
    else
      echo "$HELP_MSG"
      exit 1
    fi
  done

  if [ ! -d "$SELF_DIR_PATH/local-side/trusttunnel/$CLIENT_DIR" ]; then
    git clone "${trusttunnel_client_url:-$DEFAULT_CLIENT_URL}" "$SELF_DIR_PATH/local-side/trusttunnel/$CLIENT_DIR"
  fi

  docker buildx bake --load -f "$SELF_DIR_PATH/docker-bake.hcl"
}

clean_local() {
  local everything="$1"

  docker ps -aq -f ancestor="$LOCAL_AG_IMAGE" | xargs -r docker rm -f
  docker ps -aq -f ancestor="$LOCAL_WG_IMAGE" | xargs -r docker rm -f
  docker ps -aq -f ancestor="$LOCAL_IMAGE" | xargs -r docker rm -f

  if [[ "$everything" == "all" ]]; then
    rm -rf "${SELF_DIR_PATH:?}/local-side/trusttunnel/$CLIENT_DIR"
    docker rmi -f "$LOCAL_AG_IMAGE"
    docker rmi -f "$LOCAL_WG_IMAGE"
    docker rmi -f "$LOCAL_IMAGE"
  fi
}

clean_middle_ag_rust() {
  local everything="$1"

  docker ps -aq -f ancestor="$MIDDLE_AG_RUST_IMAGE" | xargs -r docker rm -f

  if [[ "$everything" == "all" ]]; then
    docker rmi -f "$MIDDLE_AG_RUST_IMAGE"
  fi
}

clean_middle_wg() {
  local everything="$1"

  docker ps -aq -f ancestor="$MIDDLE_WG_IMAGE" | xargs -r docker rm -f
  if [[ "$everything" == "all" ]]; then
    docker rmi -f "$MIDDLE_WG_IMAGE"
  fi
}

clean() {
  ARG=$?

  local everything="$1"

  set +e

  clean_local "$everything"

  clean_middle_ag_rust "$everything"
  clean_middle_wg "$everything"

  docker ps -aq -f ancestor="$REMOTE_IMAGE" | xargs -r docker rm -f

  if [[ "$everything" == "all" ]]; then
    docker rmi -f "$REMOTE_IMAGE"
  fi

  docker network rm "$NETWORK_NAME"

  exit $ARG
}

run() {
  local remote_ip
  local middle_ips=()
  local tunnel_types=(none wg ag)
  local remote_container

  for arg in "$@"; do
    if [[ "$arg" == --remote_ip=* ]]; then
      remote_ip=${arg#--remote_ip=}
    elif [[ "$arg" == --middle_ip=* ]]; then
      middle_ips=("${arg#--middle_ip=}")
    elif [[ "$arg" == --tunnel_type=* ]]; then
      tunnel_types=("${arg#--tunnel_type=}")
    else
      echo "$HELP_MSG"
      exit 1
    fi
  done

  docker network inspect "$NETWORK_NAME" ||
    docker network create --subnet=193.169.1.0/24 "$NETWORK_NAME"

  if [ -z "$remote_ip" ]; then
    remote_container=$(docker run -d \
      --hostname="$ENDPOINT_HOSTNAME" \
      --network="$NETWORK_NAME" \
      --ulimit nofile=65536:65536 \
      "$REMOTE_IMAGE")
    remote_ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$remote_container")
  fi

  if [ ${#middle_ips[@]} -eq 0 ]; then
    for type in "${tunnel_types[@]}"; do
      local middle_container

      if [[ "$type" == "none" ]]; then
        middle_ips+=("---")
      elif [[ "$type" == "wg" ]]; then
        middle_container=$(docker run -d \
          --cap-add=NET_ADMIN --cap-add=SYS_MODULE --device=/dev/net/tun \
          --network="$NETWORK_NAME" \
          "$MIDDLE_WG_IMAGE")
        middle_ips+=("$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$middle_container")")
      elif [[ "$type" == "ag" ]]; then
        middle_container=$(docker run -d \
          --cap-add=NET_ADMIN \
          --net="$NETWORK_NAME" \
          "$MIDDLE_AG_RUST_IMAGE")
        middle_ips+=("$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$middle_container")")
      else
        echo "$HELP_MSG"
        exit 1
      fi
    done
  fi

  for i in "${!tunnel_types[@]}"; do
    local type="${tunnel_types[$i]}"
    local middle_ip="${middle_ips[$i]}"
    if [[ "$type" == "none" ]]; then
      "$SELF_DIR_PATH/local-side/bench.sh" no-vpn "$NETWORK_NAME" "$remote_ip" "$RESULTS_DIR/no-vpn"
      set +e
      clean_local
      set -e
    elif [[ "$type" == "wg" ]]; then
      "$SELF_DIR_PATH/local-side/bench.sh" wg "$NETWORK_NAME" "$remote_ip" "$RESULTS_DIR/wg" "$middle_ip"
      set +e
      clean_local
      clean_middle_wg
      set -e
    elif [[ "$type" == "ag" ]]; then
      "$SELF_DIR_PATH/local-side/bench.sh" ag "$NETWORK_NAME" "$remote_ip" "$RESULTS_DIR/ag" "$middle_ip" "$ENDPOINT_HOSTNAME"
      set +e
      clean_local
      clean_middle_ag_rust
      set -e
    else
      echo "$HELP_MSG"
      exit 1
    fi
  done
}

cmd="$1"
shift
if [[ "$cmd" == "build" ]]; then
  build "$@"
elif [[ "$cmd" == "clean" ]]; then
  clean "$@"
elif [[ "$cmd" == "run" ]]; then
  trap clean EXIT INT TERM
  run "$@"
else
  echo "$HELP_MSG"
  exit 1
fi
