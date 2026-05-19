---auto-agents.runtime_identity — sidecar identity file plumbing for
---ADR 0023 (resumed-agent identity reconciliation).
---
---The agent process's `AUTO_AGENTS_*` env vars are baked at fork
---time and don't refresh on `claude --resume` / Codex / Gemini
---transcript-restore. A sidecar JSON file on disk becomes the
---post-spawn source of truth: spawn writes it; `refresh_agent_id`
---rewrites it; the bootstrap doc instructs every agent to read it
---over env.
---
---File location: `$AUTO_AGENTS_RUNTIME_IDENTITY_PATH` if set,
---otherwise `<stdpath('data')>/auto-agents/runtime-identity-<slot>.json`
---(typically resolves to
---`~/.local/share/nvim/auto-agents/runtime-identity-<slot>.json`).
---
---ADR 0023 §3.1 specifies the shape; this module owns the
---read/write/path-resolve plumbing. Spawn (`auto-agents/init.lua`)
---and `refresh_agent_id` (`auto-agents/mailbox/commands.lua`) both
---call into here.
---
---@module 'auto-agents.runtime_identity'

local M = {}

---Resolve the on-disk sidecar identity path for a slot. Honors the
---`AUTO_AGENTS_RUNTIME_IDENTITY_PATH` env override (used by tests +
---the spawn loop when the host wants to direct the agent at a
---specific path); falls back to a stable per-slot path under nvim's
---data dir.
---@param slot integer
---@return string
function M.path_for(slot)
  local override = vim.env.AUTO_AGENTS_RUNTIME_IDENTITY_PATH
  if type(override) == "string" and override ~= "" then
    return override
  end
  local dir = vim.fn.stdpath("data") .. "/auto-agents"
  vim.fn.mkdir(dir, "p")
  return dir .. "/runtime-identity-" .. tostring(slot) .. ".json"
end

---Build the canonical identity record for a slot. Reads live state
---from auto-core (current `instance_id`) + auto-agents (the slot's
---agent name + PID). Returns nil + reason if any piece is missing.
---@param slot integer
---@param agent_name string
---@param tool_root string
---@param mailbox_dir string?     -- the agent's mailbox dir on disk; resolved if nil
---@param stamped_by string       -- "auto-agents.spawn" | "auto-agents.refresh_agent_id" | …
---@param agent_pid integer?
---@param diff_review boolean?    -- v0.2.26: per-agent diff_review flag — direct
---                                --   gate for the mailbox `diff_queue` protocol.
---                                --   Survives env-clobber via the sidecar.
---@return table
function M.build_record(slot, agent_name, tool_root, mailbox_dir,
                        stamped_by, agent_pid, diff_review)
  local core = require("auto-core")
  local mb_path = require("auto-core.mailbox.path")
  local instance_id = core.mailbox.get_instance_id()
  local bare = "agent:" .. agent_name
  local full = mb_path.full_id(bare)
  return {
    instance_id           = instance_id,
    mailbox_id            = full,
    bare_id               = bare,
    mailbox_dir           = mailbox_dir or (tool_root .. "/" .. full),
    mailbox_bootstrap_doc = tool_root .. "/bootstrap-mailbox.md",
    tool_root             = tool_root,
    host_pid              = vim.fn.getpid(),
    agent_pid             = agent_pid,
    slot                  = slot,
    agent_name            = agent_name,
    diff_review           = diff_review == true,
    stamped_at            = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    stamped_by            = stamped_by,
  }
end

---Atomic write — temp file + rename. Idempotent overwrite of any
---existing sidecar at `path`. Returns `ok, err`.
---@param path string
---@param record table
---@return boolean, string?
function M.write(path, record)
  local encoded = vim.fn.json_encode(record)
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    local mk = vim.fn.mkdir(dir, "p")
    if mk == 0 then
      return false, "mkdir failed: " .. dir
    end
  end
  local tmp = path .. ".tmp." .. tostring(vim.fn.getpid()) .. "." .. tostring(os.time())
  local f, ferr = io.open(tmp, "w")
  if not f then
    return false, "open " .. tmp .. " failed: " .. tostring(ferr)
  end
  local ok_write, werr = pcall(function() f:write(encoded) end)
  f:close()
  if not ok_write then
    pcall(os.remove, tmp)
    return false, "write failed: " .. tostring(werr)
  end
  local ok_rename, rerr = os.rename(tmp, path)
  if not ok_rename then
    pcall(os.remove, tmp)
    return false, "rename failed: " .. tostring(rerr)
  end
  return true, nil
end

---Read the sidecar identity record from disk. Returns nil if the
---file doesn't exist or the JSON is malformed. Agents are
---instructed to fall back to env vars when this returns nil.
---@param path string
---@return table?, string?
function M.read(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil, "not_readable: " .. path
  end
  local f, ferr = io.open(path, "r")
  if not f then return nil, "open_failed: " .. tostring(ferr) end
  local content = f:read("*a")
  f:close()
  if not content or content == "" then
    return nil, "empty"
  end
  local ok, decoded = pcall(vim.fn.json_decode, content)
  if not ok or type(decoded) ~= "table" then
    return nil, "json_decode_failed"
  end
  return decoded, nil
end

return M
