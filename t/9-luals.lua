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

local path = "C:/my project/#file%20.lua"
is(lsp.fileUri(path), "file:///C:/my%20project/%23file%2520.lua", "LSP file URIs escape reserved characters.")
is(lsp.filePath(lsp.fileUri(path), true), path, "Windows drive paths round trip through a file URI.")
is(lsp.filePath("file://host/share/main.lua", true), "//host/share/main.lua", "UNC URIs keep their host.")
ok(lsp.filePath("https://example.com/main.lua", true) == nil, "Non-file URIs are ignored.")
local ending = lsp.endPosition("first\r\nsecond\r\n\228\184\173\240\159\152\128", "utf-16")
is(ending.line, 2, "Full-document changes count CRLF as one line ending.")
is(ending.character, 3, "Full-document changes count supplementary characters as two UTF-16 units.")

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
