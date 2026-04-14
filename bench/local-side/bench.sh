#!/usr/bin/env bash

HELP_MSG="
Usage:  bench.sh <type=no-vpn|wg|ag> <network> <remote_ip> <results_dir_path> [<endpoint_ip> <endpoint_hostname>]
"

set -e -x
set -o pipefail

LOCAL_IMAGE="bench-ls"
LOCAL_AG_IMAGE="bench-ls-ag"
LOCAL_WG_IMAGE="bench-ls-wg"
CONTAINER_RESULTS_DIR_PATH="/bench/results"
JOB_NUMS=(1 2 4)

start_container() {
  local set_up_cmd="$1"
  local wait_time="${2:-3}"
  local container
  container=$(eval "$set_up_cmd")
  sleep "$wait_time"
  echo "$container"
}

run_test() {
  local container="$1"
  shift
  docker exec -w /bench "$container" ./local_side.py "$@" || true
}

stop_container() {
  local container="$1"
  local results_host_dir_path="$2"
  local tear_down_cmd="${3:-}"
  mkdir -p "$results_host_dir_path"
  docker cp "$container:$CONTAINER_RESULTS_DIR_PATH/." "$results_host_dir_path"
  docker rm -f "$container"
  if [[ -n "$tear_down_cmd" ]]; then
    eval "$tear_down_cmd"
  fi
}

run_through_tun() {
  local set_up_test_suite_cmd="$1"
  local tear_down_test_suite_cmd="$2"
  local results_host_dir_path="$3"
  local remote_ip="$4"

  local container
  container=$(start_container "$set_up_test_suite_cmd")

  for jobs_num in "${JOB_NUMS[@]}"; do
    echo "Running HTTP2 download test with ${jobs_num} parallel jobs..."
    run_test "$container" \
      --output "$CONTAINER_RESULTS_DIR_PATH/lf-dl-h2-$jobs_num.json" \
      --jobs "$jobs_num" \
      --proto "http2" \
      --download "https://$remote_ip:8080/download/1GiB.dat"
    echo "...done"

    echo "Running HTTP3 download test with ${jobs_num} parallel jobs..."
    run_test "$container" \
      --output "$CONTAINER_RESULTS_DIR_PATH/lf-dl-h3-$jobs_num.json" \
      --jobs "$jobs_num" \
      --proto "http3" \
      --download "https://$remote_ip:8080/download/1GiB.dat"
    echo "...done"

    echo "Running HTTP2 upload test with ${jobs_num} parallel jobs..."
    run_test "$container" \
      --output "$CONTAINER_RESULTS_DIR_PATH/lf-ul-h2-$jobs_num.json" \
      --jobs "$jobs_num" \
      --proto "http2" \
      --upload "https://$remote_ip:8080/upload"
    echo "...done"

    echo "Running HTTP3 upload test with ${jobs_num} parallel jobs..."
    run_test "$container" \
      --output "$CONTAINER_RESULTS_DIR_PATH/lf-ul-h3-$jobs_num.json" \
      --jobs "$jobs_num" \
      --proto "http3" \
      --upload "https://$remote_ip:8080/upload"
    echo "...done"
  done

  echo "Running HTTP2 small file download test"
  run_test "$container" \
    --output "$CONTAINER_RESULTS_DIR_PATH/sf-dl-h2.json" \
    --jobs 1000 \
    --proto "http2" \
    --download "https://$remote_ip:8080/download/100KiB.dat"

  echo "Running HTTP3 small file download test"
  run_test "$container" \
    --output "$CONTAINER_RESULTS_DIR_PATH/sf-dl-h3.json" \
    --jobs 1000 \
    --proto "http3" \
    --download "https://$remote_ip:8080/download/100KiB.dat"

  stop_container "$container" "$results_host_dir_path" "$tear_down_test_suite_cmd"
}

run_through_proxy() {
  local set_up_test_suite_cmd="$1"
  local tear_down_test_suite_cmd="$2"
  local results_host_dir_path="$3"
  local remote_ip="$4"
  local proxy_hostname="$5"

  common_script_args=(--proxy "https://premium:premium@$proxy_hostname:4433")

  local container
  container=$(start_container "$set_up_test_suite_cmd")

  for jobs_num in "${JOB_NUMS[@]}"; do
    echo "Running download test with ${jobs_num} parallel jobs..."
    run_test "$container" \
      "${common_script_args[@]}" \
      --output "$CONTAINER_RESULTS_DIR_PATH/lf-dl-$jobs_num.json" \
      --jobs "$jobs_num" \
      --download "https://$remote_ip:8080/download/1GiB.dat"
    echo "...done"
    echo "Running upload test with ${jobs_num} parallel jobs..."
    run_test "$container" \
      "${common_script_args[@]}" \
      --output "$CONTAINER_RESULTS_DIR_PATH/lf-ul-$jobs_num.json" \
      --jobs "$jobs_num" \
      --upload "https://$remote_ip:8080/upload"
    echo "...done"
  done

  echo "Running small files download test..."
  run_test "$container" \
    "${common_script_args[@]}" \
    --output "$CONTAINER_RESULTS_DIR_PATH/sf-dl.json" \
    --jobs 1000 \
    --download "https://$remote_ip:8080/download/100KiB.dat"
  echo "...done"

  stop_container "$container" "$results_host_dir_path" "$tear_down_test_suite_cmd"
}

run_no_vpn() {
  local network="$1"
  local remote_ip="$2"
  local output_dir_path="$3"

  echo "Running bench without any VPN..."
  local set_up_test_suite_cmd="docker run -it -d --network=$network $LOCAL_IMAGE"
  local tear_down_test_suite_cmd=""
  run_through_tun "$set_up_test_suite_cmd" "$tear_down_test_suite_cmd" "$output_dir_path" "$remote_ip"
  echo "Bench without any VPN is done"
}

run_through_wg() {
  local network="$1"
  local remote_ip="$2"
  local endpoint_ip="$3"
  local output_dir="$4"

  local set_up_test_suite_cmd="docker run -d \
    --cap-add=NET_ADMIN --cap-add=SYS_MODULE --device=/dev/net/tun \
    --network=$network \
    $LOCAL_WG_IMAGE \
    $endpoint_ip $remote_ip/32"
  local tear_down_test_suite_cmd=""
  echo "Running bench through WireGuard tunnel..."
  run_through_tun "$set_up_test_suite_cmd" "$tear_down_test_suite_cmd" "$output_dir" "$remote_ip"
  echo "...done"
}

run_through_ag() {
  local network="$1"
  local remote_ip="$2"
  local endpoint_hostname="$3"
  local endpoint_ip="$4"
  local output_dir="$5"

  local set_up_test_suite_cmd="docker run -it -d --add-host=$endpoint_hostname:$endpoint_ip --network=$network $LOCAL_IMAGE"
  local tear_down_test_suite_cmd=""
  echo "Running bench through TrustTunnel http1 proxy..."
  run_through_proxy "$set_up_test_suite_cmd" "$tear_down_test_suite_cmd" "$output_dir/http1/" \
    "$remote_ip" "$endpoint_hostname"
  echo "...done"

  for protocol in http2 http3; do
    set_up_test_suite_cmd="docker run -d \
      --cap-add=NET_ADMIN --cap-add=SYS_MODULE --device=/dev/net/tun \
      --add-host=$endpoint_hostname:$endpoint_ip \
      --network=$network \
      $LOCAL_AG_IMAGE \
      $endpoint_hostname $endpoint_ip $protocol tun"
    tear_down_test_suite_cmd=""
    echo "Running bench through TrustTunnel ${protocol} tunnel..."
    run_through_tun "$set_up_test_suite_cmd" "$tear_down_test_suite_cmd" "$output_dir/${protocol}/" \
      "$remote_ip"

    set_up_test_suite_cmd="docker run -d \
      --cap-add=NET_ADMIN --cap-add=SYS_MODULE --device=/dev/net/tun \
      --add-host=$endpoint_hostname:$endpoint_ip \
      --network=$network \
      $LOCAL_AG_IMAGE \
      $endpoint_hostname $endpoint_ip $protocol socks 1080 1179"
    echo "Running small files download test..."
    local container
    container=$(start_container "$set_up_test_suite_cmd" 10)
    run_test "$container" \
      --output "$CONTAINER_RESULTS_DIR_PATH/sf-dl.json" \
      --jobs 10 \
      --download "https://$remote_ip:8080/download/100KiB.dat" \
      --proxy "socks5://127.0.0.1" \
      --socks-ports-range "(1080,1179)"
    stop_container "$container" "$output_dir/${protocol}/" ""
    echo "...done"
  done
}

type="$1"
network="$2"
remote_ip="$3"
output_dir="$4"
endpoint_ip="$5"
endpoint_hostname="$6"

if [[ "$type" == "no-vpn" ]]; then
  run_no_vpn "$network" "$remote_ip" "$output_dir"
elif [[ "$type" == "wg" ]]; then
  run_through_wg "$network" "$remote_ip" "$endpoint_ip" "$output_dir"
elif [[ "$type" == "ag" ]]; then
  run_through_ag "$network" "$remote_ip" "$endpoint_hostname" "$endpoint_ip" "$output_dir"
else
  echo "$HELP_MSG"
  exit 1
fi
