-- Headless tests for auto-agents.mailbox.review_commands (ADR-0067 A3). Run:
--   nvim --headless -u NONE -l tests/review_commands_spec.lua
--
-- The verbs are thin, so the assertions are about the CONTRACT rather than the
-- plumbing: that an agent cannot produce an unpaired review, that a display
-- name cannot become a path segment, and that validate never spends a revision.
local script_path = debug.getinfo(1).source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
local plugins_root = vim.fn.fnamemodify(project_root, ":h:h")

local function pick(rel)
  for _, wt in ipairs({ "/review-authoring", "/main", "" }) do
    local p = plugins_root .. "/" .. rel .. wt
    if vim.fn.isdirectory(p .. "/lua") == 1 then return p end
  end
end
for _, p in ipairs({ project_root, pick("auto-core.nvim"), pick("worktree.nvim") }) do
  if p then
    vim.opt.runtimepath:append(p)
    package.path = p .. "/lua/?.lua;" .. p .. "/lua/?/init.lua;" .. package.path
  end
end

local sb = vim.fn.tempname() .. "-revcmd"
vim.env.XDG_STATE_HOME = sb .. "/state"
vim.env.XDG_CONFIG_HOME = sb .. "/config"
vim.env.XDG_CACHE_HOME = sb .. "/cache"
-- $KB_ROOT isolated: review.create writes a document under it, so an inherited
-- value would write into the real knowledge base.
vim.env.AUTO_AGENTS_KB_ROOT = sb .. "/kb"

local pass, fail = 0, 0
local function ok(n, c, d)
  if c then pass = pass + 1; io.stdout:write("  PASS  " .. n .. "\n")
  else fail = fail + 1; io.stdout:write("  FAIL  " .. n .. "  " .. tostring(d or "") .. "\n") end
  io.stdout:flush()
end

local rc = require("auto-agents.mailbox.review_commands")
local store = require("worktree.store")
local review = require("worktree.review")
store._root_override = sb .. "/wtstore"

-- The handlers are private; drive them the way the mailbox does, through the
-- registered specs, so the schema and the handler are exercised together.
local handlers = {}
do
  local fake = { commands = { register = function(name, spec)
    handlers[name] = spec.handler; return true
  end } }
  -- Require the REAL auto-core first. `package.loaded[...] or {}` created an
  -- empty stub when it had not been loaded yet, which then shadowed the real
  -- module for the rest of the run — `.events` was nil and the event assertion
  -- could not have worked whatever production did.
  local core = require("auto-core")
  local real = core.mailbox
  core.mailbox = fake
  local out = rc.register_all()
  core.mailbox = real
  ok("all four verbs register", #out.registered == 4 and #out.skipped == 0,
    vim.inspect(out))
  ok("and the roster matches what registered",
    #rc.VERBS == 4 and handlers["review.create"] ~= nil, vim.inspect(vim.tbl_keys(handlers)))
end

local SHA = string.rep("e", 40)
local SLUG = "own__repo"

io.stdout:write("\n[1] review.create writes a PAIR\n")
-- Capture the refresh event: an agent's review must reach an OPEN view, or the
-- human sees it only after reopening.
local published = {}
do
  local core = require("auto-core")
  local real = core.events.publish
  core.events.publish = function(topic, payload)
    if topic == "core.review:changed" then published[#published + 1] = payload end
    return real(topic, payload)
  end
end
local created = handlers["review.create"]({
  repo = SLUG, commit = SHA, reviewer = "Lector", topic = "sessions",
  markdown = "# Review\n\nprose the JSON cannot carry",
  verdict = "change_requested", summary = "one must-fix",
  owner = "own", name = "repo",
  comments = { { path = "a.go", line = 3, side = "RIGHT",
                 severity = "must-fix", body = "bad" } },
})
ok("it succeeds", created.ok == true, vim.inspect(created))
ok("returning both paths and the revision",
  created.value and created.value.json_path and created.value.md_path
  and created.value.revision == 1, vim.inspect(created.value))
ok("*** the Markdown it wrote holds the CONTENT the agent supplied ***",
  table.concat(vim.fn.readfile(created.value.md_path), "\n")
    :find("prose the JSON cannot carry", 1, true) ~= nil)
ok("*** and the JSON cross-references it ***",
  (review.load(SLUG, SHA, 1) or {}).document == created.value.md_path)
ok("*** a DISPLAY name became a safe path segment ***",
  created.value.md_path:find("/agents/lector/reviews/", 1, true) ~= nil,
  created.value.md_path)
ok("*** the document name carries the repo component ***",
  created.value.md_path:find("-repo-", 1, true) ~= nil, created.value.md_path)
ok("*** a successful create publishes core.review:changed ***",
  #published == 1 and published[1].revision == 1, vim.inspect(published))

io.stdout:write("\n[1b] the ADVERTISED minimal call works\n")
do
  -- repo/commit/reviewer/markdown only — no url, owner or name. This failed
  -- validation only AFTER reserving a revision and writing a Markdown, because
  -- identity was never derived from the slug.
  local SHA2 = string.rep("b", 40)
  local before = review.max_recorded_revision(SLUG, SHA2)
  local minimal = handlers["review.create"]({
    repo = SLUG, commit = SHA2, reviewer = "Lector", markdown = "# minimal" })
  ok("*** the documented minimal args succeed ***", minimal.ok == true,
    vim.inspect(minimal))
  ok("identity was derived from the slug",
    (review.load(SLUG, SHA2, 1) or {}).repo.owner == "own",
    vim.inspect((review.load(SLUG, SHA2, 1) or {}).repo))
  ok("and it did not burn a revision on the way", before == 0)
end

io.stdout:write("\n[2] an agent cannot produce an UNPAIRED review\n")
do
  local no_md = handlers["review.create"]({
    repo = SLUG, commit = SHA, reviewer = "Lector", comments = {} })
  ok("*** create refuses without markdown content ***", no_md.ok == false, vim.inspect(no_md))
  ok("and says why a path would not do either",
    (no_md.error or ""):find("does not take a path", 1, true) ~= nil, no_md.error)

  local as_path = handlers["review.create"]({
    repo = SLUG, commit = SHA, reviewer = "Lector",
    markdown = "   ", comments = {} })
  ok("whitespace is not content", as_path.ok == false)

  local no_rev = handlers["review.create"]({
    repo = SLUG, commit = SHA, markdown = "# x", comments = {} })
  ok("*** and it refuses without a reviewer rather than guessing a directory ***",
    no_rev.ok == false, vim.inspect(no_rev))

  local unsafe = handlers["review.create"]({
    repo = SLUG, commit = SHA, reviewer = "///", markdown = "# x", comments = {} })
  ok("*** a reviewer name that slugifies to nothing is refused ***",
    unsafe.ok == false, vim.inspect(unsafe))
end

io.stdout:write("\n[3] list / show read what create wrote\n")
do
  local listed = handlers["review.list"]({ repo = SLUG, commit = SHA })
  ok("list returns the revision", listed.ok and listed.value.count == 1,
    vim.inspect(listed.value))
  local shown = handlers["review.show"]({ repo = SLUG, commit = SHA, revision = 1 })
  ok("show returns the full payload", shown.ok and shown.value.commit == SHA)
  ok("including its comment", shown.ok and #shown.value.comments == 1)
  local missing = handlers["review.show"]({ repo = SLUG, commit = SHA, revision = 99 })
  ok("a missing revision is not_found, not a crash",
    missing.ok == false and missing.code == "not_found", vim.inspect(missing))
end

io.stdout:write("\n[4] validate never spends a revision\n")
do
  local before = review.max_recorded_revision(SLUG, SHA)
  local bad = handlers["review.validate"]({ review = { schema = "nope" } })
  ok("validate reports problems rather than failing the call", bad.ok == true
    and bad.value.ok == false and #bad.value.problems > 0, vim.inspect(bad.value))
  ok("*** and consumes NO revision number ***",
    review.max_recorded_revision(SLUG, SHA) == before,
    ("%d -> %d"):format(before, review.max_recorded_revision(SLUG, SHA)))
  local good = handlers["review.validate"]({ review = (function()
    local d = review.new({ slug = SLUG, owner = "own", name = "repo",
                           commit = SHA, reviewer = "lector" })
    d.revision = 7
    d.document = "/x/agents/lector/reviews/2026-08-25-t-r7-review.md"
    d.comments = {}
    return d
  end)() })
  ok("a well-formed payload validates", good.value.ok == true, vim.inspect(good.value))
  ok("*** validate uses the WRITE rules — an unpaired payload fails ***",
    (function()
      local d = review.new({ slug = SLUG, owner = "own", name = "repo",
                             commit = SHA, reviewer = "lector" })
      d.revision = 8; d.comments = {}
      local r = handlers["review.validate"]({ review = d })
      return r.value.ok == false
    end)())
end

io.stdout:write("\n[5] argument errors are envelopes, never crashes\n")
do
  for _, case in ipairs({
    { name = "no repo", args = { commit = SHA } },
    { name = "no commit", args = { repo = SLUG } },
    -- `remote_slug` never fails — with no origin it keys off the directory
    -- name — so a typo'd path would otherwise yield a valid slug for an empty
    -- store and the agent would read `count = 0` as "no reviews yet".
    { name = "nonexistent path", args = { repo = "/nope/not/a/repo", commit = SHA } },
  }) do
    local r = handlers["review.list"](case.args)
    ok(("%s -> a structured refusal"):format(case.name),
      type(r) == "table" and r.ok == false and r.code ~= nil, vim.inspect(r))
  end
  -- ...and the positive control: a REAL directory still resolves, so the
  -- refusal above is about existence and not about rejecting every path.
  local realdir = vim.fn.tempname(); vim.fn.mkdir(realdir, "p")
  local r = handlers["review.list"]({ repo = realdir, commit = SHA })
  ok("an existing directory still resolves to a slug", r.ok == true, vim.inspect(r))
end

io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
