# ==================================================
# Stage 1: Build vLLM for CPU
# ==================================================
FROM rayproject/ray:2.49.0-py311 AS builder

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc-12 \
    g++-12 \
    libnuma-dev \
    git \
    cmake \
    ninja-build \
    && rm -rf /var/lib/apt/lists/*

ARG VLLM_REF=v0.10.2

RUN git clone --depth 1 --branch "${VLLM_REF}" \
    https://github.com/vllm-project/vllm /tmp/vllm

WORKDIR /tmp/vllm

# Install vLLM CPU dependencies
RUN python -m pip install --no-cache-dir \
    -r requirements/cpu.txt \
    --extra-index-url https://download.pytorch.org/whl/cpu

# Install build-time dependencies required by vLLM
RUN python -m pip install --no-cache-dir \
    setuptools-scm

# Build the vLLM CPU wheel
RUN mkdir -p /wheels && \
    VLLM_TARGET_DEVICE=cpu \
    python -m pip wheel -v . \
    --no-build-isolation \
    --no-deps \
    -w /wheels


# ==================================================
# Stage 2: Download the model
# ==================================================
FROM python:3.11-slim AS model

RUN pip install --no-cache-dir huggingface_hub \
    && python -c "from huggingface_hub import snapshot_download; snapshot_download('Qwen/Qwen2.5-0.5B-Instruct', local_dir='/models/qwen')"


# ==================================================
# Stage 3: Runtime image
# ==================================================
FROM rayproject/ray:2.49.0-py311

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    libnuma1 \
    && rm -rf /var/lib/apt/lists/*

# Copy vLLM dependencies and wheel
COPY --from=builder /tmp/vllm/requirements/cpu.txt /tmp/cpu.txt
COPY --from=builder /wheels /tmp/wheels

# Install vLLM and its runtime dependencies
RUN python -m pip install --no-cache-dir \
    -r /tmp/cpu.txt \
    --extra-index-url https://download.pytorch.org/whl/cpu \
    && python -m pip install --no-cache-dir --no-deps /tmp/wheels/vllm-*.whl \
    && rm -rf /tmp/wheels /tmp/cpu.txt

# Install application dependencies
COPY requirements.txt /tmp/requirements.txt

RUN python -m pip install --no-cache-dir \
    -r /tmp/requirements.txt \
    "ray[serve]==2.49.0"

# Copy model and application
RUN mkdir -p /home/ray/app /home/ray/models \
    && chown -R ray:users /home/ray/app /home/ray/models

COPY --from=model --chown=ray:users /models/qwen /home/ray/models/qwen
COPY --chown=ray:users serve_app.py /home/ray/app/serve_app.py

# Runtime configuration
ENV PYTHONPATH=/home/ray/app \
    MODEL_PATH=/home/ray/models/qwen \
    HF_HUB_OFFLINE=1 \
    VLLM_CPU_KVCACHE_SPACE=2

WORKDIR /home/ray/app

USER ray
