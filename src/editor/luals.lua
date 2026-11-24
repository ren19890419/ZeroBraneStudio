local lsp = require "lsp"
local ide = ide
local frame = ide:GetMainFrame()
local problems = ide:GetPackage("core.problems")
local source = "LuaLS"
local windows = ide.osname == "Windows"
local session, timer
local stopping = {}
local severity = {"error", "warning", "information", "hint"}
local referencesMethod, renameMethod = "textDocument/references", "textDocument/rename"

local function pathKey(path)
  path = path:gsub("\\", "/")
  return windows and path:lower() or path
end

local function absolute(file)
  file:Normalize(wx.wxPATH_NORM_ABSOLUTE + wx.wxPATH_NORM_DOTS)
  return file:GetFullPath()
end

local function send(s, message)
  if not s.queue then return end
  message.jsonrpc = "2.0"
  s.queue(lsp.frame(message))
end

local function notify(s, method, params)
  send(s, {method = method, params = params})
end

local function report(message)
  ide:Print(source..": "..message)
end

local function cancelRequest(s, reason)
  local pending = s.pending
  if not pending then return end
  s.pending = nil
  notify(s, "$/cancelRequest", {id = pending.id})
  if reason then pending.done(nil, reason) end
end

local function documentChanged(s, editor)
  local pending = s.pending
  if not pending then return end
  if pending.method == renameMethod then
    cancelRequest(s, TR("A Lua document changed. Preview the rename again."))
  elseif pending.editor == editor then
    cancelRequest(s, TR("The Lua document changed. Find references again."))
  end
end

local function reset(s)
  session = nil
  s.pending = nil
  problems:ClearDiagnostics(source)
  if not ide:IsExiting() then PackageEventHandle("onLuaLSStop") end
end

local function closeInput(s)
  if not s.input then return end
  s.input, s.queue, s.flush = nil, nil, nil
  s.process:CloseOutput()
end

local function stop()
  local s = session
  if not s then return end
  cancelRequest(s)
  reset(s)
  stopping[s.pid] = s
  s.deadline = ide:GetTime() + 1.5
  if s.ready then send(s, {id = 2, method = "shutdown"})
  else closeInput(s) end
end

local function inProject(s, path)
  return pathKey(path):sub(1, #s.prefix) == s.prefix
end

local function closeDocument(s, editor)
  local doc = s.documents[editor]
  s.dirty[editor] = nil
  if not doc then return end
  documentChanged(s, editor)
  s.documents[editor], s.byPath[doc.key] = nil, nil
  notify(s, "textDocument/didClose", {textDocument = {uri = doc.uri}})
  problems:SetDiagnostics(source, doc.path, {})
end

local function nextVersion(s, key)
  local version = (s.versions[key] or 0) + 1
  s.versions[key] = version
  return version
end

local function syncDocument(s, editor)
  if not s.ready then return end
  local document = ide:GetDocument(editor)
  local path = document and document:GetFilePath()
  local current = s.documents[editor]
  if not path or not editor.spec or editor.spec.apitype ~= "lua" or not inProject(s, path) then
    closeDocument(s, editor)
    return
  end
  local key = pathKey(path)
  if current and current.key ~= key then
    closeDocument(s, editor)
    current = nil
  end
  local text = editor:GetTextDyn()
  s.dirty[editor] = nil
  if not current then
    current = {key = key, path = path, uri = lsp.fileUri(path), text = text}
    s.documents[editor], s.byPath[key] = current, editor
    notify(s, "textDocument/didOpen", {textDocument = {uri = current.uri, languageId = "lua",
      text = text, version = nextVersion(s, key)}})
  elseif current.text ~= text and s.change ~= 0 then
    local change = {text = text}
    if s.change == 2 then
      change.range = {start = {line = 0, character = 0}, ["end"] = lsp.endPosition(current.text, s.encoding)}
    end
    current.text = text
    notify(s, "textDocument/didChange", {textDocument = {uri = current.uri, version = nextVersion(s, key)},
      contentChanges = {change}})
  end
  return current
end

local function request(s, method, editor, pos, params, done)
  cancelRequest(s, TR("The previous Lua request was canceled."))
  for changed in pairs(s.dirty) do
    if changed ~= editor then syncDocument(s, changed) end
  end
  local doc = syncDocument(s, editor)
  if not doc then return false end
  pos = math.max(0, math.min(pos, editor:GetLength()))
  local line = editor:LineFromPosition(pos)
  local prefix = editor:GetTextRangeDyn(editor:PositionFromLine(line), math.min(pos, editor:GetLineEndPosition(line)))
  params.textDocument = {uri = doc.uri}
  params.position = {line = line, character = lsp.endPosition(prefix, s.encoding).character}
  s.requestId = s.requestId + 1
  s.pending = {id = s.requestId, method = method, editor = editor, deadline = ide:GetTime() + 20, done = done}
  send(s, {id = s.requestId, method = method, params = params})
  return true
end

local function publish(s, params)
  if type(params) ~= "table" or type(params.diagnostics) ~= "table" then return end
  local path = lsp.filePath(params.uri, windows)
  if not path then return end
  path = absolute(wx.wxFileName(path))
  if not inProject(s, path) then return end
  local key = pathKey(path)
  local editor = s.byPath[key]
  if type(params.version) == "number" and params.version < (s.versions[key] or 0) then return end
  if editor then path = s.documents[editor].path end

  local entries = {}
  for _, diagnostic in ipairs(params.diagnostics) do
    local start = type(diagnostic) == "table" and type(diagnostic.range) == "table" and diagnostic.range.start
    if lsp.validPosition(start) and type(diagnostic.message) == "string" then
      local code = diagnostic.code
      local message = diagnostic.message
      if type(code) == "string" or type(code) == "number" then message = message.." ["..code.."]" end
      entries[#entries + 1] = {file = path, line = start.line + 1, column = start.character + 1,
        encoding = s.encoding, severity = severity[diagnostic.severity] or "warning", message = message}
    end
  end
  problems:SetDiagnostics(source, path, entries)
end

local function referenceLocations(s, result)
  local results, seen = {}, {}
  for _, location in ipairs(type(result) == "table" and result or {}) do
    local path = type(location) == "table" and lsp.filePath(location.uri, windows)
    local start = path and type(location.range) == "table" and location.range.start
    if lsp.validPosition(start) then
      path = absolute(wx.wxFileName(path))
      local key = pathKey(path)
      local doc = s.documents[s.byPath[key]]
      local line, character = start.line, start.character
      local id = key.."\n"..line..":"..character
      if not seen[id] then
        seen[id] = true
        results[#results + 1] = {path = doc and doc.path or path, key = key,
          line = line, character = character, encoding = s.encoding}
      end
    end
  end
  table.sort(results, function(a, b)
    if a.key ~= b.key then return a.key < b.key end
    if a.line ~= b.line then return a.line < b.line end
    return a.character < b.character
  end)
  return results
end

local function renameFiles(s, result)
  if result == lsp.null or result == nil then return {} end
  if type(result) ~= "table" or result.documentChanges or type(result.changes) ~= "table"
  or result.changes == lsp.null then
    return nil, TR("LuaLS returned an unsupported rename edit.")
  end
  local files, seen = {}, {}
  for uri, edits in pairs(result.changes) do
    local path = lsp.filePath(uri, windows)
    path = path and absolute(wx.wxFileName(path))
    if not path or not inProject(s, path) then
      return nil, TR("Rename includes a file outside the current project.")
    end
    local key = pathKey(path)
    if seen[key] or type(edits) ~= "table" or edits == lsp.null then
      return nil, TR("LuaLS returned an unsupported rename edit.")
    end
    seen[key] = true
    local doc = s.documents[s.byPath[key]]
    files[#files + 1] = {path = doc and doc.path or path, edits = edits, encoding = s.encoding}
  end
  table.sort(files, function(a, b) return pathKey(a.path) < pathKey(b.path) end)
  return files
end

local function hasProvider(provider)
  return provider == true or type(provider) == "table" and provider ~= lsp.null
end

local function receive(s, message)
  if s ~= session then
    if stopping[s.pid] and message.id == 2 and not message.method then
      notify(s, "exit")
      closeInput(s)
    end
    return
  end
  local method, params = message.method, message.params
  if not method and message.id == 1 then
    local result = message.result
    if message.error or type(result) ~= "table" or type(result.capabilities) ~= "table" then
      local err = type(message.error) == "table" and message.error.message
      report(type(err) == "string" and err or TR("Language server initialization failed."))
      stop()
      return
    end
    local caps = result.capabilities
    local sync = caps.textDocumentSync
    local encoding = caps.positionEncoding or caps.offsetEncoding
    s.encoding = (encoding == "utf-8" or encoding == "utf-32") and encoding or "utf-16"
    s.change = type(sync) == "table" and (sync.change or 0) or tonumber(sync) or 0
    s.save = type(sync) == "table" and sync.save
    s.canFindReferences = hasProvider(caps.referencesProvider)
    s.canRename = hasProvider(caps.renameProvider)
    s.ready = true
    notify(s, "initialized", lsp.object())
    for _, doc in pairs(ide:GetDocuments()) do syncDocument(s, doc:GetEditor()) end
  elseif not method and s.pending and message.id == s.pending.id then
    local pending = s.pending
    s.pending = nil
    if message.error then
      local err = type(message.error) == "table" and message.error.message
      pending.done(nil, type(err) == "string" and err or TR("The Lua language server request failed."))
    else
      pending.done(message.result)
    end
  elseif method == "textDocument/publishDiagnostics" then
    if s.ready then publish(s, params) end
  elseif method and message.id ~= nil then
    local result
    if method == "workspace/configuration" then
      result = {}
      for i in ipairs(params and params.items or {}) do result[i] = lsp.null end
    elseif method == "workspace/workspaceFolders" then
      result = s.folders
    elseif method == "window/workDoneProgress/create" or method == "window/showMessageRequest" then
      result = lsp.null
    end
    send(s, {id = message.id, result = result,
      error = not result and {code = -32601, message = "Method not supported"} or nil})
  elseif method == "window/showMessage" and type(params) == "table"
  and (params.type == 1 or params.type == 2) and type(params.message) == "string" then
    report(params.message)
  end
end

local function start(project, executable)
  if not project or not executable or session then return end
  if not wx.wxFileExists(executable) then
    report(TR("Language server executable was not found."))
    return
  end
  local folder = wx.wxFileName.DirName(project)
  project = absolute(folder)
  local root = project:gsub("[/\\]+$", "")
  if windows and root:match("^[A-Za-z]:$") then root = root.."/" end
  if root == "" then root = "/" end
  local uri = lsp.fileUri(root)
  local directories = folder:GetDirs()
  local s = {prefix = pathKey(root):gsub("/?$", "/"), documents = {}, byPath = {}, versions = {}, dirty = {},
    folders = {{uri = uri, name = directories[#directories] or root}},
    deadline = ide:GetTime() + 20, requestId = 2}
  local decode = lsp.decoder(function(message) receive(s, message) end)
  local command = '"'..executable..'"'
  local pid, err, process = ide:ExecuteCommand(command, wx.wxFileName(executable):GetPath(),
    function(data)
      local ok, problem = decode(data)
      if not ok and s == session then report(problem); stop() end
    end,
    function(pid, code)
      stopping[pid] = nil
      if s ~= session then return end
      reset(s)
      if code ~= nil then
        report(TR("Language server exited (code %d)."):format(code))
        if s.stderr and s.stderr:match("%S") then report(s.stderr) end
      end
    end,
    {raw = true, stderr = function(data) s.stderr = ((s.stderr or "") .. data):sub(-1500) end})
  if not pid then
    report(TR("Cannot start the language server: %s"):format(err or executable))
    return
  end
  s.pid, s.process, s.input = pid, process, process:GetOutputStream()
  -- A process pipe may accept only part of a frame, especially on Windows.
  s.queue, s.flush = lsp.writer(function(chunk)
    s.input:Write(chunk, #chunk)
    return s.input:LastWrite()
  end)
  session = s
  timer:Start(75)
  send(s, {id = 1, method = "initialize", params = {
    processId = lsp.null, rootUri = uri, workspaceFolders = s.folders,
    clientInfo = {name = "ZeroBrane Studio"},
    capabilities = {general = {positionEncodings = {"utf-16"}},
      workspace = {workspaceFolders = true, configuration = true},
      textDocument = {publishDiagnostics = {versionSupport = true}}},
  }})
end

timer = ide:AddTimer(frame, function()
  ide:GetOutput():ProcessStreams()
  local now = ide:GetTime()
  for pid, s in pairs(stopping) do
    if now >= s.deadline then
      closeInput(s)
      if wx.wxProcess.Exists(pid) then wx.wxProcess.Kill(pid, wx.wxSIGKILL, wx.wxKILL_CHILDREN) end
      stopping[pid] = nil
    elseif s.flush then
      s.flush()
    end
  end
  local s = session
  if s then
    if s.flush then s.flush() end
    if not s.ready and now >= s.deadline then
      report(TR("Language server initialization timed out."))
      stop()
    elseif s.ready then
      if s.pending and now >= s.pending.deadline then
        cancelRequest(s, s.pending.method == renameMethod and TR("Previewing the Lua rename timed out.")
          or TR("Finding Lua references timed out."))
      end
      for editor, due in pairs(s.dirty) do
        if now >= due then syncDocument(s, editor) end
      end
    end
  elseif not next(stopping) then
    timer:Stop()
  end
end)

local client = ide:AddPackage("core.luals", {
  GetExecutable = function(self)
    local executable = self:GetSettings().executable or ide.config.luals
    return type(executable) == "string" and executable ~= "" and executable or nil
  end,
  IsEnabled = function(self)
    return self:GetSettings().enabled ~= false and type(self:GetExecutable()) == "string"
  end,
  CanFindReferences = function(self, editor)
    local s = session
    return s and s.canFindReferences and s.documents[editor] ~= nil or false
  end,
  FindReferences = function(self, editor, pos, done)
    if not self:CanFindReferences(editor) then return false end
    local s = session
    return request(s, referencesMethod, editor, pos, {context = {includeDeclaration = true}}, function(result, err)
      if err then done(nil, err) else done(referenceLocations(s, result)) end
    end)
  end,
  CanRename = function(self, editor)
    local s = session
    return s and s.canRename and s.documents[editor] ~= nil or false
  end,
  RenameSymbol = function(self, editor, pos, newName, done)
    if not self:CanRename(editor) then return false end
    local s = session
    return request(s, renameMethod, editor, pos, {newName = newName}, function(result, err)
      if err then done(nil, err) else done(renameFiles(s, result)) end
    end)
  end,
  CancelRename = function()
    local s = session
    if s and s.pending and s.pending.method == renameMethod then cancelRequest(s) end
  end,
  Restart = function(self)
    stop()
    if self:IsEnabled() then start(ide:GetProject(), self:GetExecutable()) end
  end,
  SetExecutable = function(self, path)
    if type(path) ~= "string" or path:find('["\r\n]') or not wx.wxIsAbsolutePath(path)
    or not wx.wxFileExists(path) then return false end
    local settings = self:GetSettings()
    settings.executable, settings.enabled = path, true
    self:SetSettings(settings)
    self:Restart()
    return true
  end,
  onProjectLoad = function(self, project)
    if self:IsEnabled() then start(project, self:GetExecutable()) end
  end,
  onProjectClose = stop,
  onAppLoad = function(self)
    if self:IsEnabled() then start(ide:GetProject(), self:GetExecutable()) end
  end,
  onAppClose = function()
    stop()
    timer:Stop()
    for pid, s in pairs(stopping) do
      closeInput(s)
      if wx.wxProcess.Exists(pid) then wx.wxProcess.Kill(pid, wx.wxSIGKILL, wx.wxKILL_CHILDREN) end
    end
  end,
  onEditorLoad = function(self, editor) if session then syncDocument(session, editor) end end,
  onEditorClose = function(self, editor) if session then closeDocument(session, editor) end end,
  onEditorChange = function(self, editor)
    local s = session
    if s and s.documents[editor] then
      s.dirty[editor] = ide:GetTime() + 0.2
      documentChanged(s, editor)
    end
  end,
  onEditorSave = function(self, editor)
    local s = session
    if not s or not s.ready then return end
    local doc = syncDocument(s, editor)
    if doc and s.save then
      notify(s, "textDocument/didSave", {textDocument = {uri = doc.uri},
        text = type(s.save) == "table" and s.save.includeText and doc.text or nil})
    end
    local path = ide:GetDocument(editor):GetFilePath()
    if path and (pathKey(path) == s.prefix..".luarc.json" or pathKey(path) == s.prefix..".luarc.jsonc") then
      notify(s, "workspace/didChangeWatchedFiles", {changes = {{uri = lsp.fileUri(path), type = 2}}})
    end
  end,
})

local menuId, chooseId, enableId, restartId = ID("project.luals"), ID("project.luals.choose"),
  ID("project.luals.enable"), ID("project.luals.restart")
local menu = ide:MakeMenu {
  {chooseId, TR("Choose Server Executable...")},
  {enableId, TR("Enable Lua Language Server"), "", wx.wxITEM_CHECK},
  {restartId, TR("Restart Language Server")},
}
ide:FindTopMenu("&Project"):Append(menuId, TR("Lua Language Server"), menu)

frame:Connect(chooseId, wx.wxEVT_COMMAND_MENU_SELECTED, function()
  local current = wx.wxFileName(client:GetExecutable() or "")
  local dialog = wx.wxFileDialog(frame, TR("Choose Server Executable"), current:GetPath(), current:GetFullName(),
    windows and TR("Executables").." (*.exe)|*.exe" or "*", wx.wxFD_OPEN + wx.wxFD_FILE_MUST_EXIST)
  if dialog:ShowModal() == wx.wxID_OK then client:SetExecutable(dialog:GetPath()) end
  dialog:Destroy()
end)
frame:Connect(enableId, wx.wxEVT_COMMAND_MENU_SELECTED, function(event)
  local settings = client:GetSettings()
  settings.enabled = event:IsChecked()
  client:SetSettings(settings)
  client:Restart()
end)
frame:Connect(enableId, wx.wxEVT_UPDATE_UI, function(event)
  event:Enable(type(client:GetExecutable()) == "string")
  event:Check(client:IsEnabled())
end)
frame:Connect(restartId, wx.wxEVT_COMMAND_MENU_SELECTED, function() client:Restart() end)
frame:Connect(restartId, wx.wxEVT_UPDATE_UI, function(event)
  event:Enable(client:IsEnabled() and ide:GetProject() ~= nil)
end)
