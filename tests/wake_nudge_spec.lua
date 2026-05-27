--- Tests for the default wake nudge text (fix/wake-codex-popup-submit).
--- Run with: nvim --headless -u NONE -l tests/wake_nudge_spec.lua
---
--- Regression guard: a `wake` to a codex-backed slot submits with a bare
--- `<CR>` (no `Esc`, which would cancel in-flight generation). If the nudge
--- text contains a codex composer-completion trigger — a `$VAR`/`/` path
--- token, an `@` mention, or a leading `/` slash-command — codex opens a
--- fuzzy-completion popup and the bare `<CR>` is swallowed by it instead of
--- submitting the message. Observed live via `peek` on slot 2 (Codex): the
--- old default ended in `$AUTO_AGENTS_MAILBOX_DIR/inbox/` and the nudge sat
--- unsent under a "no matches / Press enter to insert or esc to close" popup.
--- These tests assert the EFFECT we care about: the nudge text is popup-inert.

-- Find our own path to derive project roots
local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")

for _, p in ipairs({ project_root }) do
  if vim.fn.isdirectory(p) == 1 then
    vim.opt.runtimepath:prepend(p)
  end
end

local commands = require("auto-agents.mailbox.commands")

local pass_count = 0
local fail_count = 0
local function ok(name, cond, detail)
  if cond then
    pass_count = pass_count + 1
    print(string.format("  PASS  %s", name))
  else
    fail_count = fail_count + 1
    print(string.format("  FAIL  %s  %s", name, tostring(detail or "")))
  end
end

print("\n[1] default_wake_nudge — popup-inert text (fix/wake-codex-popup-submit)")

-- Exercise both arrival kinds the router fires with.
for _, case in ipairs({
  { kind = "inbox",     origin = "nvim" },
  { kind = "responses", origin = "agent:juliet" },
}) do
  local text = commands.default_wake_nudge(case.kind, case.origin)
  local label = string.format("(%s from %s) ", case.kind, case.origin)

  ok(label .. "returns a non-empty string",
    type(text) == "string" and #text > 0, text)

  -- The original popup trigger — must be gone.
  ok(label .. "contains no $AUTO_AGENTS_MAILBOX_DIR path token",
    not text:find("$AUTO_AGENTS_MAILBOX_DIR", 1, true), text)

  -- Generalize the guard to every known codex composer-completion trigger.
  ok(label .. "contains no `$` env-var token",
    not text:find("%$"), text)
  ok(label .. "contains no `/` path separator / slash token",
    not text:find("/"), text)
  ok(label .. "contains no `@` mention token",
    not text:find("@"), text)

  -- Leading `[` is the other codex composer hazard (bracketed/queued entry).
  ok(label .. "does not start with `[`",
    text:sub(1, 1) ~= "[", text)

  -- Still informative: names the arrival kind and the origin.
  ok(label .. "mentions the arrival kind",
    text:find(case.kind, 1, true) ~= nil, text)
  ok(label .. "mentions the origin",
    text:find(case.origin, 1, true) ~= nil, text)
end

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)