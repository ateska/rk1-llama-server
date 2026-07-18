# NPU-accelerated LLM inference on the Turing RK1

This repository contains everything needed to run an **NPU-accelerated LLM chat** on a [Turing RK1](https://docs.turingpi.com/docs/turing-rk1-specs-and-io-ports) module powered by the RK3588 NPU via the mainline `rocket` DRM-accel driver.

> **AI disclosure:** this repository  was largely written with **local AI** assistance ([deepseek-ai/DeepSeek-V4-Flash-DSpark](https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash-DSpark)), directed and reviewed by a human.
> Everything performance-related was measured on real hardware (the numbers below are from a live cluster, not model output),
> but read with the same healthy skepticism.

## What you get

- **llama-server** serving `Qwen2.5-3B-Instruct` (F16) on port 8080
- **Open WebUI** browser chat interface on port 3000 (no login required)
- **NPU acceleration** via `libggml-rocket.so` - prefill **69.14 t/s** (600 MHz NPU + full 2.4 GHz CPU speed)
- Everything runs in Docker - no Kubernetes, no Talos, no cluster

## How it works

```
browser ──> open-webui:3000 ──> llama-server:8080/v1 ── GGML_BACKEND_PATH ──> /opt/rocket/libggml-rocket.so ──> /dev/accel/accel0 ──> NPU (3 cores)
```

The `rocket-runtime:local` Docker image contains `llama.cpp` built with `GGML_BACKEND_DL=ON`,
plus the rocket NPU backend as a runtime-loadable `.so`.
When `GGML_BACKEND_PATH` is set, ggml offloads big prefill matmuls to the NPU.
Unset it for a clean CPU baseline on the same `llama-server` image.

Open WebUI connects to `llama-server` over the Docker Compose network using the OpenAI-compatible API.

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

## Prerequisites

- **Turing RK1** (RK3588, 32 GB) running Turing Pi [Ubuntu 22.04](https://firmware.turingpi.com/turing-rk1/ubuntu_22.04_rockchip_linux/)
- **Docker** and **Docker Compose** v2+
- **Linux kernel source** `linux-6.18.38` (or newer 6.18+) — the rocket driver is not in older kernels

## Quick start

### 1. Build the Linux kernel

Build a 6.18+ kernel with the rocket NPU driver, then raise the NPU clock to 600 MHz.
Config options, device-tree changes, and why they matter are documented under [Kernel details](#kernel-details).

```bash
cd ~/linux-6.18.38

# Raise NPU clock to 600 MHz (recommended for the performance numbers in this README)
patch -p1 < ~/rk1-llama-server/kernel/081-rocket-drv-npu-clk.patch

# Enable required options (see Kernel details for the full list and rationale)
scripts/config --enable DRM_ACCEL
scripts/config --module DRM_ACCEL_ROCKET
scripts/config --enable PCIE_ROCKCHIP_DW_HOST
scripts/config --enable MFD_RK8XX_SPI
scripts/config --enable REGULATOR_RK808
scripts/config --enable CC_OPTIMIZE_FOR_PERFORMANCE

# Apply the DTSI / PM-domain changes described in Kernel details, then build and install
make ARCH=arm64 olddefconfig
make ARCH=arm64 -j$(nproc)
# install the kernel image + modules, then reboot into the new kernel

# After reboot: load rocket at 600 MHz and make it permanent
sudo modprobe rocket rocket_npu_clk_hz=600000000
echo 'options rocket rocket_npu_clk_hz=600000000' | sudo tee /etc/modprobe.d/rocket-npu-clock.conf

# Confirm the NPU device is present
ls -l /dev/accel/accel0
```

### 2. Build the Docker image

```bash
cd ~/rk1-llama-server
./scripts/build-image.sh   # ~1 h first time, ~30 s incremental
```

### 3. Download the model

```bash
./scripts/download-model.sh   # ~6.2 GB, ~5 min on a fast link
```

### 4. Start everything

```bash
docker compose up -d
```

### 5. Check health

```bash
curl http://localhost:8080/v1/models   # llama-server
curl http://localhost:3000/health       # Open WebUI
```

## Web UI

Open **http://<turring-pi>:3000** in your browser - no login required (`WEBUI_AUTH=false`).

Select **qwen2.5-3b-instruct** as the model and start chatting.
The model alias is set automatically via `LLAMA_ARG_ALIAS`.

## Operation

```bash
# Start all services
cd ~/rk1-llama-server && docker compose up -d

# Stop all services
docker compose down

# Restart all
docker compose restart

# Rebuild image + restart
./scripts/build-image.sh && docker compose up -d
```

### Upstream sources

| Component | Repository | Ref |
|-----------|------------|------|
| llama.cpp | https://github.com/ggml-org/llama.cpp | `ee445f93` |
| rocket-userspace | https://github.com/gregordinary/rocket-userspace | `e7bf520f` |
| ggml-rocket | https://github.com/gregordinary/ggml-rocket | `b3c7af2e` |
| patches | https://github.com/gregordinary/patches | `a402fd10` |
| Open WebUI | https://github.com/open-webui/open-webui | `v0.10.2` |

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
| Container exits with model error | Run `./scripts/download-model.sh` first |
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
- [Open WebUI](https://github.com/open-webui/open-webui): browser chat interface

## Kernel details

Technical background on the kernel options used in [Quick start](#1-build-the-linux-kernel), and how each one affects NPU throughput.

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
