---Minimal YAML frontmatter parser. Reads the leading `---`-delimited
---block of a markdown file and returns a flat map.
---
---Supports the constrained subset we use in our seeds:
---  key: "value"            -- string (quotes optional)
---  key: 42                 -- number
---  key: true|false         -- boolean
---  key: [a, b, c]          -- inline list of scalars
---  key:                    -- block list (one item per line, "  - …")
---    - item-a
---    - item-b
---
---Anything else is returned as a raw string (no error).
---@module 'auto-agents.kb.frontmatter'

local M = {}

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function strip_quotes(s)
  if (s:sub(1, 1) == '"' and s:sub(-1) == '"')
      or (s:sub(1, 1) == "'" and s:sub(-1) == "'") then
    return s:sub(2, -2)
  end
  return s
end

local function parse_scalar(s)
  s = trim(s)
  if s == "" then return "" end
  if s == "true"  then return true end
  if s == "false" then return false end
  local n = tonumber(s)
  if n then return n end
  return strip_quotes(s)
end

local function parse_inline_list(s)
  s = trim(s)
  if s == "" then return {} end
  -- Split on commas not inside quotes.
  local items, cur, in_q = {}, {}, nil
  for i = 1, #s do
    local c = s:sub(i, i)
    if in_q then
      if c == in_q then in_q = nil end
      cur[#cur + 1] = c
    elseif c == '"' or c == "'" then
      in_q = c
      cur[#cur + 1] = c
    elseif c == "," then
      items[#items + 1] = trim(table.concat(cur))
      cur = {}
    else
      cur[#cur + 1] = c
    end
  end
  if #cur > 0 then items[#items + 1] = trim(table.concat(cur)) end
  local out = {}
  for _, it in ipairs(items) do out[#out + 1] = parse_scalar(it) end
  return out
end

---Parse a markdown file's frontmatter into a flat lua table.
---Returns an empty table if there's no frontmatter.
---@param content string  -- entire file content
---@return table
function M.parse(content)
  local out = {}
  if content:sub(1, 4) ~= "---\n" and content:sub(1, 5) ~= "---\r\n" then
    return out
  end

  -- Find the closing ---.
  local lines = vim.split(content, "\n", { plain = true })
  if lines[1] ~= "---" then return out end
  local end_idx
  for i = 2, #lines do
    if lines[i] == "---" or lines[i] == "..." then end_idx = i; break end
  end
  if not end_idx then return out end

  local i = 2
  while i < end_idx do
    local line = lines[i]
    if not line:match("^%s*#") and trim(line) ~= "" then
      local key, after = line:match("^([%w_%-]+)%s*:%s*(.*)$")
      if key then
        if after == "" then
          -- block list expected on subsequent lines
          local list = {}
          local j = i + 1
          while j < end_idx do
            local item = lines[j]:match("^%s*%-%s*(.*)$")
            if not item then break end
            list[#list + 1] = parse_scalar(item)
            j = j + 1
          end
          out[key] = list
          i = j - 1
        elseif after:sub(1, 1) == "[" then
          -- inline list
          local inner = after:match("^%[(.*)%]%s*$") or ""
          out[key] = parse_inline_list(inner)
        else
          -- scalar
          out[key] = parse_scalar(after)
        end
      end
    end
    i = i + 1
  end

  return out
end

---Read a file and parse its frontmatter. Returns empty table on error.
---@param path string
---@return table
function M.parse_file(path)
  local f = io.open(path, "r")
  if not f then return {} end
  -- Read at most ~8KB to avoid loading huge markdown files just for FM.
  local content = f:read(8192) or ""
  f:close()
  return M.parse(content)
end

return M
