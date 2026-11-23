-- Busted loads this file in the test process.
return function(options)
  local busted = require "busted"
  local handler = require("busted.outputHandlers.base")()
  local json = require "dkjson"
  local cwd = require("lfs").currentdir()
  local open = io.open
  local token = options.arguments[1]
  assert(token and #token % 2 == 0 and token:match("^%x+$"), "Invalid test report path")
  local path = token:gsub("%x%x", function(hex) return string.char(tonumber(hex, 16)) end)
  local request = assert(open(path, "rb"))
  local contents = request:read("*a")
  request:close()
  local settings = assert(json.decode(contents))

  if settings.names then
    local group
    -- Track the current describe block through Busted's public events.
    busted.subscribe({"describe", "start"}, function(element)
      group = element
      return nil, true
    end)
    busted.subscribe({"describe", "end"}, function(_, parent)
      group = parent
      return nil, true
    end)
    local function include(name)
      local parts, parent = {name}, group
      while parent and parent.descriptor ~= "file" and (parent.name or parent.descriptor) do
        table.insert(parts, 1, parent.name or parent.descriptor)
        parent = busted.parent(parent)
      end
      return nil, settings.names[table.concat(parts, " ")] == true
    end
    busted.subscribe({"register", "it"}, function(name) return include(name or "it") end, {priority = 1})
    busted.subscribe({"register", "pending"}, function(name) return include(name or "pending") end, {priority = 1})
  end

  local function location(trace)
    if trace and type(trace.source) == "string" and trace.source:sub(1, 1) == "@" then
      return trace.source:sub(2), trace.currentline
    end
  end

  busted.subscribe({"suite", "end"}, function()
    local rows = {}
    local function append(entries, status)
      for _, entry in ipairs(entries) do
        local element = entry.element
        local file, line = location(entry.trace)
        local definitionFile, definitionLine = location(element.trace)
        if element.descriptor == "file" and not file then
          file = element.name
          line = type(entry.message) == "string" and tonumber(entry.message:match("^[^\r\n]-:(%d+):")) or nil
        end
        rows[#rows + 1] = {status = status, name = entry.name, message = entry.message,
          file = file, line = line, definitionFile = definitionFile, definitionLine = definitionLine,
          test = element.descriptor == "it"}
      end
    end
    append(handler.failures, "failed")
    append(handler.errors, "error")
    append(handler.successes, "passed")
    append(handler.pendings, "pending")
    local report = assert(open(path..".results", "ab"))
    assert(report:write(json.encode({cwd = cwd, rows = rows}), "\n"))
    assert(report:close())
    return nil, true
  end)

  return handler
end
