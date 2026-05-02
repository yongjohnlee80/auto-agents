---OpenCode CLI adapter (D3, M3).
---
---Upstream docs:   https://opencode.ai/docs
---Models reference: https://opencode.ai/docs/models
---Config reference: https://opencode.ai/docs/config
---
---Default invocation is bare `opencode` — drops into an interactive TUI.
---The model id format is `<provider>/<model>` (e.g.
---`anthropic/claude-sonnet-4-5`, `ollama/llama3.1`,
---`opencode/gpt-5.1-codex`). When `spec.model` is set, the adapter
---appends `--model <id>` (also accepts `-m`).
---
---OpenCode auto-loads `AGENTS.md` from cwd, so kb/instruct.lua's
---existing AGENTS.md write is picked up without extra adapter wiring.
---
---Local LLM note: OpenCode does NOT expose a CLI flag for a custom
---provider base URL — providers (including ollama / OpenAI-compatible
---endpoints) are configured in `opencode.json` (cwd) or
---`~/.config/opencode/opencode.json` (global). Once a provider is
---defined there, this adapter's `--model <provider>/<id>` selects it.
---No `api_base` field is rendered for opencode in the wizard.
---
---@module 'auto-agents.agent.adapters.opencode'

local M = {}

---@param spec table  -- bootstrap entry: { slot, kind, name, ..., cmd?, model? }
---@return string[]
function M.cmd(spec)
  if spec and spec.cmd then return spec.cmd end
  local argv = { "opencode" }
  if spec and spec.model and spec.model ~= "" then
    argv[#argv + 1] = "--model"
    argv[#argv + 1] = spec.model
  end
  return argv
end

---@param _spec table
---@return table<string,string>
function M.env(_spec)
  return {}
end

return M