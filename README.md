# rk1-llama-server — NPU-accelerated LLM inference on the Turing RK1

This repository contains everything needed to run an **NPU-accelerated LLM chat**
on a Turing RK1 module — inference server + browser UI — powered by the RK3588
NPU via the mainline `rocket` DRM-accel driver.

Built and tested on **rk04** (Turing RK1, 32 GB, Ubuntu 22.04, kernel 6.18.38).

## What you get

- **llama-server** serving `Qwen2.5-3B-Instruct` (F16) on port 8080
- **Open WebUI** browser chat interface on port 3000 (no login required)
- **NPU acceleration** via `libggml-rocket.so` — prefill **3.2× faster** than CPU
  at **69.14 t/s** (600 MHz NPU + full 2.4 GHz CPU speed)
- Everything runs in Docker — no Kubernetes, no Talos, no cluster

## How it works

```
browser ──> open-webui:3000 ──> llama-server:8080/v1 ── GGML_BACKEND_PATH ──> /opt/rocket/libggml-rocket.so ──> /dev/accel/accel0 ──> NPU (3 cores)
```

The `rocket-runtime:local` Docker image contains `llama.cpp` built with
`GGML_BACKEND_DL=ON`, plus the rocket NPU backend as a runtime-loadable `.so`.
When `GGML_BACKEND_PATH` is set, ggml offloads big prefill matmuls to the NPU.
Unset it for a clean CPU baseline — same image.

Open WebUI connects to llama-server over the Docker Compose network using the
OpenAI-compatible API.

## File structure

```
~/rk1-llama-server/
  README.md                  # This file
  docker-compose.yml         # Compose file: llama-server + open-webui
  Dockerfile                 # rocket-runtime multi-stage build
  bench.sh                   # Benchmark harness (staged into image)
  kernel/
    081-rocket-drv-npu-clk.patch   # NPU clock lever patch
  scripts/
    build-image.sh         # Build the rocket-runtime Docker image
    download-model.sh      # Download the GGUF model
  models/                    # GGUF model files (created by download-model.sh)
```

Docker volumes:
- `open-webui-data` — chat history, user settings, embedding models

## Prerequisites

- **Turing RK1** (RK3588, 32 GB recommended) running Ubuntu 22.04
- **Kernel 6.18+** with the `rocket` DRM-accel driver (`/dev/accel/accel0`
  must exist — see [kernel setup](#kernel-setup))
- **Docker** and **Docker Compose** v2+

### Kernel setup

The rk04 kernel was built from source (`linux-6.18.38.tar.xz`) with these
non-default config options:

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

Plus DTSI changes to enable the NPU cores (`rknn_core_0/1/2` with
`npu-supply = <&vdd_npu_s0>`) and a PM-domain fix (`need_regulator=false`
for `RK3588_PD_NPU` in `pm-domains.c`).

## CPU frequency scaling

The RK3588 needs the **RK806 PMIC** (on SPI) to provide `vdd_cpu_lit_s0` for
the A55 little cores. Without the RK806 MFD and regulator drivers, `cpufreq-dt`
stays deferred and all CPUs are stuck at their idle frequency (~408 MHz).

This was fixed by building the kernel with:

```
CONFIG_MFD_RK8XX_SPI=y    # RK806 PMIC over SPI
CONFIG_REGULATOR_RK808=y  # RK806 internal regulators (vdd_cpu_lit_s0, etc.)
```

The RK8603 regulators (for A76 big cores) are handled by the `fan53555` driver
(`CONFIG_REGULATOR_FAN53555=y`) which was already enabled.

**Without this fix**, the NPU's host-prep phase (tiling operands into the NPU's
native layout) is CPU-bound and severely throttled — cutting NPU prefill in half:

| State | CPU freq | NPU pp512 | CPU pp512 |
|---|---|---|---|
| CPUs stuck at idle | 408 MHz | 33.21 t/s | 7.85 t/s |
| After cpufreq fix | 2.4 GHz | **69.14 t/s** | **21.42 t/s** |
| Improvement | 6x | **2.1x** | **2.7x** |

## Quick start

```bash
# 1. Build the Docker image (~1 h first time, ~30 s incremental)
cd ~/rk1-llama-server
./scripts/build-image.sh

# 2. Download the model (~6.2 GB, ~5 min on fast link)
./scripts/download-model.sh

# 3. Start everything
docker compose up -d

# 4. Check health
curl http://localhost:8080/v1/models       # llama-server
curl http://localhost:3000/health           # Open WebUI
```

## Web UI

Open **http://rk04:3000** in your browser — no login required (`WEBUI_AUTH=false`).

Select **qwen2.5-3b-instruct** as the model and start chatting. The model alias
is set automatically via `LLAMA_ARG_ALIAS`.

## Operation

```bash
# Start all services
cd ~/rk1-llama-server && docker compose up -d

# Check logs
docker logs llama-server
docker logs open-webui

# Follow logs
docker logs -f llama-server
docker logs -f open-webui

# Stop all services
docker compose down

# Restart all
docker compose restart

# Rebuild image + restart
./scripts/build-image.sh && docker compose up -d
```

## API usage

Direct API access (any OpenAI-compatible client — IDE plugins, `llm`, curl, etc.):

```bash
# List models
curl http://rk04:8080/v1/models

# Chat completion
curl http://rk04:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5-3b-instruct","messages":[{"role":"user","content":"Hello!"}]}'
```

- **Base URL**: `http://rk04:8080/v1`
- **API key**: anything non-empty (llama-server ignores it)
- **Model**: `qwen2.5-3b-instruct`

## NPU clock overclock (600 MHz)

The stock NPU runs at 200 MHz. The 081 clock lever patch adds a module parameter
`rocket_npu_clk_hz` to raise it to 600 MHz.

### Apply (already done on rk04)

```bash
# 1. Apply the patch to the kernel source
cd ~/linux-6.18.38
patch -p1 < ~/rk1-llama-server/kernel/081-rocket-drv-npu-clk.patch

# 2. Rebuild the rocket module
make ARCH=arm64 -C ~/linux-6.18.38 M=drivers/accel/rocket modules

# 3. Install and reload
sudo cp drivers/accel/rocket/rocket.ko /lib/modules/6.18.38/kernel/drivers/accel/rocket/
sudo rmmod rocket && sudo modprobe rocket rocket_npu_clk_hz=600000000

# 4. Make permanent
echo 'options rocket rocket_npu_clk_hz=600000000' | sudo tee /etc/modprobe.d/rocket-npu-clock.conf
```

### Verify

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

## Rebuilding the image

```bash
# Full build
./scripts/build-image.sh

# Then restart
docker compose up -d
```

The image bundles:
- **llama.cpp** (commit `ee445f93`) — `llama-server`, `llama-bench`, `llama-cli`
- **rocket-userspace** (commit `e7bf520f`) — `librocketnpu` userspace library
- **ggml-rocket** (commit `b3c7af2e`) — `libggml-rocket.so` NPU backend
- All pinned for reproducibility in the Dockerfile.

### Upstream sources

| Component | Repository | Ref |
|-----------|------------|------|
| llama.cpp | https://github.com/ggml-org/llama.cpp | `ee445f93` |
| rocket-userspace | https://github.com/gregordinary/rocket-userspace | `e7bf520f` |
| ggml-rocket | https://github.com/gregordinary/ggml-rocket | `b3c7af2e` |
| patches | https://github.com/gregordinary/patches | `a402fd10` |
| Open WebUI | https://github.com/open-webui/open-webui | `v0.10.2` |

## Performance reference (rk04, Qwen2.5-3B-Instruct f16)

All numbers measured with `llama-bench -p 512 -n 0 -r 1 -ngl 0`, CPUs at full
speed (A55 1.8 GHz / A76 2.4 GHz), governor = `performance`.

| Configuration | pp512 (t/s) | vs CPU |
|:---|---:|---:|
| **CPU only** | 21.42 | 1.0x baseline |
| **NPU 600 MHz** | **69.14** | **3.23x** |

### Before and after the cpufreq fix

The NPU's host-prep phase is CPU-bound. With CPUs stuck at idle speed:

| State | CPU freq | NPU pp512 | CPU pp512 |
|---|---|---|---|
| cpufreq broken | 408 MHz | 33.21 t/s | 7.85 t/s |
| cpufreq fixed | 2.4 GHz | **69.14 t/s** | **21.42 t/s** |

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|-------------------|
| `/dev/accel/accel0` missing | Rocket driver not loaded — `sudo modprobe rocket` or check kernel config |
| Container exits with model error | Run `./scripts/download-model.sh` first |
| No NPU speedup | `GGML_BACKEND_PATH` unset in docker-compose.yml |
| NPU half speed (~33 t/s) | CPU stuck at idle frequency — rebuild kernel with `CONFIG_MFD_RK8XX_SPI=y` and `CONFIG_REGULATOR_RK808=y` |
| Container OOMKilled | Raise memory limit in docker-compose.yml (16G is fine for 3B @ 32k ctx) |
| GPU warning in logs | Normal — the NPU is not a GPU, that message is harmless |
| Old kernel (pre-6.18) | Rocket driver only exists in 6.18+. Compile from source |

## See also

- [chat-rk1](https://github.com/eburgueno/chat-rk1) — the upstream project this is based on (Kubernetes/Talos)
- [gregordinary/patches](https://github.com/gregordinary/patches) — rocket driver patches (clock, voltage, IOMMU, UAF fixes)
- [rocket-userspace](https://github.com/gregordinary/rocket-userspace) — NPU userspace library
- [ggml-rocket](https://github.com/gregordinary/ggml-rocket) — ggml backend for the RK3588 NPU
- [Open WebUI](https://github.com/open-webui/open-webui) — browser chat interface
