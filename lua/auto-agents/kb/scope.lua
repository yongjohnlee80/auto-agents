---Per-agent KB scope resolution (D16). Maps an agent's `kb_scope` to
---the env vars `AUTO_AGENTS_KB_WRITE` (single dir) and
---`AUTO_AGENTS_KB_READ` (colon-separated dirs) that get injected at
---spawn. Agents are trusted to honor these — best-effort coordination,
---not OS-level sandboxing (see D6).
---
---  shared    R: kb/shared + kb/agents/* ;  W: kb/shared        (default)
---  private   R: kb/shared + kb/agents/<name> ; W: kb/agents/<name>
---  isolated  R: kb/agents/<name> ;        W: kb/agents/<name>
---
---@module 'auto-agents.kb.scope'

local M = {}

---@param spec table  -- { name?, slot, kb_scope? }
---@return string
local function agent_dir_name(spec)
  if spec.name and spec.name ~= "" then return spec.name end
  return "agent" .. tostring(spec.slot or "")
end

---Compute env vars for a slot's KB access. Side-effect: ensures the
---per-agent dir exists if scope is private/isolated.
---@param spec table  -- bootstrap entry-shaped
---@param kb_root string
---@return table<string,string> env  -- AUTO_AGENTS_KB_WRITE / AUTO_AGENTS_KB_READ / AUTO_AGENTS_KB_ROOT
function M.env_for(spec, kb_root)
  local scope = spec.kb_scope or "shared"
  local shared = kb_root .. "/shared"
  local agents_dir = kb_root .. "/agents"
  local agent_name = agent_dir_name(spec)
  local private = agents_dir .. "/" .. agent_name

  if scope == "private" or scope == "isolated" then
    vim.fn.mkdir(private, "p")
  end

  if scope == "shared" then
    return {
      AUTO_AGENTS_KB_ROOT  = kb_root,
      AUTO_AGENTS_KB_WRITE = shared,
      AUTO_AGENTS_KB_READ  = shared .. ":" .. agents_dir,
      AUTO_AGENTS_KB_SCOPE = "shared",
    }
  elseif scope == "private" then
    return {
      AUTO_AGENTS_KB_ROOT  = kb_root,
      AUTO_AGENTS_KB_WRITE = private,
      AUTO_AGENTS_KB_READ  = shared .. ":" .. private,
      AUTO_AGENTS_KB_SCOPE = "private",
    }
  elseif scope == "isolated" then
    return {
      AUTO_AGENTS_KB_ROOT  = kb_root,
      AUTO_AGENTS_KB_WRITE = private,
      AUTO_AGENTS_KB_READ  = private,
      AUTO_AGENTS_KB_SCOPE = "isolated",
    }
  end
  -- Unknown scope — be safe: no KB access.
  return {}
end

return M
