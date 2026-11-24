local json = require "dkjson"
local lsp = {null = json.null}
local maxHeader, maxBody = 8192, 32 * 1024 * 1024

function lsp.object()
  return setmetatable({}, {__jsontype = "object"})
end

function lsp.frame(message)
  local body = json.encode(message)
  return ("Content-Length: %d\r\n\r\n%s"):format(#body, body)
end

function lsp.writer(write)
  local pending, first, offset = {}, 1, 1
  local function flush()
    local budget = 64 * 1024
    while first <= #pending and budget > 0 do
      local data = pending[first]
      local chunk = data:sub(offset, offset + math.min(budget, 16 * 1024) - 1)
      local count = write(chunk)
      if count == 0 then return end
      offset, budget = offset + count, budget - count
      if offset > #data then
        pending[first], first, offset = false, first + 1, 1
      end
    end
    if first > #pending then pending, first = {}, 1 end
  end
  local function queue(data)
    pending[#pending + 1] = data
    if first == #pending then flush() end
  end
  return queue, flush
end

function lsp.decoder(onMessage)
  local header, remaining, parts = "", nil, nil
  return function(data)
    while #data > 0 do
      if not remaining then
        local block = header .. data
        local first, last = block:find("\r\n\r\n", 1, true)
        if not first then
          if #block > maxHeader then return nil, "LSP message header is too large." end
          header = block
          break
        end
        if first > maxHeader then return nil, "LSP message header is too large." end
        local length = ("\n"..block:sub(1, first - 1):lower().."\r\n")
          :match("\ncontent%-length:[ \t]*(%d+)[ \t]*\r\n")
        remaining = tonumber(length)
        if not remaining or remaining < 1 or remaining > maxBody then
          return nil, "Invalid LSP content length."
        end
        header, parts, data = "", {}, block:sub(last + 1)
      end

      local count = math.min(remaining, #data)
      if count == 0 then break end
      parts[#parts + 1] = data:sub(1, count)
      remaining, data = remaining - count, data:sub(count + 1)
      if remaining == 0 then
        local body = table.concat(parts)
        remaining, parts = nil, nil
        local ok, message, nextpos = pcall(json.decode, body, 1, lsp.null)
        if not ok or type(message) ~= "table" or message.jsonrpc ~= "2.0"
        or body:find("%S", nextpos) then
          return nil, "Invalid LSP message."
        end
        onMessage(message)
      end
    end
    return true
  end
end

function lsp.fileUri(path)
  path = path:gsub("\\", "/"):gsub("[^A-Za-z0-9_.~:/-]", function(byte)
    return ("%%%02X"):format(byte:byte())
  end)
  if path:sub(1, 2) == "//" then return "file:"..path end
  return "file://"..(path:sub(1, 1) == "/" and "" or "/")..path
end

function lsp.filePath(uri, windows)
  if type(uri) ~= "string" then return end
  local host, path = uri:match("^file://([^/]*)(/[^?#]*)$")
  if not path then return end
  path = path:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
  if path:find("[%z\r\n]") then return end
  if host ~= "" and host:lower() ~= "localhost" then
    if windows and host:match("^[%w_.-]+$") then return "//"..host..path end
    return
  end
  if not windows then return path end
  return path:match("^/([A-Za-z]:/.*)$")
end

function lsp.endPosition(text, encoding)
  local line, start = 0, 1
  while true do
    local at = text:find("[\r\n]", start)
    if not at then break end
    line = line + 1
    start = at + (text:sub(at, at + 1) == "\r\n" and 2 or 1)
  end
  local character = #text - start + 1
  if encoding ~= "utf-8" then
    character = 0
    for byte in text:sub(start):gmatch("[^\128-\191]") do
      character = character + (encoding == "utf-16" and byte:byte() >= 240 and 2 or 1)
    end
  end
  return {line = line, character = character}
end

function lsp.validPosition(pos)
  return type(pos) == "table"
    and type(pos.line) == "number" and pos.line >= 0 and pos.line % 1 == 0
    and type(pos.character) == "number" and pos.character >= 0 and pos.character % 1 == 0
end

function lsp.byteOffset(line, character, encoding)
  local offset = 0
  for codepoint in line:gmatch("[^\128-\191][\128-\191]*") do
    local bytes = #codepoint
    local units = encoding == "utf-8" and bytes or encoding == "utf-16" and bytes == 4 and 2 or 1
    if character < units then break end
    offset, character = offset + bytes, character - units
  end
  return offset, character == 0
end

function lsp.textEdits(text, edits, encoding, allowEndPastEOF)
  if type(edits) ~= "table" then return end
  local lines, first = {}, 1
  while true do
    local eol = text:find("[\r\n]", first)
    lines[#lines + 1] = {first, (eol or #text + 1) - 1}
    if not eol then break end
    first = eol + (text:sub(eol, eol + 1) == "\r\n" and 2 or 1)
  end

  local function offset(pos, allowPastEOF)
    if not lsp.validPosition(pos) then return end
    local line = lines[pos.line + 1]
    if not line then
      if allowPastEOF and pos.line == #lines and pos.character == 0 then return #text, lines[#lines] end
      return
    end
    local bytes, exact = lsp.byteOffset(text:sub(line[1], line[2]), pos.character, encoding)
    if exact then return line[1] - 1 + bytes, line end
  end

  local result = {}
  for _, edit in ipairs(edits) do
    if type(edit) ~= "table" or type(edit.range) ~= "table" or type(edit.newText) ~= "string" then return end
    local start, startLine = offset(edit.range.start)
    local finish, endLine = offset(edit.range["end"], allowEndPastEOF)
    if not start or not finish or finish < start then return end
    result[#result + 1] = {start = start, finish = finish, text = edit.newText,
      line = edit.range.start.line, contextStart = startLine[1], contextEnd = endLine[2]}
  end
  for index in pairs(edits) do
    if not result[index] then return end
  end
  table.sort(result, function(a, b) return a.start < b.start end)
  for i = 2, #result do
    local prev, edit = result[i - 1], result[i]
    if edit.start < prev.finish or edit.start == prev.start then return end
  end
  return result
end

local function addFormattingEdits(result, start, before, after)
  if before == after then return end
  if before:gsub("%s", "") ~= after:gsub("%s", "") then
    result[#result + 1] = {start = start, finish = start + #before, text = after}
    return
  end

  -- Keep unchanged code in place so Scintilla can track its carets and line markers.
  local oldPos, newPos = 1, 1
  local oldBoundary, newBoundary = 0, 0
  while oldPos <= #before + 1 do
    local oldCode = before:find("%S", oldPos) or #before + 1
    local newCode = after:find("%S", newPos) or #after + 1
    local oldSpace, newSpace = before:sub(oldPos, oldCode - 1), after:sub(newPos, newCode - 1)
    if oldSpace ~= newSpace then
      local head, tail = 0, 0
      local shared = math.min(#oldSpace, #newSpace)
      while head < shared and oldSpace:byte(head + 1) == newSpace:byte(head + 1) do head = head + 1 end
      while tail < shared - head and oldSpace:byte(-tail - 1) == newSpace:byte(-tail - 1) do tail = tail + 1 end
      result[#result + 1] = {start = start + oldPos - 1 + head, finish = start + oldCode - 1 - tail,
        text = newSpace:sub(head + 1, #newSpace - tail)}
    end
    if oldCode > #before then break end
    if oldBoundary <= oldCode then oldBoundary = before:find("%s", oldCode) or #before + 1 end
    if newBoundary <= newCode then newBoundary = after:find("%s", newCode) or #after + 1 end
    local count = math.min(oldBoundary - oldCode, newBoundary - newCode)
    oldPos, newPos = oldCode + count, newCode + count
  end
end

function lsp.formatEdits(text, edits, encoding, first, last)
  -- LuaLS uses a virtual next line as the end of a range that reaches EOF.
  local ranges = lsp.textEdits(text, edits, encoding, true)
  if not ranges then return end
  local result = {}
  for _, edit in ipairs(ranges) do
    local start, finish, replacement = edit.start, edit.finish, edit.text
    local original = text:sub(start + 1, finish)
    if original ~= replacement then
      if first then
        if finish < first or start > last or start == last and last < #text then return nil, "range" end
        local head, tail = math.max(0, first - start), math.max(0, finish - last)
        if head + tail > math.min(#original, #replacement) or original:sub(1, head) ~= replacement:sub(1, head)
        or tail > 0 and original:sub(-tail) ~= replacement:sub(-tail) then return nil, "range" end
        start, finish = start + head, finish - tail
        original = original:sub(head + 1, #original - tail)
        replacement = replacement:sub(head + 1, #replacement - tail)
        if finish == last and last < #text and not replacement:find("[\r\n]$") then return nil, "range" end
      end
      addFormattingEdits(result, start, original, replacement)
    end
  end
  return result
end

return lsp
