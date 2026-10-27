# Helm's Host

Helm's Host runs Hugging Face GGUF models in a Docker container, using named
options. Pick a model, download it automatically if needed, and serve it through
an OpenAI-compatible API or llama.cpp's browser UI.

The CUDA build targets an RTX 3090 (GPU architecture 86) and pins llama.cpp to
`b820cc8e6f94843d32f92c8ebd7db837dae2bd8b`, CUDA to 12.8.1, and the container's
Ubuntu base to 24.04. Runtime files are `ctl.sh`, `Dockerfile`, and an optional
`.env`; `.env.example` documents the defaults. Offline tests live in `tests/`.

## Run on the Ubuntu server

Requires Bash, Docker with GPU support and a compatible NVIDIA driver/container
toolkit, plus Ubuntu's `realpath`, `stat` and `findmnt`. No Compose or Python needed.
Container build settings do not indicate your host OS or driver version.

Stop your current GPU workload manually first. From the repository directory:

```bash
./ctl.sh run \
  --model unsloth/Qwen3.5-35B-A3B-GGUF:UD-Q4_K_XL \
  --alias qwen3.5-35b-a3b \
  --mode opencode

./ctl.sh logs
./ctl.sh status
./ctl.sh stop
```

Only `--model` is required. `--alias` defaults to the repository name without the
owner or quantization suffix; `--mode` defaults to `opencode`. Both `--key value`
and `--key=value` work. Use `--mode webui` for the native browser UI.
OpenCode mode serves the API; it does not launch or configure the OpenCode client.
Point that client's OpenAI-compatible provider to `http://SERVER:8080/v1` with
the selected alias as its model ID.

The first run builds the CUDA image if missing, then llama.cpp downloads the
selected model if it is not cached. Later runs reuse the image and persistent
cache. No model list, per-model targets or download script is needed. To rebuild
after editing the Dockerfile, run `./ctl.sh build`. The build sends only the
Dockerfile to Docker, so local settings and weights never enter the build context.

`run` replaces only this project's previous container, leaving downloaded models
in place. It reports that the container has started; downloads and model loading
can take a while before the endpoint responds. Follow logs to diagnose invalid
selectors, authentication, startup errors or insufficient VRAM.

## Settings

Defaults work without an `.env`. To customize, create it once without replacing
an existing file:

```bash
test -e .env || cp .env.example .env
```

The default Docker image is `local/helms-host:b820cc8e6f94`, the container is
`local-helms-host`, and its ownership label is `io.helms-host.service=helms-host`.
Existing `IMAGE_NAME` and `CONTAINER_NAME` settings override these defaults.
Containers from earlier releases with a service label identifying `helms-host`
are also recognized. The next `run` recreates them with the current ownership
label while preserving the model cache. A conflicting current label or a
container without a recognized service label is refused.

Edit `.env` for storage, port, context size, GPU layers or an optional `HF_TOKEN`.
Values are literal, with optional matching quotes; no shell expansion or inline
comments. Precedence is CLI options, inherited shell variables, `.env`, defaults.
The script resolves its own directory, so it also works from elsewhere.
Use `DOCKER="sudo docker" ./ctl.sh run ...` if needed; run the script as the user
who owns the model cache, so container files retain that user's UID/GID.
For gated models with sudo, use `DOCKER="sudo --preserve-env=HF_TOKEN docker"`
so the Docker client can forward the token to the container.

```bash
./ctl.sh run --model OWNER/REPO:QUANT --port 8081 --ctx-size 32768 --gpu-layers 99

# Optional native llama-server flags after -- (including model-specific sampling):
./ctl.sh run --model OWNER/REPO:QUANT -- --temp 0.6 --top-p 0.95 --top-k 20
```

Defaults use 65,536 context tokens, full offloading up to 99 layers, q8_0 KV cache,
Flash Attention, one slot, Jinja tool templates, reasoning off and text-only loading
(`--no-mmproj`). Model fit depends on its architecture, quantization and context;
reduce `--ctx-size` or GPU layers if necessary. Extra flags are passed verbatim
to llama.cpp after the defaults; changing its host/port can invalidate the printed
endpoint and Docker port mapping.

## Storage and validation

`/srv/ai/models` is bind-mounted to `/models`; `LLAMA_CACHE=/models/cache`
keeps downloaded models between runs and can reuse an existing llama.cpp cache.
The script does not move, delete or rewrite existing
weights or settings. The script checks `LLAMA_STORAGE_MOUNT` (default `/srv/ai`)
before creating cache/home folders or replacing its container. If your drive is
mounted at `/srv`, set that as the mount and keep the models path `/srv/ai/models`.
Only set `LLAMA_STORAGE_MOUNT=` to intentionally allow storage without a separate
mount. Relative model paths resolve beside `ctl.sh`. Keep custom storage outside
the checkout or under `models/`. The included `.gitignore` excludes `.env`, model
weights, caches and logs while keeping `.env.example` in source control.

The default port is published on the server's network interfaces.
API: `http://SERVER:8080/v1`; Web UI: `http://SERVER:8080`.
Keep access on your trusted network. Stop removes only this project's container;
it keeps storage, images and other services. Status includes stopped containers;
it does not check readiness.

Run the offline checks from the repository directory (Python 3 is needed only
for tests, using its standard library):

```bash
bash -n ctl.sh
python3 -B -m unittest discover -s tests -v
```

Tests use temporary storage and a fake Docker command. They do not contact a
Docker daemon, download models, or require a GPU. They can also run from any
directory with `python3 -B /path/to/helms-host/tests/test_ctl.py`.

On the server, build and run your chosen model, follow logs, then verify
readiness and a chat request:

```bash
curl -fsS http://127.0.0.1:8080/v1/models
curl -fsS http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.5-35b-a3b","messages":[{"role":"user","content":"Say hello"}],"max_tokens":32}'
```

Use your actual port/alias. Verify the GPU is detected in logs and cached weights
are reused on the next run. GPU, downloads, inference and LAN access require
server validation.
