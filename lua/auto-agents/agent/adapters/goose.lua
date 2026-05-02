---Goose CLI adapter (D3, M3).
---
---Upstream docs: https://goose-docs.ai/
---Quickstart:    https://goose-docs.ai/docs/quickstart
---Env vars:      https://goose-docs.ai/docs/guides/environment-variables
---
---Default invocation is `goose session` — drops into an interactive TUI.
---Goose's canonical model selection is via `goose configure` (writes
---`~/.config/goose/config.yaml`), but env vars take precedence and are
---the cleanest per-spawn override:
---
---  - GOOSE_MODEL          — model id (e.g. `claude-sonnet-4-5`,
---                            `llama3.1`, plain names — no namespacing)
---  - GOOSE_PROVIDER       — provider name (`anthropic`, `ollama`,
---                            `openai`, `openrouter`, etc.)
---  - GOOSE_PROVIDER__HOST — base URL override; for ollama, e.g.
---                            `http://192.168.1.10:11434`. Defaults to
---                            `localhost:11434` when omitted.
---
---Goose auto-loads `AGENTS.md` from cwd by default (alongside
---`.goosehints`), so kb/instruct.lua's existing AGENTS.md write is
---picked up without any extra adapter wiring.
---
---@module 'auto-agents.agent.adapters.goose'

local M = {}

---@param spec table  -- bootstrap entry: { slot, kind, name, ..., cmd?, model?, provider?, api_base? }
---@return string[]
function M.cmd(spec)
  if spec and spec.cmd then return spec.cmd end
  return { "goose", "session" }
end

---@param spec table
---@return table<string,string>
function M.env(spec)
  local env = {}
  if not spec then return env end
  if spec.model    and spec.model    ~= "" then env.GOOSE_MODEL          = spec.model    end
  if spec.provider and spec.provider ~= "" then env.GOOSE_PROVIDER       = spec.provider end
  if spec.api_base and spec.api_base ~= "" then env.GOOSE_PROVIDER__HOST = spec.api_base end
  return env
end

return M