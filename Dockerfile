# syntax=docker/dockerfile:1
#
# rocket-runtime — aarch64 LLM inference image for the RK3588 NPU.
# Based on github.com/eburgueno/chat-rk1
#
# Build: docker build -t rocket-runtime:local .
ARG BASE=debian:trixie-slim

ARG ROCKET_USERSPACE_REPO=https://github.com/gregordinary/rocket-userspace
ARG ROCKET_USERSPACE_REF=e7bf520f16119556a6bbfffbb3859acf0cb15750
ARG GGML_ROCKET_REPO=https://github.com/gregordinary/ggml-rocket
ARG GGML_ROCKET_REF=b3c7af2ec46ef4b46c06ee38d72734f6be46eee2
ARG PATCHES_REPO=https://github.com/gregordinary/patches
ARG PATCHES_REF=a402fd101afad8bb1d5cfe2e99fc78e2bd35b940
ARG LLAMACPP_REPO=https://github.com/ggml-org/llama.cpp
ARG LLAMACPP_REF=ee445f93d8a0a5033a46d1960e901ef5caec9a41

FROM  AS build
ARG ROCKET_USERSPACE_REPO ROCKET_USERSPACE_REF
ARG GGML_ROCKET_REPO GGML_ROCKET_REF
ARG PATCHES_REPO PATCHES_REF
ARG LLAMACPP_REPO LLAMACPP_REF
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends       build-essential cmake git ca-certificates pkg-config       libdrm-dev libcurl4-openssl-dev     && rm -rf /var/lib/apt/lists/*
WORKDIR /src

# rocket_userspace needs the rocket_accel.h UAPI header
RUN git clone --filter=blob:none  patches     && git -C patches checkout      && install -D -m0644 patches/rocket/uapi/rocket_accel.h /usr/include/drm/rocket_accel.h

# llama.cpp: shared libs + DL backend loader
RUN git clone  llama.cpp     && git -C llama.cpp checkout      && cmake -S llama.cpp -B llama.cpp/build          -DCMAKE_BUILD_TYPE=Release          -DGGML_BACKEND_DL=ON -DBUILD_SHARED_LIBS=ON          -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8.2-a+fp16+dotprod          -DLLAMA_CURL=ON -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF     && cmake --build llama.cpp/build -j24          --target llama-bench llama-cli llama-server

# rocket_userspace (librocketnpu)
RUN git clone  rocket-userspace     && git -C rocket-userspace checkout      && cmake -S rocket-userspace -B rocket-userspace/build          -DCMAKE_BUILD_TYPE=Release -DROCKETNPU_BUILD_TESTS=OFF     && cmake --build rocket-userspace/build -j24     && cmake --install rocket-userspace/build --prefix /usr/local

# ggml_rocket: the NPU backend .so
RUN git clone  ggml-rocket     && git -C ggml-rocket checkout      && cmake -S ggml-rocket -B ggml-rocket/build-dl          -DCMAKE_BUILD_TYPE=Release          -DGGML_ROCKET_DL=ON          -DHOST_DIR=/src/llama.cpp          -DGGML_LIB_DIR=/src/llama.cpp/build/bin          -DROCKETNPU_DIR=/src/rocket-userspace     && cmake --build ggml-rocket/build-dl -j24     && install -D -m0755 ggml-rocket/build-dl/libggml-rocket.so /opt/rocket/libggml-rocket.so

# Collect binaries + shared libs into /opt/llama
RUN mkdir -p /opt/llama     && cp -a llama.cpp/build/bin/llama-bench llama.cpp/build/bin/llama-cli           llama.cpp/build/bin/llama-server /opt/llama/     && cp -a llama.cpp/build/bin/*.so* /opt/llama/

FROM  AS runtime
LABEL org.opencontainers.image.source=https://github.com/ggml-org/llama.cpp       org.opencontainers.image.description=llama.cpp + ggml-rocket NPU backend for RK3588       org.opencontainers.image.licenses=GPL-3.0-or-later
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends       libdrm2 libcurl4 libgomp1 ca-certificates python3 curl     && rm -rf /var/lib/apt/lists/*
COPY --from=build /opt/llama/ /opt/llama/
COPY --from=build /opt/rocket/libggml-rocket.so /opt/rocket/libggml-rocket.so
COPY bench.sh /opt/bench/bench.sh
RUN chmod +x /opt/bench/bench.sh
ENV PATH=/opt/llama:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin     LD_LIBRARY_PATH=/opt/llama     ROCKET_BACKEND=/opt/rocket/libggml-rocket.so     LLAMA_CACHE=/models
WORKDIR /models
CMD [llama-bench, --help]
