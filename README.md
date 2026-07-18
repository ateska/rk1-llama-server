# rk1-llama-server — NPU-accelerated LLM inference on the Turing RK1

This repository contains everything needed to run an **NPU-accelerated LLM chat**
on a Turing RK1 module, powered by the RK3588 NPU via the mainline `rocket`
DRM-accel driver.

Built and tested on **rk04** (Turing RK1, 32 GB, Ubuntu 22.04, kernel 6.18.38).

## What you get

- **llama-server** on port 8080 — inference server + **built-in web chat UI**
- **NPU acceleration** — prefill **3.2× faster** than CPU at **69.14 t/s**
  (600 MHz NPU + full 2.4 GHz CPU speed)
- Single container, zero dependencies — no extra services, databases, or external UIs

## How it works

```
browser ──> http://rk04:8080 ──> llama-server (built-in SvelteKit UI + API)
                                     │
                              GGML_BACKEND_PATH
                                     │
                              /opt/rocket/libggml-rocket.so ──> /dev/accel/accel0
```

llama-server bundles a complete web chat interface (SvelteKit PWA) at its root
URL. The same port serves both the UI (`/`) and the OpenAI-compatible API
(`/v1/...`).

## File structure

```
~/rk1-llama-server/
  README.md                  # This file
  docker-compose.yml         # Single-service compose file
  Dockerfile                 # rocket-runtime multi-stage build
  bench.sh                   # Benchmark harness
  kernel/
    081-rocket-drv-npu-clk.patch   # NPU 600 MHz clock lever patch
  scripts/
    build-image.sh         # Build the Docker image
    download-model.sh      # Download the GGUF model
  models/                    # GGUF model files
```

## Prerequisites

- **Turing RK1** (RK3588, 32 GB recommended) running Ubuntu 22.04
- **Kernel 6.18+** with the `rocket` DRM-accel driver (see kernel setup below)
- **Docker** and **Docker Compose** v2+

### Kernel setup

Built from `linux-6.18.38.tar.xz` with these non-default configs:

```bash
scripts/config --enable DRM_ACCEL
scripts/config --module DRM_ACCEL_ROCKET
scripts/config --enable PCIE_ROCKCHIP_DW_HOST     # NVMe on RK3588
scripts/config --enable MFD_RK8XX_SPI              # RK806 PMIC (CPU voltage)
scripts/config --enable REGULATOR_RK808            # RK806 regulators
scripts/config --enable CC_OPTIMIZE_FOR_PERFORMANCE
```

Plus DTS changes: enable NPU cores (`rknn_core_0/1/2`), PM-domain fix
(`need_regulator=false` for `RK3588_PD_NPU`).

### CPU frequency scaling fix

The RK806 PMIC provides `vdd_cpu_lit_s0` for A55 cores. Without
`CONFIG_MFD_RK8XX_SPI`, `cpufreq-dt` stays deferred and CPUs run at ~408 MHz,
which throttles the NPU's host-prep phase and cuts NPU throughput in half.

| State | CPU freq | NPU pp512 | CPU pp512 |
|---|---|---|---|
| CPUs stuck at idle | 408 MHz | 33.21 t/s | 7.85 t/s |
| After cpufreq fix | 2.4 GHz | **69.14 t/s** | **21.42 t/s** |

## Quick start

```bash
# 1. Build the Docker image (~1 h first time, ~30 s incremental)
cd ~/rk1-llama-server && ./scripts/build-image.sh

# 2. Download the model (~6.2 GB)
./scripts/download-model.sh

# 3. Start
docker compose up -d

# 4. Open http://rk04:8080 in your browser
```

## Operation

```bash
cd ~/rk1-llama-server
docker compose up -d                        # start
docker compose down                         # stop
docker compose restart                      # restart
docker compose logs -f                      # follow logs
./scripts/build-image.sh && docker compose up -d   # rebuild + restart
```

## API usage

```bash
curl http://rk04:8080/v1/models
curl http://rk04:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5-3b-instruct","messages":[{"role":"user","content":"Hello!"}]}'
```

## NPU clock overclock (600 MHz)

Stock: 200 MHz. The 081 patch adds `rocket_npu_clk_hz` parameter for 600 MHz.

```bash
cd ~/linux-6.18.38
patch -p1 < ~/rk1-llama-server/kernel/081-rocket-drv-npu-clk.patch
make ARCH=arm64 M=drivers/accel/rocket modules
sudo cp drivers/accel/rocket/rocket.ko /lib/modules/6.18.38/kernel/drivers/accel/rocket/
sudo rmmod rocket && sudo modprobe rocket rocket_npu_clk_hz=600000000
echo 'options rocket rocket_npu_clk_hz=600000000' | sudo tee /etc/modprobe.d/rocket-npu-clock.conf
```

## Rebuilding the image

```bash
./scripts/build-image.sh && docker compose up -d
```

The image bundles llama.cpp (`ee445f93`), rocket-userspace (`e7bf520f`), and
ggml-rocket (`b3c7af2e`), all pinned in the Dockerfile.

## Performance reference

`llama-bench -p 512 -n 0 -r 1 -ngl 0`, CPUs at full speed, governor = performance.

| Configuration | pp512 (t/s) | vs CPU |
|---|---:|---:|
| CPU only | 21.42 | 1.0× |
| **NPU 600 MHz** | **69.14** | **3.23×** |

## Troubleshooting

| Symptom | Fix |
|---|---|
| `/dev/accel/accel0` missing | `sudo modprobe rocket` or rebuild kernel with `CONFIG_DRM_ACCEL_ROCKET` |
| Container exits with model error | Run `./scripts/download-model.sh` |
| No NPU speedup | `GGML_BACKEND_PATH` unset in compose file |
| NPU half speed (~33 t/s) | CPUs stuck at idle — rebuild kernel with `CONFIG_MFD_RK8XX_SPI` |
| Web UI shows gzip error | Open in a real browser (curl needs `Accept-Encoding: gzip`) |

## See also

- [chat-rk1](https://github.com/eburgueno/chat-rk1) — upstream project (Kubernetes/Talos)
- [gregordinary/patches](https://github.com/gregordinary/patches) — rocket driver patches
- [ggml-rocket](https://github.com/gregordinary/ggml-rocket) — NPU ggml backend
