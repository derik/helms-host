#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
help() {
  cat <<'EOF'
Helm's Host - containerized llama.cpp

Usage:
  ./ctl.sh run --model OWNER/REPO[:QUANT] [--alias NAME] [--mode opencode|webui]
               [--port PORT] [--ctx-size TOKENS] [--gpu-layers N] [-- SERVER_ARGS...]
  ./ctl.sh build          Build the pinned CUDA image (also automatic if missing)
  ./ctl.sh stop           Remove this project's container; keep all model data
  ./ctl.sh logs           Follow logs, including download progress
  ./ctl.sh status         Show this project's container

Only --model is required. Alias defaults to the repository name; mode to opencode.
Optional .env lives beside this script. Shell variables override .env; CLI wins.
Use DOCKER="sudo docker" if Docker requires sudo; run ctl.sh as the data owner.
EOF
}

action="${1:-help}"
if (($#)); then shift; fi
case "$action" in
  help|-h|--help) help; exit ;;
  run|build|stop|logs|status) ;;
  *) die "Unknown command: $action (see ./ctl.sh help)" ;;
esac

# Read literal KEY=value settings, without executing shell code or expanding $.
if [[ -f "$root/.env" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)[[:space:]]*=(.*)$ ]] || die 'Invalid .env line; use KEY=value.'
    key="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
    case "$key" in
      DOCKER|IMAGE_NAME|CONTAINER_NAME|LLAMA_MODELS_DIR|LLAMA_STORAGE_MOUNT|HOST_PORT|CTX_SIZE|GPU_LAYERS|HF_TOKEN) ;;
      *) die "Unknown .env setting: $key" ;;
    esac
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then value="${value:1:${#value}-2}"; fi
    if [[ ! -v "$key" ]]; then export "$key=$value"; fi
  done < "$root/.env"
fi

image="${IMAGE_NAME:-local/helms-host:b820cc8e6f94}"
container="${CONTAINER_NAME:-local-helms-host}"
models="${LLAMA_MODELS_DIR:-/srv/ai/models}"
mount="${LLAMA_STORAGE_MOUNT-/srv/ai}"
port="${HOST_PORT:-8080}"
ctx="${CTX_SIZE:-65536}"
layers="${GPU_LAYERS:-99}"
model='' alias='' mode=opencode
extra=()
while (($#)); do
  [[ "$action" == run ]] || die "$action takes no options."
  if [[ "$1" == --*=* ]]; then set -- "${1%%=*}" "${1#*=}" "${@:2}"; fi
  case "$1" in
    --) shift; extra=("$@"); break ;;
    --model|--alias|--mode|--port|--ctx-size|--gpu-layers)
      (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || die "Missing value for $1."
      case "$1" in
        --model) model="$2" ;; --alias) alias="$2" ;; --mode) mode="$2" ;;
        --port) port="$2" ;; --ctx-size) ctx="$2" ;; --gpu-layers) layers="$2" ;;
      esac
      shift 2 ;;
    -h|--help) help; exit ;;
    *) die "Unknown option: $1 (see ./ctl.sh help)" ;;
  esac
done
[[ "$container" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]+$ ]] || die 'Invalid CONTAINER_NAME.'
read -r -a docker_cmd <<< "${DOCKER:-docker}"
docker_cli() { "${docker_cmd[@]}" "$@"; }
build() {
  # Only send the Dockerfile: no .env, model weights or local build context.
  docker_cli build --tag "$image" - < "$root/Dockerfile"
}
owned_container() {
  local owner markers key
  owner="$(docker_cli container inspect --format '{{with index .Config.Labels "io.helms-host.service"}}{{.}}{{end}}' "$container" 2>/dev/null)" || return 1
  if [[ "$owner" == helms-host ]]; then return 0; fi
  if [[ -z "$owner" ]]; then
    # Earlier releases used a different service-label namespace. Recognize the
    # explicit service identity, never just the container name or image.
    markers="$(docker_cli container inspect --format '{{range $key, $value := .Config.Labels}}{{if eq $value "helms-host"}}{{println $key}}{{end}}{{end}}' "$container")" ||
      die "Cannot inspect ownership labels for $container."
    while IFS= read -r key; do
      if [[ "$key" == *.service ]]; then return 0; fi
    done <<< "$markers"
  fi
  die "Container $container is not identified as Helm's Host; check its labels or choose another CONTAINER_NAME."
}
check_storage() {
  [[ "$models" == /* ]] || models="$root/$models"
  models="$(realpath -m -- "$models")"
  [[ "$models" != *,* ]] || die 'Model storage path cannot contain a comma (Docker mount syntax).'
  if [[ -n "$mount" ]]; then
    [[ "$mount" == /* ]] || die 'LLAMA_STORAGE_MOUNT must be an absolute path or empty.'
    mount="$(realpath -m -- "$mount")"
    [[ -d "$mount" ]] || die "Storage mount is not an accessible directory: $mount. No directories created."
    findmnt --kernel --mountpoint "$mount" --noheadings --output TARGET >/dev/null ||
      die "Storage is not mounted at $mount. Check findmnt -T '$mount'; set LLAMA_STORAGE_MOUNT to the exact mount point. No directories created."
    # Also check existing cache/home symlinks before creating anything.
    local path existing
    for path in "$models" "$models/cache" "$models/.home"; do
      path="$(realpath -m -- "$path")"
      [[ "$mount" == / || "$path" == "$mount" || "$path" == "$mount/"* ]] ||
        die 'Model/cache/home path is outside LLAMA_STORAGE_MOUNT. No directories created.'
      existing="$path"
      while [[ ! -e "$existing" ]]; do existing="$(dirname -- "$existing")"; done
      [[ "$(stat -c %d -- "$existing")" == "$(stat -c %d -- "$mount")" ]] ||
        die 'Model/cache/home path is on a different filesystem. No directories created.'
    done
  fi
}

if [[ "$action" == run ]]; then
  [[ "$model" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+(:[a-zA-Z0-9_.-]+)?$ ]] ||
    die 'Provide --model OWNER/REPO[:QUANT].'
  if [[ -z "$alias" ]]; then alias="${model##*/}"; alias="${alias%%:*}"; fi
  [[ "$alias" != -* && ! "$alias" =~ [[:space:],] ]] || die 'Alias must be one name without spaces or commas.'
  case "$mode" in opencode) ui=--no-ui ;; webui) ui=--ui ;; *) die 'Mode must be opencode or webui.' ;; esac
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || die 'Port must be 1–65535.'
  [[ "$ctx" =~ ^[1-9][0-9]*$ ]] || die 'Context size must be a positive integer.'
  [[ "$layers" =~ ^[0-9]+$ ]] || die 'GPU layers must be a nonnegative integer.'
  check_storage
fi

# Fail on daemon/permission errors before altering storage or a running container.
docker_cli info >/dev/null
case "$action" in
  build) build ;;
  run)
    exists=false
    if owned_container; then exists=true; fi
    if ! docker_cli image inspect "$image" >/dev/null 2>&1; then build; fi
    mkdir -p -- "$models/cache" "$models/.home"
    [[ -w "$models/cache" && -w "$models/.home" ]] || die 'Cache/home must be writable by the current user; no ownership changes performed.'
    if "$exists"; then docker_cli container rm --force "$container" >/dev/null; fi
    docker_cli run --detach --name "$container" --label io.helms-host.service=helms-host \
      --gpus all --ipc host --user "$(id -u):$(id -g)" \
      --publish "$port:8080" --mount "type=bind,source=$models,target=/models" \
      --env HOME=/models/.home --env LLAMA_CACHE=/models/cache \
      --env HF_HOME=/models/.home/huggingface --env HF_TOKEN \
      "$image" "$ui" --host 0.0.0.0 --port 8080 \
      -hf "$model" --alias "$alias" --ctx-size "$ctx" --n-gpu-layers "$layers" \
      --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn on --parallel 1 \
      --jinja --reasoning off --no-mmproj --timeout 3600 "${extra[@]}"
    printf 'Container started; model may still be downloading/loading. Use ./ctl.sh logs.\n'
    printf 'API: http://127.0.0.1:%s/v1  Model: %s\n' "$port" "$alias"
    if [[ "$mode" == webui ]]; then printf 'Web UI: http://127.0.0.1:%s\n' "$port"; fi
    ;;
  stop)
    if owned_container; then docker_cli container rm --force "$container"; else printf 'No container named %s.\n' "$container"; fi ;;
  logs)
    owned_container || die "No container named $container."
    docker_cli logs --follow --tail 100 "$container" ;;
  status)
    if owned_container; then
      docker_cli ps --all --filter "name=^/${container//./\\.}$"
    else
      printf 'No container named %s.\n' "$container"
    fi ;;
esac
