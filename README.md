# NPU-accelerated LLM inference on the Turing RK1

This repository contains everything needed to run an **NPU-accelerated LLM chat** on a [Turing RK1](https://docs.turingpi.com/docs/turing-rk1-specs-and-io-ports) Compute Module powered by the RK3588 NPU via the mainline `rocket` DRM-accel driver.

Runs on **rk04** (Turing RK1, 32 GB, Ubuntu 22.04, kernel 6.18.38).

## Models available

| Model | File | Size | Quick switch |
|---|---|---|---|
| **Qwen 2.5 3B Instruct** | `Qwen2.5-3B-Instruct-f16.gguf` | 5.8 GB | `./switch-model.sh Qwen2.5-3B-Instruct-f16.gguf qwen2.5-3b-instruct` |
| **Gemma 4 E2B IT** | `gemma-4-E2B-it-BF16.gguf` | 8.7 GB | `./switch-model.sh gemma-4-E2B-it-BF16.gguf gemma-4-e2b-it` |

Models live on the ZFS tank at `/models/` (mounted into the container as `/models:ro`).

## How it works

```
client ──> llama-server:8080/v1 ── GGML_BACKEND_PATH ──> /opt/rocket/libggml-rocket.so ──> /dev/accel/accel0 ──> NPU (3 cores)
```

The `rocket-runtime:local` Docker image contains `llama.cpp` built with `GGML_BACKEND_DL=ON`,
plus the rocket NPU backend as a runtime-loadable `.so`.
When `GGML_BACKEND_PATH` is set, ggml offloads big prefill matmuls to the NPU.
Unset it for a clean CPU baseline on the same `llama-server` image.

Point any OpenAI-compatible client at `http://rk04:8080/v1`, or use the built-in UI at `http://rk04:8080`.

## File structure

```
~/rk1-llama-server/
  README.md                  # This file
  docker-compose.yml         # Compose file: llama-server
  Dockerfile                 # rocket-runtime multi-stage build
  bench.sh                   # Benchmark harness (staged into image)
  switch-model.sh            # Model-switching script
  kernel/
    081-rocket-drv-npu-clk.patch   # NPU clock lever patch
  scripts/
    build-image.sh         # Build the rocket-runtime Docker image
    download-model.sh      # Download the GGUF model
  /models/                   # GGUF model files (ZFS tank mount)
```

## Quick start

### 1. Build the Docker image

```bash
cd ~/rk1-llama-server
./scripts/build-image.sh   # ~1 h first time, ~30 s incremental
```

### 2. Download a model

```bash
# Qwen 2.5 3B Instruct (~5.8 GB)
curl -fL --retry 5 --retry-all-errors -C - \
  -o /models/Qwen2.5-3B-Instruct-f16.gguf \
  'https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-f16.gguf'

# Gemma 4 E2B IT (~8.7 GB)
curl -fL --retry 5 --retry-all-errors -C - \
  -o /models/gemma-4-E2B-it-BF16.gguf \
  'https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-BF16.gguf'
```

Or use the convenience script (edit it first to point at the model you want):

```bash
./scripts/download-model.sh
```

### 3. Start the server

```bash
docker compose up -d
```

### 4. Check health

```bash
curl http://localhost:8080/v1/models
```

## Switching models

Use `switch-model.sh` — it stops the current container, swaps `MODEL_FILE` and `LLAMA_ARG_ALIAS`, then restarts:

```bash
cd ~/rk1-llama-server

# Switch to Qwen
./switch-model.sh Qwen2.5-3B-Instruct-f16.gguf qwen2.5-3b-instruct

# Switch to Gemma
./switch-model.sh gemma-4-E2B-it-BF16.gguf gemma-4-e2b-it
```

The script waits up to 30 seconds for the server to become ready, then exits.

You can also switch via env vars directly:

```bash
MODEL_FILE=Qwen2.5-3B-Instruct-f16.gguf LLAMA_ARG_ALIAS=qwen2.5-3b-instruct docker compose up -d
```

The `docker-compose.yml` defaults to `MODEL_FILE=gemma-4-E2B-it-BF16.gguf` and `LLAMA_ARG_ALIAS=gemma-4-e2b-it` if the env vars are not set.

## Using the server

Open **http://rk04:8080** in your browser for the built-in llama.cpp UI, or point an OpenAI-compatible client at `http://rk04:8080/v1`.

```bash
curl http://rk04:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5-3b-instruct","messages":[{"role":"user","content":"Hello!"}]}'
```

## Operation

```bash
# Start
cd ~/rk1-llama-server && docker compose up -d

# Stop
docker compose down

# Restart
docker compose restart

# Rebuild image + restart
./scripts/build-image.sh && docker compose up -d
```

## Upstream sources

| Component | Repository | Ref |
|-----------|------------|------|
| llama.cpp | https://github.com/ggml-org/llama.cpp | `ee445f93` |
| rocket-userspace | https://github.com/gregordinary/rocket-userspace | `e7bf520f` |
| ggml-rocket | https://github.com/gregordinary/ggml-rocket | `b3c7af2e` |
| patches | https://github.com/gregordinary/patches | `a402fd10` |

### Repo-local fixes

The cloned `Dockerfile` from the upstream repo had all `ARG` variable references stripped
(`${BASE}`, `${PATCHES_REPO}`, etc.) and the `LABEL` value lacked quotes around a description
containing spaces. These have been repaired locally — the `Dockerfile` on disk is now
functional. The `build-image.sh` also had a `cp bench.sh .` line that fails when source
and destination are the same file (now removed).

## Performance reference (Qwen2.5-3B-Instruct f16)

All numbers measured with `llama-bench -p 512 -n 0 -r 1 -ngl 0`,
CPUs at full speed (A55 1.8 GHz / A76 2.4 GHz), governor = `performance`.

| Configuration | pp512 (t/s) | vs CPU |
|:---|---:|---:|
| **CPU only** | 21.42 | 1.0x baseline |
| **NPU 600 MHz** | **69.14** | **3.23x** |

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|-------------------|
| `/dev/accel/accel0` missing | Rocket driver not loaded - `sudo modprobe rocket` or check kernel config |
| Container exits with model error | Model not in `/models/` - download it first |
| No NPU speedup | `GGML_BACKEND_PATH` unset in docker-compose.yml |
| NPU half speed (~33 t/s) | CPU stuck at idle frequency - rebuild kernel with `CONFIG_MFD_RK8XX_SPI=y` and `CONFIG_REGULATOR_RK808=y` |
| Container OOMKilled | Raise memory limit in docker-compose.yml (16G is fine for 3B @ 32k ctx) |
| GPU warning in logs | Normal - the NPU is not a GPU, that message is harmless |
| Old kernel (pre-6.18) | Rocket driver only exists in 6.18+. Compile from source |

## See also

- [chat-rk1](https://github.com/eburgueno/chat-rk1): the upstream project this is based on (Kubernetes/Talos)
- [gregordinary/patches](https://github.com/gregordinary/patches): rocket driver patches (clock, voltage, IOMMU, UAF fixes)
- [rocket-userspace](https://github.com/gregordinary/rocket-userspace): NPU userspace library
- [ggml-rocket](https://github.com/gregordinary/ggml-rocket): ggml backend for the RK3588 NPU

## Kernel details

Technical background on the kernel options used for building 6.18+ for the RK1, and how each one affects NPU throughput.

### Required config options

```bash
# NPU driver
scripts/config --enable DRM_ACCEL
scripts/config --module DRM_ACCEL_ROCKET

# NVMe PCIe (DesignWare host controller for RK3588)
scripts/config --enable PCIE_ROCKCHIP_DW_HOST

# CPU frequency scaling (RK806 PMIC regulator for CPU voltage)
scripts/config --enable MFD_RK8XX_SPI
scripts/config --enable REGULATOR_RK808

# Optimize for performance instead of size
scripts/config --enable CC_OPTIMIZE_FOR_PERFORMANCE
```

### Device tree and PM-domain

Enable the NPU cores in the DTSI (`rknn_core_0/1/2` with `npu-supply = <&vdd_npu_s0>`) and apply a PM-domain fix (`need_regulator=false` for `RK3588_PD_NPU` in `pm-domains.c`). Without these, `/dev/accel/accel0` will not appear even if the rocket module is built.

### CPU frequency scaling

The RK3588 needs the **RK806 PMIC** (on SPI) to provide `vdd_cpu_lit_s0` for the A55 little cores.
Without the RK806 MFD and regulator drivers, `cpufreq-dt` stays deferred and all CPUs are stuck at their idle frequency (~408 MHz).

```
CONFIG_MFD_RK8XX_SPI=y    # RK806 PMIC over SPI
CONFIG_REGULATOR_RK808=y  # RK806 internal regulators (vdd_cpu_lit_s0, etc.)
```

The RK8603 regulators (for A76 big cores) are handled by the `fan53555` driver (`CONFIG_REGULATOR_FAN53555=y`) which was already enabled.

**Without this fix**, the NPU's host-prep phase (tiling operands into the NPU's native layout) is CPU-bound and severely throttled — cutting NPU prefill roughly in half (~33 t/s instead of ~69 t/s).

### NPU clock overclock (600 MHz)

The stock NPU runs at 200 MHz.
The `081-rocket-drv-npu-clk.patch` adds a module parameter `rocket_npu_clk_hz` so you can raise it to 600 MHz (applied in Quick start step 1).

Verify after install:

```bash
# Check current clock
cat /sys/module/rocket/parameters/rocket_npu_clk_hz

# Check dmesg for confirmation
dmesg | grep 'NPU clk'

# Benchmark with NPU
docker exec llama-server sh -c \
  'GGML_BACKEND_PATH=/opt/rocket/libggml-rocket.so llama-bench \
    -m /models/Qwen2.5-3B-Instruct-f16.gguf -p 512 -n 0 -r 1 -ngl 0'

# Benchmark without NPU (CPU baseline)
docker exec llama-server sh -c \
  'env -u GGML_BACKEND_PATH llama-bench \
    -m /models/Qwen2.5-3B-Instruct-f16.gguf -p 512 -n 0 -r 1 -ngl 0'
```
