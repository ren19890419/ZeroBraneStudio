local lsp = require "lsp"
local messages = {}
local receive = lsp.decoder(function(message) messages[#messages + 1] = message end)
local diagnostic = lsp.frame({jsonrpc = "2.0", method = "textDocument/publishDiagnostics",
  params = {message = "\228\184\173\230\150\135"}})
local response = lsp.frame({jsonrpc = "2.0", id = 1, result = {}})
local split = diagnostic:find("\228", 1, true)
ok(receive(diagnostic:sub(1, 4)), "An LSP header can arrive in multiple reads.")
ok(receive(diagnostic:sub(5, split)), "An LSP message can arrive with a split UTF-8 sequence.")
is(#messages, 0, "The decoder waits for all bytes in a message.")
ok(receive(diagnostic:sub(split + 1) .. response), "One read can contain multiple LSP messages.")
is(messages[1].params.message, "\228\184\173\230\150\135", "LSP framing preserves UTF-8 bytes.")
is(messages[2].id, 1, "The decoder emits both messages in order.")
local rejected = lsp.decoder(function() error("Invalid frames must not be dispatched.") end)
ok(not rejected("Content-Length: 0\r\n\r\n"), "The decoder rejects an invalid content length.")

local sent, space = "", 2
local queue, flush = lsp.writer(function(chunk)
  local count = math.min(#chunk, space)
  sent, space = sent..chunk:sub(1, count), space - count
  return count
end)
queue(diagnostic)
queue(response)
is(sent, diagnostic:sub(1, 2), "A short write keeps the unsent bytes queued.")
space = #diagnostic + #response
flush()
is(sent, diagnostic..response, "Later messages wait for the partially written LSP frame.")
queue("next")
space = 4
flush()
is(sent, diagnostic..response.."next", "An empty queue can be reused after a flush.")

local path = "C:/my project/#file%20.lua"
is(lsp.fileUri(path), "file:///C:/my%20project/%23file%2520.lua", "LSP file URIs escape reserved characters.")
is(lsp.filePath(lsp.fileUri(path), true), path, "Windows drive paths round trip through a file URI.")
is(lsp.filePath("file://host/share/main.lua", true), "//host/share/main.lua", "UNC URIs keep their host.")
ok(lsp.filePath("https://example.com/main.lua", true) == nil, "Non-file URIs are ignored.")
local ending = lsp.endPosition("first\r\nsecond\r\n\228\184\173\240\159\152\128", "utf-16")
is(ending.line, 2, "Full-document changes count CRLF as one line ending.")
is(ending.character, 3, "Full-document changes count supplementary characters as two UTF-16 units.")

local line = "a\228\184\173\240\159\152\128x"
is(lsp.byteOffset(line, 4, "utf-16"), 8, "Reference locations use UTF-16 columns by default.")
is(lsp.byteOffset(line, 3, "utf-16"), 4, "Navigation never splits a surrogate pair.")
is(lsp.byteOffset(line, 3, "utf-32"), 8, "Reference locations can use UTF-32 columns.")
is(lsp.byteOffset(line, 7, "utf-8"), 4, "Navigation never splits a UTF-8 character.")
is(lsp.byteOffset(line, 20, "utf-16"), #line, "A reference column beyond the line is clamped.")

local function edit(line, first, last, replacement)
  return {range = {start = {line = line, character = first},
    ["end"] = {line = line, character = last}}, newText = replacement}
end

local edits = lsp.textEdits("header\r\n"..line.." x\r\n", {
  edit(1, 6, 7, "second"), edit(1, 4, 5, "first"),
}, "utf-16")
is(edits and edits[1].start, 16, "Rename converts UTF-16 ranges to byte offsets after CRLF and emoji.")
is(edits and edits[1].finish, 17, "Rename records the exclusive end of each replacement.")
is(edits and edits[2].text, "second", "Rename orders edits by their position in the original text.")
ok(not lsp.textEdits(line, {edit(0, 3, 5, "bad")}, "utf-16"), "Rename rejects a range inside a surrogate pair.")
ok(not lsp.textEdits(line, {edit(0, 4, 7, "bad")}, "utf-16"), "Rename rejects out-of-bounds ranges.")
ok(not lsp.textEdits("alpha", {edit(0, 0, 3, "a"), edit(0, 2, 5, "b")}, "utf-16"),
  "Rename rejects overlapping replacements before applying any changes.")
ok(not lsp.textEdits("alpha", {malformed = edit(0, 0, 3, "a")}, "utf-16"),
  "Rename rejects malformed edit arrays instead of silently skipping entries.")

local function replacement(first, last, text)
  return {range = {start = {line = first, character = 0}, ["end"] = {line = last, character = 0}}, newText = text}
end

local selection = "a=1\r\nb=2\r\nc=3"
local formatting = lsp.formatEdits(selection, {replacement(0, 2, "a=1\r\nb = 2\r\n")}, "utf-16", 5, 10)
is(formatting and #formatting, 2, "Formatting clips unchanged context and applies only the selected line's spaces.")
is(formatting and formatting[1].start, 6, "Range formatting retains CRLF and uses the original byte positions.")
ok(not lsp.formatEdits(selection, {replacement(0, 2, "a = 1\r\nb = 2\r\n")}, "utf-16", 5, 10),
  "Range formatting rejects changes outside the selected lines.")
ok(not lsp.formatEdits(selection, {replacement(1, 2, "b = 2")}, "utf-16", 5, 10),
  "Range formatting cannot merge the next unselected line.")
local eof = lsp.formatEdits(selection, {replacement(2, 3, "c = 3\r\n")}, "utf-16", 10, #selection)
is(eof and eof[#eof].start, #selection, "LuaLS range formatting maps the virtual line after EOF to the file end.")
is(eof and eof[#eof].text, "\r\n", "Range formatting can format the final line without an existing newline.")
ok(not lsp.textEdits(selection, {replacement(2, 3, "c = 3")}, "utf-16"), "Rename ranges remain strict at EOF.")
local indent = lsp.formatEdits("a\r\n  b", {replacement(0, 2, "a\r\n b")}, "utf-16")
is(indent and indent[1].start, 4, "Formatting leaves unchanged line endings in place when updating indentation.")

if ide then
  local client = ide:GetPackage("core.luals")
  ok(client:IsEnabled() == (client:GetExecutable() ~= nil and client:GetSettings().enabled ~= false),
    "The LuaLS client reports whether an executable is enabled.")
  local problems = ide:GetPackage("core.problems")
  local path = "C:/project with spaces/lsp-test.lua"
  local diagnostic = {file = path, line = 1, column = 4, message = "test", severity = "information"}
  problems:SetDiagnostics("LuaLS test", path, {diagnostic})
  local entry = problems:GetDiagnostics(path)[1]
  is(entry and entry.source, "LuaLS test", "Problems records a diagnostic's source.")
  problems:SetDiagnostics("LuaLS test", path, {})
  is(#problems:GetDiagnostics(path), 0, "An empty published list removes the source's old diagnostics.")
  problems:ClearDiagnostics("LuaLS test")
end
