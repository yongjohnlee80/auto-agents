---Aider CLI adapter (D3, M3).
---
---Upstream docs: https://aider.chat/docs/usage.html
---Config docs:   https://aider.chat/docs/config/aider_conf.html
---
---Default invocation is plain `aider` from the project root. `--model
---<id>` is canonical for picking a model and gets appended when
---`spec.model` is set. `--api-base <url>` is appended when
---`spec.api_base` is set — required for ollama / lm-studio /
---openrouter / any OpenAI-compatible local server (e.g.
---`aider --model ollama_chat/llama3 --api-base http://192.168.1.10:11434`).
---
---Unlike claude/codex/gemini/junie, aider does **not** auto-load a
---per-cwd markdown instruction file — users normally opt in via
---`read:` in `.aider.conf.yml` or `--read <FILE>` on the CLI. To make
---the auto-agents KB block visible without per-user config changes,
---this adapter appends `--read AGENTS.md` to every launch (the same
---file kb/instruct.lua writes the block into for codex/copilot/generic).
---The flag is additive on top of any existing `.aider.conf.yml`. To
---opt out, set `cmd = ["aider", ...]` explicitly in the spec.
---
---@module 'auto-agents.agent.adapters.aider'

local M = {}

---@param spec table  -- bootstrap entry: { slot, kind, name, title, ..., cmd?, model?, api_base? }
---@return string[]
function M.cmd(spec)
  if spec and spec.cmd then return spec.cmd end
  local argv = { "aider" }
  if spec and spec.model and spec.model ~= "" then
    argv[#argv + 1] = "--model"
    argv[#argv + 1] = spec.model
  end
  if spec and spec.api_base and spec.api_base ~= "" then
    argv[#argv + 1] = "--api-base"
    argv[#argv + 1] = spec.api_base
  end
  -- Auto-load the auto-agents instruction block written into AGENTS.md
  -- by kb/instruct.lua. cwd is set by the spawn path, so the relative
  -- path resolves correctly.
  argv[#argv + 1] = "--read"
  argv[#argv + 1] = "AGENTS.md"
  return argv
end

---@param _spec table
---@return table<string,string>
function M.env(_spec)
  return {}
end

return M
