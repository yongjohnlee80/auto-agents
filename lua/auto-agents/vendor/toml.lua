---Minimal TOML codec for auto-agents config files.
---
---Supports the subset we actually use:
---  * `[section]`            table headers
---  * `[[array]]`            array-of-tables headers
---  * `key = "string"`       basic strings (single line, \n \t \r \\ \" escapes)
---  * `key = 42` / `3.14`    numbers
---  * `key = true|false`     booleans
---  * `key = ["a", "b"]`     arrays of strings/ints
---  * `# comment` / blank    ignored
---
---NOT supported: dotted keys, inline tables, multi-line strings, datetime,
---hex/octal/bin literals. We control both producer and consumer (the
---plugin reads/writes its own files), so the constrained subset is
---sufficient — and a 200-line audit beats vendoring a 600-line library
---we don't fully understand.
---@module 'auto-agents.vendor.toml'

local M = {}

-- ── parse ──────────────────────────────────────────────────────────────────

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function unescape_string(s)
  return (s:gsub("\\(.)", function(c)
    if c == "n" then return "\n" end
    if c == "t" then return "\t" end
    if c == "r" then return "\r" end
    if c == '"' then return '"' end
    if c == "\\" then return "\\" end
    return c
  end))
end

local function strip_inline_comment(s)
  -- Strip `# …` only when not inside a "...".
  local out, in_str, esc = {}, false, false
  for i = 1, #s do
    local c = s:sub(i, i)
    if esc then
      out[#out + 1] = c
      esc = false
    elseif in_str and c == "\\" then
      out[#out + 1] = c
      esc = true
    elseif c == '"' then
      in_str = not in_str
      out[#out + 1] = c
    elseif c == "#" and not in_str then
      break
    else
      out[#out + 1] = c
    end
  end
  return trim(table.concat(out))
end

local parse_value  -- forward

local function parse_array(body)
  -- Split top-level commas, respecting strings.
  local items, cur, in_str, esc = {}, {}, false, false
  for i = 1, #body do
    local c = body:sub(i, i)
    if esc then
      cur[#cur + 1] = c
      esc = false
    elseif in_str and c == "\\" then
      cur[#cur + 1] = c
      esc = true
    elseif c == '"' then
      in_str = not in_str
      cur[#cur + 1] = c
    elseif c == "," and not in_str then
      table.insert(items, trim(table.concat(cur)))
      cur = {}
    else
      cur[#cur + 1] = c
    end
  end
  local last = trim(table.concat(cur))
  if last ~= "" then table.insert(items, last) end
  local out = {}
  for _, it in ipairs(items) do
    table.insert(out, parse_value(it))
  end
  return out
end

parse_value = function(v)
  v = trim(v)
  if v == "" then error("toml: empty value") end
  if v:sub(1, 1) == '"' and v:sub(-1) == '"' then
    return unescape_string(v:sub(2, -2))
  end
  if v == "true" then return true end
  if v == "false" then return false end
  if v:sub(1, 1) == "[" and v:sub(-1) == "]" then
    return parse_array(v:sub(2, -2))
  end
  local n = tonumber(v)
  if n then return n end
  error("toml: cannot parse value: " .. v)
end

---@param text string
---@return table
function M.decode(text)
  local result = {}
  local cur = result
  for raw_line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local line = strip_inline_comment(raw_line)
    if line ~= "" then
      if line:sub(1, 2) == "[[" and line:sub(-2) == "]]" then
        local name = trim(line:sub(3, -3))
        result[name] = result[name] or {}
        local entry = {}
        table.insert(result[name], entry)
        cur = entry
      elseif line:sub(1, 1) == "[" and line:sub(-1) == "]" then
        local name = trim(line:sub(2, -2))
        result[name] = result[name] or {}
        cur = result[name]
      else
        local k, v = line:match("^([%w_%-]+)%s*=%s*(.+)$")
        if not k then error("toml: cannot parse line: " .. raw_line) end
        cur[k] = parse_value(v)
      end
    end
  end
  return result
end

-- ── encode ─────────────────────────────────────────────────────────────────

local function encode_string(s)
  s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\t", "\\t"):gsub("\r", "\\r")
  return '"' .. s .. '"'
end

local function encode_value(v)
  local t = type(v)
  if t == "string" then return encode_string(v) end
  if t == "number" then
    if v == math.floor(v) and math.abs(v) < 1e15 then return tostring(math.floor(v)) end
    return tostring(v)
  end
  if t == "boolean" then return tostring(v) end
  if t == "table" then
    local parts = {}
    for _, item in ipairs(v) do parts[#parts + 1] = encode_value(item) end
    return "[" .. table.concat(parts, ", ") .. "]"
  end
  error("toml: cannot encode value of type " .. t)
end

local function is_array(t)
  if type(t) ~= "table" then return false end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n > 0 and n == #t
end

local function sorted_keys(t, order)
  local keys, seen = {}, {}
  if order then
    for _, k in ipairs(order) do
      if t[k] ~= nil then keys[#keys + 1] = k; seen[k] = true end
    end
  end
  local rest = {}
  for k in pairs(t) do
    if not seen[k] then rest[#rest + 1] = k end
  end
  table.sort(rest)
  for _, k in ipairs(rest) do keys[#keys + 1] = k end
  return keys
end

---@param data table
---@param opts? { section_order?: string[], key_order?: table<string,string[]> }
---@return string
function M.encode(data, opts)
  opts = opts or {}
  local out = {}

  local function emit_section(name, tbl)
    if next(tbl) == nil then return end
    out[#out + 1] = "[" .. name .. "]"
    for _, k in ipairs(sorted_keys(tbl, opts.key_order and opts.key_order[name])) do
      out[#out + 1] = k .. " = " .. encode_value(tbl[k])
    end
    out[#out + 1] = ""
  end

  local function emit_array_section(name, list)
    for _, entry in ipairs(list) do
      out[#out + 1] = "[[" .. name .. "]]"
      for _, k in ipairs(sorted_keys(entry, opts.key_order and opts.key_order[name])) do
        out[#out + 1] = k .. " = " .. encode_value(entry[k])
      end
      out[#out + 1] = ""
    end
  end

  local emitted = {}
  for _, name in ipairs(opts.section_order or {}) do
    local v = data[name]
    if type(v) == "table" then
      if is_array(v) then emit_array_section(name, v) else emit_section(name, v) end
      emitted[name] = true
    end
  end
  local rest = {}
  for k in pairs(data) do if not emitted[k] then rest[#rest + 1] = k end end
  table.sort(rest)
  for _, name in ipairs(rest) do
    local v = data[name]
    if type(v) == "table" then
      if is_array(v) then emit_array_section(name, v) else emit_section(name, v) end
    end
  end

  return table.concat(out, "\n")
end

return M
