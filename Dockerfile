# syntax=docker/dockerfile:1.7

ARG CUDA_VERSION=12.8.1
ARG UBUNTU_VERSION=24.04

FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS build

ARG DEBIAN_FRONTEND=noninteractive
ARG LLAMA_CPP_REPO=https://github.com/ggml-org/llama.cpp.git
ARG LLAMA_CPP_REF=b820cc8e6f94843d32f92c8ebd7db837dae2bd8b
ARG CUDA_ARCHITECTURES=86
ARG CMAKE_BUILD_TYPE=Release

ENV CUDA_COMPAT_LIBDIR=/usr/local/cuda/compat \
    CUDA_STUBS_LIBDIR=/usr/local/cuda/targets/x86_64-linux/lib/stubs \
    LIBRARY_PATH=/usr/local/cuda/compat:/usr/local/cuda/targets/x86_64-linux/lib/stubs:${LIBRARY_PATH}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        ccache \
        cmake \
        curl \
        git \
        libcurl4-openssl-dev \
        libssl-dev \
        ninja-build \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN git clone --filter=blob:none "${LLAMA_CPP_REPO}" llama.cpp \
    && cd llama.cpp \
    && git checkout "${LLAMA_CPP_REF}"

RUN cmake -S /src/llama.cpp -B /src/llama.cpp/build \
        -G Ninja \
        -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE}" \
        -DGGML_CUDA=ON \
        -DLLAMA_CURL=ON \
        -DLLAMA_OPENSSL=ON \
        -DLLAMA_BUILD_TESTS=OFF \
        -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES}" \
        -DCMAKE_EXE_LINKER_FLAGS="-Wl,-rpath-link,${CUDA_COMPAT_LIBDIR} -L${CUDA_COMPAT_LIBDIR} -L${CUDA_STUBS_LIBDIR}" \
        -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-rpath-link,${CUDA_COMPAT_LIBDIR} -L${CUDA_COMPAT_LIBDIR} -L${CUDA_STUBS_LIBDIR}" \
    && cmake --build /src/llama.cpp/build --target llama-server llama-cli -j"$(nproc)"

FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION}

LABEL org.opencontainers.image.title="Helm's Host"

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libgomp1 \
        libcurl4 \
        libssl3t64 \
        tini \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/llama.cpp/build/bin/ /usr/local/bin/
COPY --from=build /src/llama.cpp/LICENSE /licenses/llama.cpp/LICENSE

ENV HOME=/models/.home \
    LLAMA_CACHE=/models/cache \
    HF_HOME=/models/.home/huggingface \
    LD_LIBRARY_PATH=/usr/local/bin:${LD_LIBRARY_PATH} \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    NVIDIA_VISIBLE_DEVICES=all

WORKDIR /models
EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--", "llama-server"]
CMD ["--help"]
