---auto-agents.sanitize: text from outside (a peer's subject, a message's body, an id) made safe to
---type into an agent's terminal: no escape sequence, control or invalid UTF-8 survives, and lengths
---are capped. The fallback (auto-agents.fallback) types every delivery through it.
---
---@module 'auto-agents.sanitize'

local M = {}

M.MAX_TEXT = 80 -- a free-text field's default cap, in characters

---Strip everything a terminal could act on from `s`:
---  * ESC sequences (CSI `ESC [ … final`, OSC/DCS/APC/PM/SOS `ESC ] … BEL|ST`,
---    and any other `ESC x` pair), including the bracketed-paste end marker;
---  * C0 controls (NUL … US, so newline and CR) and DEL;
---  * C1 controls, both as UTF-8 (U+0080 … U+009F) and as raw 8-bit bytes;
---  * any byte that is not part of a valid UTF-8 sequence.
---Removed controls become a space; whitespace then collapses and trims.
---@param s string
---@return string
function M.strip_controls(s)
  s = s:gsub("\27%[[\48-\63]*[\32-\47]*[\64-\126]?", " ")        -- CSI
       :gsub("\27[%]PX%^_][^\7\27]*\7", " ")                          -- OSC … BEL
       :gsub("\27[%]PX%^_][^\7\27]*\27\\", " ")                       -- OSC … ST
       :gsub("\27.?", " ")                                              -- any other ESC
  -- Walk UTF-8: keep valid printable sequences, drop C0/DEL/C1 and junk.
  local out, i, n = {}, 1, #s
  while i <= n do
    local b = s:byte(i)
    local len = (b < 0x80 and 1) or (b >= 0xC2 and b <= 0xDF and 2)
      or (b >= 0xE0 and b <= 0xEF and 3) or (b >= 0xF0 and b <= 0xF4 and 4) or nil
    local ok_seq = len ~= nil and i + len - 1 <= n
    if ok_seq and len > 1 then
      -- RFC 3629: these leads narrow the first continuation byte, which
      -- rejects overlongs (E0, F0), surrogates (ED) and > U+10FFFF (F4).
      local lo = (b == 0xE0 and 0xA0) or (b == 0xF0 and 0x90) or 0x80
      local hi = (b == 0xED and 0x9F) or (b == 0xF4 and 0x8F) or 0xBF
      for k = i + 1, i + len - 1 do
        local c = s:byte(k)
        if c < lo or c > hi then ok_seq = false; break end
        lo, hi = 0x80, 0xBF
      end
    end
    if not ok_seq then
      out[#out + 1] = " "; i = i + 1
    else
      local ch = s:sub(i, i + len - 1)
      local cp1 = ch:byte(2)
      local is_c0 = len == 1 and (b < 0x20 or b == 0x7F)
      local is_c1 = len == 2 and b == 0xC2 and cp1 >= 0x80 and cp1 <= 0x9F
      out[#out + 1] = (is_c0 or is_c1) and " " or ch
      i = i + len
    end
  end
  s = table.concat(out)
  return (s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

---@param s string
---@param max integer
---@return string
local function cap(s, max)
  if vim.fn.strchars(s) > max then
    s = vim.fn.strcharpart(s, 0, max - 1) .. "…"
  end
  return s
end

---Free text (a subject, an error, a message's text): controls stripped, length capped (max, or
---M.MAX_TEXT). Every free-text field typed into a terminal goes through here.
---@param s any
---@param max integer?
---@return string?
function M.sanitize(s, max)
  if type(s) ~= "string" then return nil end
  s = M.strip_controls(s)
  if s == "" then return nil end
  return cap(s, max or M.MAX_TEXT)
end

M.ID_PLACEHOLDER = "(unprintable)"
M.MAX_ID = 64

---An identity-like field from a message or envelope (sender, recipient,
---command, code, failure reason): controls stripped, then accepted only if it
---is made of letters, digits and `:._-@/` and fits `M.MAX_ID`; anything else
---becomes `M.ID_PLACEHOLDER`. nil / empty stays nil.
---@param s any
---@return string?
function M.sanitize_id(s)
  if type(s) ~= "string" or s == "" then return nil end
  local clean = M.strip_controls(s)
  if clean == "" or #clean > M.MAX_ID or not clean:match("^[%w:%._%-@/]+$") then
    return M.ID_PLACEHOLDER
  end
  return clean
end

---A host-built path (the router composes it, but the file name comes from
---whoever wrote the file): controls stripped, generously capped.
---@param s any
---@return string?
function M.sanitize_path(s)
  if type(s) ~= "string" then return nil end
  s = M.strip_controls(s)
  if s == "" then return nil end
  return cap(s, 512)
end

return M
