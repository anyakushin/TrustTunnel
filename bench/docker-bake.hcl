variable "CACHE_REPO" {
  default = ""
}

variable "ENDPOINT_HOSTNAME" {
  default = "endpoint.bench"
}

variable "REMOTE_HOSTNAME" {
  default = "server.bench"
}

variable "CLIENT_DIR" {
  default = "trusttunnel-client"
}

function "cache_from" {
  params = [name]
  result = CACHE_REPO != "" ? ["type=registry,ref=${CACHE_REPO}/${name}:latest"] : []
}

function "cache_to" {
  params = [name]
  result = CACHE_REPO != "" ? ["type=registry,ref=${CACHE_REPO}/${name}:latest,mode=max"] : []
}

group "default" {
  targets = [
    "bench-common",
    "bench-rs",
    "bench-ls",
    "bench-ls-ag",
    "bench-ls-wg",
    "bench-mb-agrs",
    "bench-mb-wg",
  ]
}

target "bench-common" {
  context    = "."
  dockerfile = "Dockerfile"
  tags       = ["bench-common"]
  cache-from = cache_from("bench-common")
  cache-to   = cache_to("bench-common")
}

target "bench-rs" {
  context    = "remote-side"
  dockerfile = "Dockerfile"
  tags       = ["bench-rs"]
  args = {
    HOSTNAME = REMOTE_HOSTNAME
  }
  cache-from = cache_from("bench-rs")
  cache-to   = cache_to("bench-rs")
}

target "bench-ls" {
  context    = "local-side"
  dockerfile = "Dockerfile"
  tags       = ["bench-ls"]
  contexts = {
    bench-common = "target:bench-common"
  }
  cache-from = cache_from("bench-ls")
  cache-to   = cache_to("bench-ls")
}

target "bench-mb-agrs" {
  context    = ".."
  dockerfile = "bench/middle-box/trusttunnel-rust/Dockerfile"
  tags       = ["bench-mb-agrs"]
  args = {
    ENDPOINT_HOSTNAME = ENDPOINT_HOSTNAME
  }
  contexts = {
    bench-common = "target:bench-common"
  }
  cache-from = cache_from("bench-mb-agrs")
  cache-to   = cache_to("bench-mb-agrs")
}

target "bench-mb-wg" {
  context    = "middle-box/wireguard"
  dockerfile = "Dockerfile"
  tags       = ["bench-mb-wg"]
  contexts = {
    bench-common = "target:bench-common"
  }
  cache-from = cache_from("bench-mb-wg")
  cache-to   = cache_to("bench-mb-wg")
}

target "bench-ls-ag" {
  context    = "local-side/trusttunnel"
  dockerfile = "Dockerfile"
  tags       = ["bench-ls-ag"]
  args = {
    CLIENT_DIR = CLIENT_DIR
  }
  contexts = {
    bench-ls = "target:bench-ls"
  }
  cache-from = cache_from("bench-ls-ag")
  cache-to   = cache_to("bench-ls-ag")
}

target "bench-ls-wg" {
  context    = "local-side/wireguard"
  dockerfile = "Dockerfile"
  tags       = ["bench-ls-wg"]
  contexts = {
    bench-ls = "target:bench-ls"
  }
  cache-from = cache_from("bench-ls-wg")
  cache-to   = cache_to("bench-ls-wg")
}
