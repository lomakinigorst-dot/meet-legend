#!/usr/bin/env python3
"""OpenAI-compatible local bridge to Claude Code OAuth.

Hermes can call OpenAI-compatible custom providers. Claude Code OAuth is not
that API, so this local-only proxy adapts `/v1/chat/completions` requests to
the official `claude -p` CLI that uses Igor's Claude Code authorization.
"""

from __future__ import annotations

import json
import os
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


HOST = os.environ.get("CLAUDE_CODE_PROXY_HOST", "127.0.0.1")
PORT = int(os.environ.get("CLAUDE_CODE_PROXY_PORT", "8787"))
MODEL_ID = os.environ.get("CLAUDE_CODE_PROXY_MODEL", "claude-code-sonnet")
CLAUDE_MODEL = os.environ.get("CLAUDE_CODE_MODEL", "sonnet")
HERMES_ENV = Path(os.environ.get("HERMES_ENV_FILE", "/root/.hermes/.env"))
WORKSPACE = Path(os.environ.get("KLEO_WORKSPACE", "/opt/kleo/obsidian-vault"))
TIMEOUT = int(os.environ.get("CLAUDE_CODE_PROXY_TIMEOUT", "360"))
# Каждый запрос поднимает отдельный процесс claude (Node, сотни МБ RSS).
# Без ограничения пять активных топиков = пять-семь процессов разом и OOM на VPS.
MAX_CONCURRENCY = int(os.environ.get("CLAUDE_CODE_PROXY_MAX_CONCURRENCY", "2"))
QUEUE_WAIT = int(os.environ.get("CLAUDE_CODE_PROXY_QUEUE_WAIT", "90"))
# Мост к модели, а не второй агент: инструменты и доступ к vault по умолчанию выключены.
# Включать только осознанно — это возвращает многоходовые сессии и минуты на ответ.
AGENTIC = os.environ.get("CLAUDE_CODE_PROXY_AGENTIC", "0").strip().lower() in {"1", "true", "yes"}
MAX_TURNS = os.environ.get("CLAUDE_CODE_PROXY_MAX_TURNS", "12" if AGENTIC else "1")

_claude_slots = threading.BoundedSemaphore(max(1, MAX_CONCURRENCY))
KLEO_SYSTEM_PROMPT = os.environ.get(
    "CLAUDE_CODE_SYSTEM_PROMPT",
    "Ты отвечаешь только обычным текстом. У тебя нет инструментов, файловой "
    "системы и терминала — не пытайся их вызывать и не эмулируй вызовы функций. "
    "Строго следуй роли, личности и контексту, заданным в сообщениях. "
    "Язык ответа — русский, если явно не сказано иное.",
)


def load_env_file() -> dict[str, str]:
    values: dict[str, str] = {}
    if not HERMES_ENV.exists():
        return values
    for raw in HERMES_ENV.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip("\"'")
    return values


def text_from_content(content: Any) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        chunks: list[str] = []
        for part in content:
            if isinstance(part, dict):
                if part.get("type") in {"text", "input_text"}:
                    chunks.append(str(part.get("text", "")))
                elif "text" in part:
                    chunks.append(str(part.get("text", "")))
            else:
                chunks.append(str(part))
        return "\n".join(chunk for chunk in chunks if chunk)
    return str(content)


MAX_PROMPT_CHARS = int(os.environ.get("CLAUDE_CODE_PROXY_MAX_CHARS", "160000"))
HEAD_KEEP = 3  # системная часть и начало роли


def messages_to_prompt(messages: list[dict[str, Any]]) -> str:
    parts: list[str] = []
    for message in messages:
        role = str(message.get("role", "user")).strip() or "user"
        content = text_from_content(message.get("content")).strip()
        if not content:
            continue
        parts.append(f"## {role}\n{content}")

    prompt = "\n\n".join(parts).strip()
    if len(prompt) <= MAX_PROMPT_CHARS or len(parts) <= HEAD_KEEP + 1:
        return prompt

    # Тред разросся. Оставляем начало (роль, инструкции) и хвост (свежий разговор),
    # середину выбрасываем с явной пометкой — молча терять контекст хуже.
    head, tail = parts[:HEAD_KEEP], []
    budget = MAX_PROMPT_CHARS - sum(len(p) for p in head) - 200
    for part in reversed(parts[HEAD_KEEP:]):
        if budget - len(part) < 0:
            break
        tail.append(part)
        budget -= len(part)
    tail.reverse()
    dropped = len(parts) - len(head) - len(tail)
    if dropped <= 0:
        return prompt
    note = f"## system\n[пропущено {dropped} сообщений из середины переписки — тред слишком длинный]"
    return "\n\n".join(head + [note] + tail).strip()


def error_status(text: str, returncode: int) -> int:
    lower = text.lower()
    if "weekly limit" in lower or "rate limit" in lower or "too many requests" in lower:
        return 429
    if "oauth" in lower or "unauthorized" in lower or "invalid api key" in lower:
        return 401
    if returncode == 124:
        return 504
    return 502


class Handler(BaseHTTPRequestHandler):
    server_version = "kleo-claude-code-proxy/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def send_json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_sse_completion(self, response_id: str, created: int, output: str, model_id: str = MODEL_ID) -> None:
        def event(payload: dict[str, Any]) -> bytes:
            data = json.dumps(payload, ensure_ascii=False)
            return f"data: {data}\n\n".encode("utf-8")

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        role_chunk = {
            "id": response_id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model_id,
            "choices": [{"index": 0, "delta": {"role": "assistant"}, "finish_reason": None}],
        }
        content_chunk = {
            "id": response_id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model_id,
            "choices": [{"index": 0, "delta": {"content": output}, "finish_reason": None}],
        }
        final_chunk = {
            "id": response_id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model_id,
            "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
        }
        self.wfile.write(event(role_chunk))
        if output:
            self.wfile.write(event(content_chunk))
        self.wfile.write(event(final_chunk))
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.close_connection = True

    def authorized(self) -> bool:
        expected = load_env_file().get("CLAUDE_CODE_PROXY_KEY", os.environ.get("CLAUDE_CODE_PROXY_KEY", ""))
        if not expected:
            return True
        return self.headers.get("Authorization", "") == f"Bearer {expected}"

    def do_GET(self) -> None:
        if self.path.rstrip("/") == "/healthz":
            self.send_json(
                200,
                {
                    "ok": True,
                    "model": MODEL_ID,
                    "agentic": AGENTIC,
                    "max_concurrency": MAX_CONCURRENCY,
                    "free_slots": _claude_slots._value,
                },
            )
            return
        if self.path.rstrip("/") == "/v1/models":
            self.send_json(
                200,
                {
                    "object": "list",
                    "data": [
                        {
                            "id": MODEL_ID,
                            "object": "model",
                            "created": 0,
                            "owned_by": "claude-code-oauth",
                        }
                    ],
                },
            )
            return
        self.send_json(404, {"error": {"message": "not found"}})

    def do_POST(self) -> None:
        if not self.authorized():
            self.send_json(401, {"error": {"message": "unauthorized", "type": "auth_error"}})
            return
        if self.path.rstrip("/") != "/v1/chat/completions":
            self.send_json(404, {"error": {"message": "not found"}})
            return

        length = int(self.headers.get("Content-Length", "0") or "0")
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError as exc:
            self.send_json(400, {"error": {"message": f"invalid JSON: {exc}", "type": "bad_request"}})
            return

        prompt = messages_to_prompt(payload.get("messages") or [])
        if not prompt:
            self.send_json(400, {"error": {"message": "empty prompt", "type": "bad_request"}})
            return

        # ---- KLEO-fix 2026-08-20: уважать запрошенную модель ----
        # Прокси раньше жёстко гнал sonnet (CLAUDE_MODEL из env) и игнорировал
        # model из запроса. Игорь использует подписку Claude Code $200 и хочет,
        # чтобы запрос opus реально шёл в claude CLI как --model opus.
        _MODEL_MAP = {
            "claude-code-opus": "opus",
            "claude-code-sonnet": "sonnet",
            "claude-code-sonnet-4.6": "sonnet",
            "opus": "opus",
            "sonnet": "sonnet",
        }
        _req_model = str(payload.get("model", "") or "").strip()
        _cli_model = _MODEL_MAP.get(_req_model) or (CLAUDE_MODEL or "sonnet")
        _resp_model = "claude-code-" + _cli_model
        # ---- /KLEO-fix ----

        env = os.environ.copy()
        env.update(load_env_file())
        if not env.get("CLAUDE_CODE_OAUTH_TOKEN"):
            self.send_json(401, {"error": {"message": "CLAUDE_CODE_OAUTH_TOKEN is not configured", "type": "auth_error"}})
            return

        # Прокси — мост к модели, а не второй агент. Раньше здесь поднимался
        # полноценный Claude Code с доступом к vault (--add-dir) и правом ходить
        # по инструментам до 12 ходов: каждый ответ в чате занимал минуты, и при
        # пяти активных топиках сервер держал семь процессов claude разом.
        # Читать vault умеет сам КЛЕО в Hermes — своими инструментами.
        cmd = ["claude", "-p", "--model", _cli_model]
        if AGENTIC:
            cmd += [
                "--add-dir",
                str(WORKSPACE),
                "--allowedTools",
                "Read",
                "Grep",
                "Glob",
                "--disallowedTools",
                "Bash",
                "Write",
                "Edit",
            ]
        cmd += [
            "--max-turns",
            MAX_TURNS,
            "--permission-mode",
            "default",
            "--output-format",
            "text",
        ]
        if not _claude_slots.acquire(timeout=QUEUE_WAIT):
            self.send_json(
                503,
                {"error": {"message": "Claude Code proxy is busy, try again", "type": "overloaded"}},
            )
            return
        try:
            proc = subprocess.run(
                cmd,
                cwd=str(WORKSPACE),
                env=env,
                input=prompt,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=TIMEOUT,
            )
        except subprocess.TimeoutExpired:
            self.send_json(504, {"error": {"message": "Claude Code CLI timed out", "type": "timeout"}})
            return
        finally:
            _claude_slots.release()

        output = (proc.stdout or "").strip()
        stderr = (proc.stderr or "").strip()
        if proc.returncode != 0:
            raw = "\n".join(part for part in (output, stderr) if part).strip() or "Claude Code CLI failed"
            lower_raw = raw.lower()
            if "weekly limit" in lower_raw or "rate limit" in lower_raw or "too many requests" in lower_raw:
                message = (
                    "⚠️ Достигнут недельный лимит Claude (подписка Claude Code).\n\n"
                    "КЛЕО временно работает без основного мозга.\n\n"
                    "Что делать:\n"
                    "• Написать /model deepseek — переключиться на DeepSeek (хуже по качеству, но работает)\n"
                    "• Или подождать сброса лимита (обычно в понедельник UTC)"
                )
            else:
                message = raw
            self.send_json(error_status(raw, proc.returncode), {"error": {"message": message, "type": "claude_code_error"}})
            return

        response_id = f"chatcmpl-{uuid.uuid4().hex}"
        created = int(time.time())
        if payload.get("stream"):
            self.send_sse_completion(response_id, created, output, _resp_model)
            return

        response = {
            "id": response_id,
            "object": "chat.completion",
            "created": created,
            "model": _resp_model,
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": output},
                    "finish_reason": "stop",
                }
            ],
            "usage": {
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "total_tokens": 0,
            },
        }
        self.send_json(200, response)


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Claude Code proxy listening on http://{HOST}:{PORT}/v1", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
