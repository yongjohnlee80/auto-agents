---Codex CLI adapter (D3, M3).
---@module 'auto-agents.agent.adapters.codex'

local M = {}

---Argv for a codex spawn.
---
---**No `--model` here, deliberately.** Codex rejects the model ids this
---config carries, so passing `spec.model` through broke the spawn instead of
---selecting a model; the flag was dropped rather than normalised, because
---codex resolves its own model perfectly well without us (`/model`
---in-session, `model` in `~/.codex/config.toml`) and
---`auto-agents.status.model_reader` reads the live one back off the TUI for
---the status surface either way. A `model` recorded in the TOML is roster
---metadata for a codex slot, nothing more — `kb/instruct.lua` says so in the
---agent's own instructions.
---
---To pin a model for a codex slot, give it the flag explicitly:
---`cmd = ["codex", "-m", "<id>"]` (an explicit `cmd` is returned verbatim).
---@param spec table  -- bootstrap entry: { slot, kind, name, title, ..., cmd?, model? }
---@return string[]
function M.cmd(spec)
  if spec and spec.cmd then return vim.list_slice(spec.cmd) end
  return { "codex" }
end

---@param _spec table
---@return table<string,string>
function M.env(_spec)
  return {}
end

return M
