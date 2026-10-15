import os
import time
import uuid

# ============================================================
# Environment configuration (must be set BEFORE any import)
# ============================================================
os.environ["OMP_NUM_THREADS"] = "2"
os.environ["MKL_NUM_THREADS"] = "2"
os.environ["VLLM_CPU_KVCACHE_SPACE"] = "2"

# Force offline mode — the model is already inside the image
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"

# ============================================================
# Imports
# ============================================================
from fastapi import FastAPI
from pydantic import BaseModel, Field
from ray import serve
from transformers import AutoTokenizer
from vllm import AsyncEngineArgs, AsyncLLMEngine, SamplingParams

# ============================================================
# Model configuration
# ============================================================
MODEL_PATH = os.getenv("MODEL_PATH", "/home/ray/models/qwen")
MODEL_NAME = "Qwen/Qwen2.5-0.5B-Instruct"

api = FastAPI()


# ============================================================
# Request schemas
# ============================================================
class GenerateRequest(BaseModel):
    prompt: str
    max_new_tokens: int = Field(64, ge=1, le=64)


class Message(BaseModel):
    role: str
    content: str


class ChatRequest(BaseModel):
    model: str = MODEL_NAME
    messages: list[Message]
    max_tokens: int = 128


# ============================================================
# Ray Serve deployment
# ============================================================
@serve.deployment(
    num_replicas=1,
    ray_actor_options={"num_cpus": 2},
    max_ongoing_requests=4,
    graceful_shutdown_timeout_s=0,
    health_check_period_s=30,
    health_check_timeout_s=30,
)
@serve.ingress(api)
class LLMService:
    def __init__(self):
        # Load tokenizer from local files only (no internet)
        self.tokenizer = AutoTokenizer.from_pretrained(
            MODEL_PATH,
            local_files_only=True,
        )

        # Initialize vLLM engine with memory-friendly settings
        self.engine = AsyncLLMEngine.from_engine_args(
            AsyncEngineArgs(
                model=MODEL_PATH,
                tokenizer=MODEL_PATH,
                dtype="float16",
                swap_space=0,
                enforce_eager=True,
                max_model_len=1024,          
                disable_log_stats=True,
                trust_remote_code=True,
                gpu_memory_utilization=0.1,
                block_size=16,
             )
        )

    async def _generate(self, prompt: str, max_tokens: int):
        params = SamplingParams(max_tokens=max_tokens, temperature=0.7)
        final = None
        async for out in self.engine.generate(prompt, params, uuid.uuid4().hex):
            final = out
        return final.outputs[0]

    @api.post("/generate")
    async def generate(self, req: GenerateRequest):
        result = await self._generate(req.prompt, req.max_new_tokens)
        return {"text": result.text}

    @api.post("/v1/chat/completions")
    async def chat(self, req: ChatRequest):
        prompt = self.tokenizer.apply_chat_template(
            [m.model_dump() for m in req.messages],
            tokenize=False,
            add_generation_prompt=True,
        )
        result = await self._generate(prompt, req.max_tokens)
        return {
            "id": f"chatcmpl-{uuid.uuid4().hex}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": MODEL_NAME,
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": result.text,
                    },
                    "finish_reason": result.finish_reason,
                }
            ],
        }


llm_app = LLMService.bind()