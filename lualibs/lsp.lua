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

function lsp.byteOffset(line, character, encoding)
  local offset = 0
  for codepoint in line:gmatch("[^\128-\191][\128-\191]*") do
    local bytes = #codepoint
    local units = encoding == "utf-8" and bytes or encoding == "utf-16" and bytes == 4 and 2 or 1
    if character < units then break end
    offset, character = offset + bytes, character - units
  end
  return offset
end

return lsp
