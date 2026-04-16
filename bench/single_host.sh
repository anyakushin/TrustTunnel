#!/usr/bin/env bash

set -e
set -o pipefail

HELP_MSG="
Usage: single_host.sh COMMAND

Commands
    build [--client=<trusttunnel_client_repo_url>]
        Mock: logs repo info and exits 0

    clean [all]
        Mock: removes benchmark results and exits 0

    run [--remote_ip=<ipaddr>]
        [--middle_ip=<ipaddr>]
        [--tunnel_type=none|wg|ag|all]
        Mock: writes fake benchmark results to bench/results/ and exits 0
"

SELF_DIR_PATH=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
RESULTS_DIR="results"

REPO_ROOT=$(git -C "$SELF_DIR_PATH/.." remote get-url origin 2>/dev/null || echo "unknown")
ENDPOINT_BRANCH=$(git -C "$SELF_DIR_PATH/.." rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
ENDPOINT_COMMIT=$(git -C "$SELF_DIR_PATH/.." rev-parse --short HEAD 2>/dev/null || echo "unknown")
CLIENT_DIR="$SELF_DIR_PATH/local-side/trusttunnel/trusttunnel-client"

log_endpoint_info() {
  local repo_url="$REPO_ROOT"
  local repo_name="$repo_url"
  repo_name=$(echo "$repo_name" | sed 's|^git@github.com:||; s|https\?://github.com/||; s|\.git$||')
  echo "[bench/mock] endpoint repo    = $repo_name"
  echo "[bench/mock] endpoint branch  = $ENDPOINT_BRANCH"
  echo "[bench/mock] endpoint commit  = $ENDPOINT_COMMIT"
}

log_client_info() {
  if [ -d "$CLIENT_DIR" ]; then
    local repo_url
    repo_url=$(git -C "$CLIENT_DIR" remote get-url origin 2>/dev/null || echo "unknown")
    local repo_name
    repo_name=$(echo "$repo_url" | sed 's|^git@github.com:||; s|https\?://github.com/||; s|\.git$||')
    echo "[bench/mock] client repo    = $repo_name"
    echo "[bench/mock] client branch  = $(git -C "$CLIENT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
    echo "[bench/mock] client commit  = $(git -C "$CLIENT_DIR" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
  else
    echo "[bench/mock] client dir not found at $CLIENT_DIR"
  fi
}

write_result() {
  local dir="$1"
  local filename="$2"
  local test_type="$3"
  local proto="$4"
  local jobs_num=1

  case "$filename" in
    lf-dl-*|lf-ul-*)
      jobs_num=$(echo "$filename" | grep -oP '\d+' | tail -1)
      ;;
    sf-*)
      jobs_num=1000
      ;;
  esac

  local speed
  speed=$(echo "$filename" | cksum | awk '{print $1 % 10000}')

  mkdir -p "$dir"
  cat > "$dir/$filename" <<EOF
{
  "$test_type": {
    "jobs_num": $jobs_num,
    "failed_num": 0,
    "avg_speed_MBps": 42.$speed,
    "errors": []
  }
}
EOF
}

write_ag_results() {
  local base="$1"
  for proto_dir in http1 http2 http3; do
    for proto in h2 h3; do
      write_result "$base/ag/$proto_dir" "lf-dl-$proto-1.json" "http_download" "$proto"
      write_result "$base/ag/$proto_dir" "lf-dl-$proto-2.json" "http_download" "$proto"
      write_result "$base/ag/$proto_dir" "lf-dl-$proto-4.json" "http_download" "$proto"
      write_result "$base/ag/$proto_dir" "lf-ul-$proto-1.json" "http_upload" "$proto"
      write_result "$base/ag/$proto_dir" "lf-ul-$proto-2.json" "http_upload" "$proto"
      write_result "$base/ag/$proto_dir" "lf-ul-$proto-4.json" "http_upload" "$proto"
    done
    write_result "$base/ag/$proto_dir" "sf-dl-h2.json" "http_download" "h2"
    write_result "$base/ag/$proto_dir" "sf-dl-h3.json" "http_download" "h3"
  done
}

write_wg_results() {
  local base="$1"
  for proto in h2 h3; do
    write_result "$base/wg" "lf-dl-$proto-1.json" "http_download" "$proto"
    write_result "$base/wg" "lf-dl-$proto-2.json" "http_download" "$proto"
    write_result "$base/wg" "lf-dl-$proto-4.json" "http_download" "$proto"
    write_result "$base/wg" "lf-ul-$proto-1.json" "http_upload" "$proto"
    write_result "$base/wg" "lf-ul-$proto-2.json" "http_upload" "$proto"
    write_result "$base/wg" "lf-ul-$proto-4.json" "http_upload" "$proto"
    write_result "$base/wg" "sf-dl-$proto.json" "http_download" "$proto"
  done
}

write_novpn_results() {
  local base="$1"
  for proto in h2 h3; do
    write_result "$base/no-vpn" "lf-dl-$proto-1.json" "http_download" "$proto"
    write_result "$base/no-vpn" "lf-dl-$proto-2.json" "http_download" "$proto"
    write_result "$base/no-vpn" "lf-dl-$proto-4.json" "http_download" "$proto"
    write_result "$base/no-vpn" "lf-ul-$proto-1.json" "http_upload" "$proto"
    write_result "$base/no-vpn" "lf-ul-$proto-2.json" "http_upload" "$proto"
    write_result "$base/no-vpn" "lf-ul-$proto-4.json" "http_upload" "$proto"
    write_result "$base/no-vpn" "sf-dl-$proto.json" "http_download" "$proto"
  done
}

build() {
  echo "[bench/mock] build: starting"
  log_endpoint_info
  log_client_info
  echo "[bench/mock] build: done (skipped Docker builds)"
}

clean() {
  echo "[bench/mock] clean: removing $SELF_DIR_PATH/$RESULTS_DIR/"
  rm -rf "$SELF_DIR_PATH/$RESULTS_DIR/"
  echo "[bench/mock] clean: done"
}

run() {
  local tunnel_type="ag"

  for arg in "$@"; do
    if [[ "$arg" == --tunnel_type=* ]]; then
      tunnel_type="${arg#--tunnel_type=}"
    fi
  done

  if [[ "$tunnel_type" == "all" ]]; then
    tunnel_type="none wg ag"
  fi

  echo "[bench/mock] run: starting, tunnel_types = $tunnel_type"
  log_endpoint_info

  for type in $tunnel_type; do
    case "$type" in
      none) write_novpn_results "$SELF_DIR_PATH/$RESULTS_DIR" ;;
      wg)   write_wg_results   "$SELF_DIR_PATH/$RESULTS_DIR" ;;
      ag)   write_ag_results   "$SELF_DIR_PATH/$RESULTS_DIR" ;;
      *)    echo "unknown tunnel_type: $type"; exit 1 ;;
    esac
    echo "[bench/mock] run: wrote results for $type"
  done

  echo "[bench/mock] run: done"
}

cmd="${1:-}"
if [ -z "$cmd" ]; then
  echo "$HELP_MSG"
  exit 1
fi
shift

case "$cmd" in
  build) build "$@" ;;
  clean) clean "$@" ;;
  run)   run "$@" ;;
  *)     echo "$HELP_MSG"; exit 1 ;;
esac
