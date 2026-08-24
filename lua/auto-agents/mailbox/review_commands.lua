---auto-agents.mailbox.review_commands — the `review.*` mailbox surface
---(ADR-0067 A3).
---
---Gives agents the same write path a human gets from the diff view, so both
---produce the same artifact through the same validator. Thin wrappers over
---`worktree.review`; the `review.` namespace groups them in `commands_list`
---beside `todos.*`.
---
---Verb roster (4):
---
---  review.create    write a Markdown-paired review as the next revision
---  review.list      revisions recorded for (repo, commit)
---  review.show      one review by (repo, commit, revision)
---  review.validate  dry-run a payload WITHOUT writing
---
---**`review.create` takes Markdown CONTENT, never a path.** It cannot take a
---path: the document's filename embeds the revision, and the revision is not
---known until `save_pair` wins its reservation, so any path a caller supplied
---would be a guess. The verb passes the content and receives back the paths
---actually written.
---
---**There is deliberately no `review.add_comment`.** A written review is
---immutable — review-json §3 says a re-review is a new revision, never an edit
---— so a whole review arrives in one call.
---
---**`review.validate` exists so a bad payload is diagnosed without spending a
---revision number.** Reserving one and failing retires it permanently
---(ADR-0067 §2.1), which is cheap but not free.
---@module 'auto-agents.mailbox.review_commands'

local M = {}

local _registered = {}

local function ok_response(value) return { ok = true, value = value } end
local function err_response(code, message)
  return { ok = false, error = message, code = code }
end

---Deferred + soft, matching the todos surface: the module must load cleanly
---even when worktree is absent at startup.
local function review_or_err()
  local ok, mod = pcall(require, "worktree.review")
  if not ok or type(mod) ~= "table" then
    return nil, err_response("dependency_unavailable",
      "worktree.review is not available")
  end
  return mod
end

---_slug resolves the caller's repo argument to a store slug.
---
---Accepts a slug directly or a filesystem path, because an agent knows where a
---repo IS more reliably than what its slug is — the slug is derived from the
---`origin` remote and is not something a caller should have to reproduce.
---@param arg string
---@return string? slug, table? errenv
local function resolve_slug(arg)
  if type(arg) ~= "string" or arg == "" then
    return nil, err_response("invalid_args", "args.repo must be a slug or a path")
  end
  if not arg:find("/") then return arg, nil end
  local ok, store = pcall(require, "worktree.store")
  if not ok then
    return nil, err_response("dependency_unavailable", "worktree.store is not available")
  end
  -- A path that does not exist is REFUSED rather than resolved.
  --
  -- `remote_slug` never fails: with no `origin` it keys off the containing
  -- directory name, so a typo'd path yields a perfectly well-formed slug for a
  -- store that has nothing in it. The agent then gets `count = 0` and reads it
  -- as "no reviews yet" instead of "you named a directory that isn't there".
  -- Silently answering the wrong question is worse than declining.
  if vim.fn.isdirectory(arg) == 0 then
    return nil, err_response("invalid_args",
      "no such directory: " .. arg .. " — pass an existing repo path, or the "
      .. "slug directly if the repo is not on this machine")
  end
  local okr, slug = pcall(store.remote_slug, arg)
  if okr and type(slug) == "string" and slug ~= "" then return slug, nil end
  return nil, err_response("invalid_args",
    "could not resolve a slug for " .. arg .. " — pass the slug directly")
end

local function h_create(args)
  local review, errenv = review_or_err(); if not review then return errenv end
  local slug, serr = resolve_slug(args.repo); if not slug then return serr end

  if type(args.commit) ~= "string" then
    return err_response("invalid_args", "args.commit must be a 40-char sha")
  end
  if type(args.markdown) ~= "string" or vim.trim(args.markdown) == "" then
    return err_response("invalid_args",
      "args.markdown must be the review's primary document CONTENT — this verb "
      .. "does not take a path, because the filename embeds a revision that is "
      .. "not known until the write wins its reservation")
  end
  local reviewer = args.reviewer
  if type(reviewer) ~= "string" or reviewer == "" then
    return err_response("invalid_args", "args.reviewer required — it selects the "
      .. "document's directory, and guessing one is worse than declining")
  end

  -- The slug is a PATH SEGMENT and must not be able to escape the store.
  local rslug = reviewer:lower():gsub("[^a-z0-9_-]+", "-"):gsub("%-+", "-")
    :gsub("^%-", ""):gsub("%-$", "")
  if rslug == "" then
    return err_response("invalid_args",
      "args.reviewer produced no safe path segment")
  end

  local kb = vim.env.AUTO_AGENTS_KB_ROOT
  if type(kb) ~= "string" or kb == "" then
    return err_response("dependency_unavailable",
      "cannot resolve $KB_ROOT for the review document")
  end

  local doc = review.new({
    slug = slug, url = args.url, owner = args.owner, name = args.name,
    commit = args.commit, base = args.base, reviewer = reviewer,
    verdict = args.verdict, summary = args.summary,
  })
  doc.reviewer_slug = rslug
  doc.comments = args.comments or {}

  local topic = tostring(args.topic or "review")
    :lower():gsub("[^a-z0-9_-]+", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
  if topic == "" then topic = "review" end
  local date = os.date("!%Y-%m-%d")

  local res, err = review.save_pair(slug, doc, function(rev)
    local dir = ("%s/agents/%s/reviews"):format(kb, rslug)
    return args.markdown,
      ("%s/%s-%s-r%d-review.md"):format(dir, date, topic, rev)
  end)
  if not res then return err_response("internal_error", tostring(err)) end
  return ok_response({
    json_path = res.json_path, md_path = res.md_path, revision = res.revision,
  })
end

local function h_list(args)
  local review, errenv = review_or_err(); if not review then return errenv end
  local slug, serr = resolve_slug(args.repo); if not slug then return serr end
  if type(args.commit) ~= "string" then
    return err_response("invalid_args", "args.commit required")
  end
  local ok, list = pcall(review.list_for, slug, args.commit)
  if not ok then return err_response("internal_error", tostring(list)) end
  return ok_response({ count = #list, revisions = list })
end

local function h_show(args)
  local review, errenv = review_or_err(); if not review then return errenv end
  local slug, serr = resolve_slug(args.repo); if not slug then return serr end
  if type(args.commit) ~= "string" then
    return err_response("invalid_args", "args.commit required")
  end
  local rev = tonumber(args.revision)
  if not rev then return err_response("invalid_args", "args.revision required") end
  local ok, doc, lerr = pcall(review.load, slug, args.commit, rev)
  if not ok then return err_response("internal_error", tostring(doc)) end
  if lerr then return err_response("invalid_args", tostring(lerr)) end
  if not doc then return err_response("not_found", "no such revision") end
  return ok_response(doc)
end

local function h_validate(args)
  local review, errenv = review_or_err(); if not review then return errenv end
  local payload = args.review
  if type(payload) ~= "table" then
    return err_response("invalid_args", "args.review must be the payload table")
  end
  -- `for_write` deliberately: a caller asking "would this be accepted?" means
  -- accepted by a WRITE, and reads are the tolerant path.
  local ok, problems = review.validate(payload, { for_write = true })
  return ok_response({ ok = ok, problems = problems })
end

local SPECS = {
  ["review.create"] = {
    owner       = "auto-agents",
    description = "Write a review as the next revision, PAIRED with its primary Markdown. `markdown` is the document's CONTENT, not a path — the filename embeds a revision that is not known until the write wins its reservation. Returns `{json_path, md_path, revision}`.",
    schema      = { repo = "string", commit = "string", markdown = "string",
                    reviewer = "string", topic = "string?", verdict = "string?",
                    summary = "string?", comments = "table?", base = "string?",
                    url = "string?", owner = "string?", name = "string?" },
    handler     = h_create,
  },
  ["review.list"] = {
    owner       = "auto-agents",
    description = "List the revisions recorded for a commit, newest first.",
    schema      = { repo = "string", commit = "string" },
    handler     = h_list,
  },
  ["review.show"] = {
    owner       = "auto-agents",
    description = "Fetch one review by (repo, commit, revision).",
    schema      = { repo = "string", commit = "string", revision = "number" },
    handler     = h_show,
  },
  ["review.validate"] = {
    owner       = "auto-agents",
    description = "Dry-run a review payload against the schema WITHOUT writing, so a bad payload is diagnosed without spending a revision number.",
    schema      = { review = "table" },
    handler     = h_validate,
  },
}

---register_all mirrors `todos_commands.register_all`.
---@return { registered: string[], skipped: string[] }
function M.register_all()
  local mailbox = require("auto-core").mailbox
  local out = { registered = {}, skipped = {} }
  for name, spec in pairs(SPECS) do
    local ok, regerr = mailbox.commands.register(name, spec)
    if ok then
      _registered[name] = true
      out.registered[#out.registered + 1] = name
    else
      out.skipped[#out.skipped + 1] = name
      require("auto-agents.log").warn("mailbox.commands",
        string.format("register('%s') failed: %s", name, tostring(regerr)))
    end
  end
  table.sort(out.registered)
  table.sort(out.skipped)
  return out
end

---VERBS is the roster, for tests and for documentation.
M.VERBS = { "review.create", "review.list", "review.show", "review.validate" }

return M
