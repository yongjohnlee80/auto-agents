---Type definitions for auto-agents.nvim. Loaded for lua-language-server only;
---this module does not export runtime values.
---@module 'auto-agents.types'

---@alias AutoAgentsLogLevel "error"|"warn"|"info"|"debug"|"trace"
---@alias AutoAgentsAgentKind "claude"|"codex"|"gemini"|"junie"|"aider"|"goose"|"opencode"|"copilot"|"generic"
---@alias AutoAgentsKbScope "shared"|"private"|"isolated"
---@alias AutoAgentsSlotRail "winbar"|"vertical"|"off"
---@alias AutoAgentsSplitSide "left"|"right"
---@alias AutoAgentsAgentState "idle"|"running"|"exited"|"errored"

---@class AutoAgentsPanelConfig
---@field side AutoAgentsSplitSide
---@field min_width integer
---@field max_width integer
---@field percentage number
---@field editor_floor integer
---@field slot_rail AutoAgentsSlotRail

---@class AutoAgentsAgentsConfig
---@field default_kind AutoAgentsAgentKind
---@field primary_kind AutoAgentsAgentKind
---@field bootstrap table[]  -- list of bootstrap entries

---@class AutoAgentsKbConfig
---@field default_scope AutoAgentsKbScope

---@class AutoAgentsTerminalConfig
---@field provider "auto"|"snacks"|"native"|"none"
---@field cwd string|nil
---@field cwd_provider (fun(ctx: AutoAgentsCwdContext): string|nil)|nil
---@field git_repo_cwd boolean

---@class AutoAgentsCwdContext
---@field cwd string|nil
---@field file_dir string|nil

---@class AutoAgentsTerminalSpec
---@field cmd string|string[]                       -- argv for termopen
---@field cwd string|nil
---@field env table<string,string>|nil
---@field on_exit (fun(exit_code: integer))|nil
---@field kind AutoAgentsAgentKind|nil              -- metadata: agent kind for float title
---@field name string|nil                            -- metadata: handle for float title
---@field title string|nil                           -- metadata: display label for float title

---@class AutoAgentsTerminalInstance
---@field bufnr integer|nil
---@field jobid integer|nil
---@field state AutoAgentsAgentState
---@field exit_code integer|nil
---@field start fun(self: AutoAgentsTerminalInstance, winid: integer|nil): integer|nil
---@field resize_to fun(self: AutoAgentsTerminalInstance, winid: integer)
---@field send fun(self: AutoAgentsTerminalInstance, text: string): boolean
---@field kill fun(self: AutoAgentsTerminalInstance, signal: string|nil)
---@field is_alive fun(self: AutoAgentsTerminalInstance): boolean
---@field get_bufnr fun(self: AutoAgentsTerminalInstance): integer|nil
---@field get_jobid fun(self: AutoAgentsTerminalInstance): integer|nil

---@class AutoAgentsTerminalProvider
---@field new fun(spec: AutoAgentsTerminalSpec): AutoAgentsTerminalInstance

---@class AutoAgentsConfig
---@field log_level AutoAgentsLogLevel
---@field panel AutoAgentsPanelConfig
---@field agents AutoAgentsAgentsConfig
---@field kb AutoAgentsKbConfig
---@field terminal AutoAgentsTerminalConfig

---@class AutoAgent
---@field id string
---@field slot integer|nil
---@field name string
---@field title string|nil
---@field kind AutoAgentsAgentKind
---@field role string|nil
---@field memory_path string|nil
---@field tasks string[]
---@field cmd string[]
---@field cwd string|nil
---@field allowed_paths string[]
---@field kb_scope AutoAgentsKbScope|nil
---@field env table<string,string>
---@field manager_id string|nil
---@field bufnr integer|nil
---@field jobid integer|nil
---@field state AutoAgentsAgentState
---@field started_at integer|nil
---@field exit_code integer|nil

return {}
