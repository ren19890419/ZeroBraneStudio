local reporter = assert(loadfile("lualibs/bustedoutput.lua"))()
local json = require "dkjson"
local temporary = wx.wxFile()
local request = wx.wxFileName.CreateTempFileName("zbs-busted-test", temporary)
temporary:Close()
local name = 'group fails [100%] "quoted" & more'
assert(FileWrite(request, json.encode({names = {[name] = true}})))
local output = request..".results"
local events = {}
local file = {descriptor = "file"}
local group = {name = "group", parent = file}
local base = {successes = {}, pendings = {}, errors = {{
  name = "spec/demo_spec.lua", message = ".../demo_spec.lua:3: unexpected symbol",
  element = {descriptor = "file", name = "spec/demo_spec.lua"},
}}, failures = {{
  name = name, message = "spec/demo_spec.lua:12: assertion failed",
  trace = {source = "@spec/demo_spec.lua", currentline = 12},
  element = {descriptor = "it", trace = {source = "@spec/demo_spec.lua", currentline = 8}},
}}}
local modules = package.loaded
local oldBusted, oldBase = modules.busted, modules["busted.outputHandlers.base"]
modules.busted = {
  subscribe = function(topic, callback) events[table.concat(topic, ".")] = callback end,
  parent = function(node) return node.parent end,
}
modules["busted.outputHandlers.base"] = function() return base end
local okReporter, handler = pcall(reporter, {arguments = {(request:gsub(".", function(char)
  return ("%02x"):format(char:byte())
end))}})
modules.busted, modules["busted.outputHandlers.base"] = oldBusted, oldBase
local written, results
if okReporter then
  events["describe.start"](group)
  local _, matching = events["register.it"]('fails [100%] "quoted" & more')
  local _, other = events["register.it"]('fails [100%] "quoted" & more again')
  ok(matching == true and other == false, "Busted reruns selected names literally, excluding similar names.")
  ok(events["register.pending"] ~= nil, "Busted applies the rerun filter to pending cases too.")
  written = pcall(events["suite.end"])
  if written then results = json.decode(FileRead(output) or "") end
end
FileRemove(output)
FileRemove(request)
ok(okReporter and handler == base, "The test reporter uses the Busted output handler API.")
local row = results and results.rows[1]
is(row and row.status, "failed", "The reporter preserves the outcome.")
is(row and row.line, 12, "The report points to the failure line.")
is(row and row.definitionLine, 8, "The report preserves the test definition as a fallback.")
local syntax = results and results.rows[2]
is(syntax and syntax.file, "spec/demo_spec.lua", "File errors use the original path when Lua shortens the message.")
is(syntax and syntax.line, 3, "File errors retain their reported line.")
