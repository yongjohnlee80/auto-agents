#!/usr/bin/env python3
"""
Submit a proposed full-file edit to auto-agents.nvim's diff queue.

Agent contract:
  - Use this helper instead of writing files directly when
    AUTO_AGENTS_DIFF_REVIEW=true and your native CLI/tooling does not
    already call the IDE openDiff tool.
  - Write the complete proposed file contents to a temporary file.
  - Run:
        auto-agents-open-diff.py --file <target> --new-file <proposal>
  - Wait for the command to finish. It blocks until the user accepts,
    denies, requests changes, or the optional timeout expires.
  - On "accepted", this helper writes the accepted content to <target>
    unless --no-write is passed.
  - On "rejected", do not write the file. Read the JSON "reason". If
    the user included review comments or requested changes, revise the
    proposal and submit a new diff through this helper.
  - The helper sends a best-effort close_tab cleanup for its tab name on
    exit so hidden/abandoned queue entries are cleared.

Runtime configuration is read from the agent environment:
  - AUTO_AGENTS_MCP_URL or AUTO_AGENTS_MCP_PORT
  - CODEX_CODE_IDE_AUTHORIZATION / CODEX_CODE_AUTH_TOKEN /
    CODEX_CODE_IDE_AUTH_TOKEN / AUTO_AGENTS_MCP_AUTH_TOKEN
  - AUTO_AGENTS_AGENT_NAME (optional default for --agent)
"""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import socket
import struct
import sys
import time
from urllib.parse import urlparse


PROTOCOL_VERSION = "2024-11-05"


def _env_first(*names: str) -> str | None:
    for name in names:
        value = os.environ.get(name)
        if value:
            return value
    return None


def _bridge_host_port() -> tuple[str, int]:
    url = os.environ.get("AUTO_AGENTS_MCP_URL")
    if url:
        parsed = urlparse(url)
        if parsed.hostname and parsed.port:
            return parsed.hostname, parsed.port

    port = os.environ.get("AUTO_AGENTS_MCP_PORT") or os.environ.get("CODEX_CODE_SSE_PORT")
    if not port:
        raise RuntimeError("AUTO_AGENTS_MCP_URL or AUTO_AGENTS_MCP_PORT is required")
    return "127.0.0.1", int(port)


def _auth_token() -> str:
    token = _env_first(
        "AUTO_AGENTS_MCP_AUTH_TOKEN",
        "CODEX_CODE_IDE_AUTHORIZATION",
        "CODEX_CODE_AUTH_TOKEN",
        "CODEX_CODE_IDE_AUTH_TOKEN",
        "CLAUDE_CODE_IDE_AUTHORIZATION",
    )
    if not token:
        raise RuntimeError("diff bridge auth token is not available in the environment")
    return token


def _send_frame(sock: socket.socket, text: str) -> None:
    payload = text.encode("utf-8")
    length = len(payload)
    if length < 126:
        header = bytes([0x81, 0x80 | length])
    elif length < 65536:
        header = bytes([0x81, 0x80 | 126]) + struct.pack("!H", length)
    else:
        header = bytes([0x81, 0x80 | 127]) + struct.pack("!Q", length)
    mask = os.urandom(4)
    masked = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
    sock.sendall(header + mask + masked)


def _send_control(sock: socket.socket, opcode: int, payload: bytes = b"") -> None:
    if len(payload) > 125:
        payload = payload[:125]
    mask = os.urandom(4)
    masked = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
    sock.sendall(bytes([0x80 | opcode, 0x80 | len(payload)]) + mask + masked)


def _recv_exact(sock: socket.socket, length: int) -> bytes:
    chunks: list[bytes] = []
    remaining = length
    while remaining:
        chunk = sock.recv(remaining)
        if not chunk:
            raise EOFError("socket closed")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _recv_text(sock: socket.socket) -> str:
    while True:
        first, second = _recv_exact(sock, 2)
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", _recv_exact(sock, 2))[0]
        elif length == 127:
            length = struct.unpack("!Q", _recv_exact(sock, 8))[0]

        mask = _recv_exact(sock, 4) if masked else b""
        payload = _recv_exact(sock, length) if length else b""
        if masked:
            payload = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))

        if opcode == 0x1:
            return payload.decode("utf-8")
        if opcode == 0x8:
            raise EOFError("websocket closed")
        if opcode == 0x9:
            _send_control(sock, 0xA, payload)


def _connect(timeout: float | None) -> socket.socket:
    host, port = _bridge_host_port()
    token = _auth_token()
    sock = socket.create_connection((host, port), timeout=timeout)
    sock.settimeout(timeout)

    key = base64.b64encode(os.urandom(16)).decode("ascii")
    request = "\r\n".join(
        [
            "GET /websocket HTTP/1.1",
            f"Host: {host}:{port}",
            "Upgrade: websocket",
            "Connection: Upgrade",
            f"Sec-WebSocket-Key: {key}",
            "Sec-WebSocket-Version: 13",
            f"x-codex-code-ide-authorization: {token}",
            "",
            "",
        ]
    )
    sock.sendall(request.encode("ascii"))

    response = b""
    while b"\r\n\r\n" not in response:
        chunk = sock.recv(4096)
        if not chunk:
            raise EOFError("handshake failed: socket closed")
        response += chunk
    if b"101 Switching Protocols" not in response:
        raise RuntimeError(response.decode("utf-8", "replace"))

    return sock


def _request(sock: socket.socket, request_id: int, method: str, params: dict) -> dict:
    _send_frame(
        sock,
        json.dumps(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "method": method,
                "params": params,
            }
        ),
    )
    while True:
        message = json.loads(_recv_text(sock))
        if message.get("id") == request_id:
            return message


def _notify(sock: socket.socket, method: str, params: dict | None = None) -> None:
    _send_frame(
        sock,
        json.dumps(
            {
                "jsonrpc": "2.0",
                "method": method,
                "params": params or {},
            }
        ),
    )


def _content_text(result: dict, index: int) -> str | None:
    content = result.get("content")
    if not isinstance(content, list) or index >= len(content):
        return None
    item = content[index]
    if not isinstance(item, dict):
        return None
    text = item.get("text")
    return text if isinstance(text, str) else None


def submit(args: argparse.Namespace) -> dict:
    target = Path(args.file).expanduser().resolve()
    proposal = Path(args.new_file).expanduser().resolve()
    new_contents = proposal.read_text(encoding=args.encoding)
    tab_name = args.tab_name or f"{args.agent} {target.name}"

    timeout = args.timeout if args.timeout and args.timeout > 0 else None
    deadline = (time.monotonic() + timeout) if timeout else None

    sock = _connect(timeout)
    close_sent = False

    def close_tab() -> None:
        nonlocal close_sent
        if close_sent:
            return
        close_sent = True
        try:
            _send_frame(
                sock,
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": 99,
                        "method": "tools/call",
                        "params": {
                            "name": "close_tab",
                            "arguments": {"tab_name": tab_name},
                        },
                    }
                ),
            )
        except OSError:
            pass

    try:
      init = _request(
          sock,
          1,
          "initialize",
          {
              "protocolVersion": PROTOCOL_VERSION,
              "capabilities": {},
              "clientInfo": {
                  "name": "auto-agents-open-diff",
                  "version": "0.1.0",
              },
          },
      )
      if "error" in init:
          return {"status": "error", "error": init["error"]}

      _notify(sock, "notifications/initialized")
      _send_frame(
          sock,
          json.dumps(
              {
                  "jsonrpc": "2.0",
                  "id": 2,
                  "method": "tools/call",
                  "params": {
                      "name": "openDiff",
                      "arguments": {
                          "old_file_path": str(target),
                          "new_file_path": str(target),
                          "new_file_contents": new_contents,
                          "tab_name": tab_name,
                          "_auto_agents_name": args.agent,
                      },
                  },
              }
          ),
      )

      while True:
          if deadline:
              remaining = deadline - time.monotonic()
              if remaining <= 0:
                  close_tab()
                  return {"status": "timeout", "file_path": str(target)}
              sock.settimeout(remaining)

          message = json.loads(_recv_text(sock))
          if message.get("id") != 2:
              continue
          if "error" in message:
              return {"status": "error", "error": message["error"], "file_path": str(target)}

          result = message.get("result") or {}
          marker = _content_text(result, 0)
          if marker == "FILE_SAVED":
              close_tab()
              accepted = _content_text(result, 1)
              if accepted is None:
                  accepted = new_contents
              wrote = False
              if not args.no_write:
                  target.parent.mkdir(parents=True, exist_ok=True)
                  target.write_text(accepted, encoding=args.encoding)
                  wrote = True
              return {
                  "status": "accepted",
                  "action": "written" if wrote else "accepted",
                  "file_path": str(target),
                  "wrote": wrote,
              }
          if marker == "DIFF_REJECTED":
              close_tab()
              reason = _content_text(result, 1) or "User rejected the diff."
              return {
                  "status": "rejected",
                  "action": "revise",
                  "file_path": str(target),
                  "reason": reason,
                  "comment": reason,
              }
          close_tab()
          return {"status": "error", "file_path": str(target), "error": result}
    finally:
        close_tab()
        sock.close()


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", required=True, help="target file path")
    parser.add_argument("--new-file", required=True, help="file containing the complete proposed contents")
    parser.add_argument(
        "--agent",
        default=os.environ.get("AUTO_AGENTS_AGENT_NAME") or "agent",
        help="agent name shown in the diff queue",
    )
    parser.add_argument("--tab-name", default=None, help="optional diff tab/queue name")
    parser.add_argument("--timeout", type=float, default=0, help="seconds to wait; 0 waits forever")
    parser.add_argument("--encoding", default="utf-8", help="file encoding for proposal and accepted write")
    parser.add_argument("--no-write", action="store_true", help="return accepted content status without writing target")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    try:
        result = submit(args)
    except Exception as exc:  # noqa: BLE001 - command-line helper must serialize failures.
        result = {"status": "error", "error": str(exc)}

    print(json.dumps(result, ensure_ascii=False))
    return 0 if result.get("status") in {"accepted", "rejected"} else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
