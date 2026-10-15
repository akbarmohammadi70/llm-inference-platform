FROM rayproject/ray:2.49.0-py311 AS builder

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc-12 g++-12 libnuma-dev git cmake ninja-build \
 && rm -rf /var/lib/apt/lists/*

ARG VLLM_REF=v0.10.2
RUN git clone --depth 1 --branch ${VLLM_REF} https://github.com/vllm-project/vllm /tmp/vllm
WORKDIR /tmp/vllm
RUN pip install -r requirements/cpu.txt --extra-index-url https://download.pytorch.org/whl/cpu \
 && VLLM_TARGET_DEVICE=cpu pip wheel . --no-build-isolation --no-deps -w /wheels


FROM python:3.11-slim AS model

RUN pip install huggingface_hub
RUN python -c "from huggingface_hub import snapshot_download; \
snapshot_download('Qwen/Qwen2.5-0.5B-Instruct', local_dir='/models/qwen')"


FROM rayproject/ray:2.49.0-py311

USER root
RUN apt-get update && apt-get install -y --no-install-recommends libnuma1 \
 && rm -rf /var/lib/apt/lists/*
USER ray

COPY --from=builder /wheels /tmp/wheels
COPY --from=builder /tmp/vllm/requirements/cpu.txt /tmp/cpu.txt
RUN pip install /tmp/wheels/vllm-*.whl -r /tmp/cpu.txt \
      --extra-index-url https://download.pytorch.org/whl/cpu \
 && pip install "ray[serve]==2.49.0" fastapi pydantic \
 && rm -rf /tmp/wheels /tmp/cpu.txt

COPY --from=model --chown=ray:users /models/qwen /home/ray/models/qwen
COPY --chown=ray:users serve_app.py /home/ray/app/serve_app.py

ENV PYTHONPATH=/home/ray/app \
    MODEL_PATH=/home/ray/models/qwen \
    HF_HUB_OFFLINE=1 \
    VLLM_CPU_KVCACHE_SPACE=2