# ==================================================
# Stage 1: Build the vLLM CPU wheel
# ==================================================
FROM rayproject/ray:2.49.0-py311 AS builder

USER root

# Install the C/C++ toolchain and system libraries needed to compile vLLM.
# gcc-12/g++-12 are set as the default compilers via update-alternatives,
# because vLLM's CPU build expects a recent GCC.
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc-12 \
    g++-12 \
    libnuma-dev \
    git \
    ninja-build \
    && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 10 \
    && update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-12 10 \
    && rm -rf /var/lib/apt/lists/*

# Install a recent cmake from pip.
# The apt version (3.22) is too old; vLLM requires cmake >= 3.26.
RUN python -m pip install --no-cache-dir "cmake>=3.26.1" ninja

# vLLM version (git tag) to build
ARG VLLM_REF=v0.10.2

# Clone only the requested tag to keep the image layer small
RUN git clone --depth 1 --branch "${VLLM_REF}" \
    https://github.com/vllm-project/vllm /tmp/vllm

WORKDIR /tmp/vllm

# Install build-time dependencies.
# They must be installed manually because we build with --no-build-isolation.
RUN python -m pip install --no-cache-dir \
    -r requirements/build.txt \
    --extra-index-url https://download.pytorch.org/whl/cpu

# Install vLLM CPU dependencies (CPU-only PyTorch, etc.)
RUN python -m pip install --no-cache-dir \
    -r requirements/cpu.txt \
    --extra-index-url https://download.pytorch.org/whl/cpu

# Build the vLLM wheel for CPU and save it to /wheels
RUN mkdir -p /wheels && \
    VLLM_TARGET_DEVICE=cpu \
    python -m pip wheel -v . \
    --no-build-isolation \
    --no-deps \
    -w /wheels


# ==================================================
# Stage 2: Download the model from Hugging Face
# ==================================================
FROM python:3.11-slim AS model

# Download the model once at build time so the runtime image works offline
RUN pip install --no-cache-dir huggingface_hub \
    && python -c "from huggingface_hub import snapshot_download; snapshot_download('Qwen/Qwen2.5-0.5B-Instruct', local_dir='/models/qwen')"

# ==================================================
# Stage 3: Runtime image
# ==================================================
FROM rayproject/ray:2.49.0-py311

USER root

# Runtime-only system library required by vLLM CPU kernels
RUN apt-get update && apt-get install -y --no-install-recommends \
    libnuma1 \
    && rm -rf /var/lib/apt/lists/*

# Copy the whole requirements directory from the builder stage.
# cpu.txt includes "-r common.txt", so copying only cpu.txt is not enough.
COPY --from=builder /tmp/vllm/requirements /tmp/vllm-requirements
COPY --from=builder /wheels /tmp/wheels

# Install vLLM runtime dependencies first, then the vLLM wheel itself
RUN python -m pip install --no-cache-dir \
    -r /tmp/vllm-requirements/cpu.txt \
    --extra-index-url https://download.pytorch.org/whl/cpu \
    && python -m pip install --no-cache-dir --no-deps /tmp/wheels/vllm-*.whl \
    && rm -rf /tmp/wheels /tmp/vllm-requirements

# Install application dependencies (and Ray Serve)
COPY requirements.txt /tmp/requirements.txt

RUN python -m pip install --no-cache-dir \
    -r /tmp/requirements.txt \
    "ray[serve]==2.49.0"

# Create app and model directories owned by the non-root "ray" user
RUN mkdir -p /home/ray/app /home/ray/models \
    && chown -R ray:users /home/ray/app /home/ray/models

# Copy the downloaded model and the application code
COPY --from=model --chown=ray:users /models/qwen /home/ray/models/qwen
COPY --chown=ray:users serve_app.py /home/ray/app/serve_app.py

# Runtime configuration:
# - PYTHONPATH: lets Python import serve_app
# - MODEL_PATH: local path of the model
# - HF_HUB_OFFLINE: never try to download from Hugging Face at runtime
# - VLLM_CPU_KVCACHE_SPACE: KV cache size in GiB
ENV PYTHONPATH=/home/ray/app \
    MODEL_PATH=/home/ray/models/qwen \
    HF_HUB_OFFLINE=1 \
    VLLM_CPU_KVCACHE_SPACE=2

WORKDIR /home/ray/app

# Run as the non-root user for safety
USER ray