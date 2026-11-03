#!/usr/bin/env python3
"""A stand-in for Hermes's API server and for an OpenAI-compatible endpoint, for trying Nibble's
real network code without a model or a Hermes gateway.

    python3 -I scripts/mock-backend.py [PORT]        default 8650

Point Nibble's settings at http://127.0.0.1:PORT (Hermes or OpenAI-compatible; any key, any
model). A turn goes: a wait notice, reasoning, a web search, a page read, then the answer, with
usage at the end. A message containing "approve" asks for an approval first (answer it in the
panel); one containing "fail" ends in an error. Standard library only.
"""

import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8650
APPROVALS = {}  # run id -> threading.Event, plus the answer
ANSWERS = {}

ANSWER = """这是本地测试服务器的回答，走的是 Nibble 真正的网络代码。

### 刚才发生了什么

1. 先等了一下（模拟限流重试）
2. 思考，然后**搜索**、**阅读**
3. 最后输出这段文字

```python
print("hello from the mock")
```

| 阶段 | 灯光 |
|---|---|
| 等待 | rings |
| 搜索 | across |
"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("mock: " + (fmt % args) + "\n")

    def _json(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length) or b"{}")

    def do_GET(self):
        path = self.path.split("?")[0]
        if path.endswith("/health"):
            return self._json(200, {"status": "ok"})
        if path.endswith("/v1/capabilities"):
            return self._json(200, {"features": {"session_chat_streaming": True}})
        if path.endswith("/models"):
            return self._json(200, {"object": "list", "data": [{"id": "mock-flash"}, {"id": "mock-pro"}]})
        self._json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        path = self.path.split("?")[0]
        body = self._body()
        if "/v1/runs/" in path and path.endswith("/approval"):
            run = path.split("/v1/runs/")[1].split("/")[0]
            ANSWERS[run] = body.get("choice")
            event = APPROVALS.get(run)
            if event:
                event.set()
            return self._json(200, {"ok": True})
        if path.endswith("/chat/completions"):
            return self._stream(body)
        self._json(404, {"error": {"message": "not found"}})

    # A streamed turn -----------------------------------------------------------------------

    def _send(self, data, event=None):
        frame = (f"event: {event}\n" if event else "") + f"data: {data}\n\n"
        self.wfile.write(frame.encode())
        self.wfile.flush()

    def _chunk(self, run, delta, finish=None, **extra):
        obj = {"id": run, "object": "chat.completion.chunk", "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
        obj.update(extra)
        self._send(json.dumps(obj, ensure_ascii=False))

    def _stream(self, body):
        messages = body.get("messages") or []
        last = messages[-1] if messages else {}
        content = last.get("content")
        text = content if isinstance(content, str) else " ".join(p.get("text", "") for p in content or [] if isinstance(p, dict))
        run = f"chatcmpl-{int(time.time() * 1000)}"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self._chunk(run, {"role": "assistant"})
            self._send(json.dumps({"kind": "lifecycle", "text": "⏳ Provider busy, retrying in 2s"}), "hermes.status")
            time.sleep(2)
            for piece in ["先想一想", "这个问题", "该怎么回答。"]:
                self._chunk(run, {"reasoning_content": piece})
                time.sleep(0.6)
            if "approve" in text:
                event = threading.Event()
                APPROVALS[run] = event
                self._send(json.dumps({"run_id": run, "request_id": "r1", "command": "python3 -m pip install requests",
                                       "choices": ["once", "session", "deny"]}), "approval.request")
                event.wait(300)
                if ANSWERS.get(run) == "deny":
                    self._chunk(run, {"content": "好的，没有运行。"})
                    self._finish(run)
                    return
            self._chunk(run, {"content": "我去查一下。"})
            time.sleep(0.4)
            self._send(json.dumps({"tool": "web_search", "label": "pip install requests", "toolCallId": "t1", "status": "running"}), "hermes.tool.progress")
            time.sleep(2.2)
            self._send(json.dumps({"tool": "web_search", "toolCallId": "t1", "status": "completed"}), "hermes.tool.progress")
            self._send(json.dumps({"tool": "web_extract", "label": "pip.pypa.io", "toolCallId": "t2", "status": "running"}), "hermes.tool.progress")
            time.sleep(2.2)
            self._send(json.dumps({"tool": "web_extract", "toolCallId": "t2", "status": "completed"}), "hermes.tool.progress")
            self._chunk(run, {"reasoning_content": "整理一下。"})
            time.sleep(1)
            if "fail" in text:
                self._chunk(run, {}, "error", error={"message": "模拟的失败：provider returned 503"})
                self._send("[DONE]")
                return
            for i in range(0, len(ANSWER), 2):
                self._chunk(run, {"content": ANSWER[i:i + 2]})
                time.sleep(0.03)
            self._finish(run)
        except (BrokenPipeError, ConnectionResetError):
            sys.stderr.write("mock: client closed the stream (stopped)\n")

    def _finish(self, run):
        self._chunk(run, {}, "stop", usage={"prompt_tokens": 1200, "completion_tokens": 180, "total_tokens": 1380})
        self._send("[DONE]")


if __name__ == "__main__":
    print(f"mock backend on http://127.0.0.1:{PORT}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
