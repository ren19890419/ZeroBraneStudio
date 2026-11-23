local ide = ide
local gitstatus = require "gitstatus"
local frame = ide:GetMainFrame()
local notebook = ide:GetOutputNotebook()
local windows = ide.osname == "Windows"
local viewId, refreshId, diffId = ID("view.gitchanges"), ID("git.refresh"), ID("git.diff")
local title, diffTitle = TR("Git Changes"), TR("Git Diff")

local panel = wx.wxPanel(notebook, wx.wxID_ANY)
local refreshButton = wx.wxButton(panel, refreshId, TR("Refresh"))
local summary = wx.wxStaticText(panel, wx.wxID_ANY, "")
local header = wx.wxBoxSizer(wx.wxHORIZONTAL)
header:Add(refreshButton, 0, wx.wxRIGHT, 8)
header:Add(summary, 1, wx.wxALIGN_CENTER_VERTICAL)
local list = wx.wxListCtrl(panel, wx.wxID_ANY, wx.wxDefaultPosition, wx.wxDefaultSize,
  wx.wxLC_REPORT + wx.wxLC_SINGLE_SEL)
list:SetName(title)
for index, column in ipairs({{TR("File"), 360}, {TR("Change"), 125}, {TR("Area"), 120}}) do
  list:InsertColumn(index - 1, column[1])
  list:SetColumnWidth(index - 1, column[2])
end
local sizer = wx.wxBoxSizer(wx.wxVERTICAL)
sizer:Add(header, 0, wx.wxEXPAND + wx.wxALL, 5)
sizer:Add(list, 1, wx.wxEXPAND)
panel:SetSizer(sizer)
ide:AddPanelDocked(notebook, panel, "gitchangespanel", title, nil, false)

local diffPanel = wx.wxPanel(notebook, wx.wxID_ANY)
local diffHeader = wx.wxStaticText(diffPanel, wx.wxID_ANY, "")
local patch = ide:CreateStyledTextCtrl(diffPanel, wx.wxID_ANY)
patch:SetCodePage(wxstc.wxSTC_CP_UTF8)
patch:StyleSetFont(wxstc.wxSTC_STYLE_DEFAULT, ide:GetOutput():GetFont())
patch:StyleSetForeground(wxstc.wxSTC_STYLE_DEFAULT, ide:GetOutput():StyleGetForeground(wxstc.wxSTC_STYLE_DEFAULT))
patch:StyleSetBackground(wxstc.wxSTC_STYLE_DEFAULT, ide:GetOutput():StyleGetBackground(wxstc.wxSTC_STYLE_DEFAULT))
patch:StyleClearAll()
patch:SetMarginWidth(0, 0)
patch:SetMarginWidth(1, 0)
patch:SetReadOnly(true)
if wxstc.wxSTC_LEX_DIFF then patch:SetLexer(wxstc.wxSTC_LEX_DIFF) end
local patchSizer = wx.wxBoxSizer(wx.wxVERTICAL)
patchSizer:Add(diffHeader, 0, wx.wxEXPAND + wx.wxALL, 5)
patchSizer:Add(patch, 1, wx.wxEXPAND)
diffPanel:SetSizer(patchSizer)
ide:AddPanelDocked(notebook, diffPanel, "gitdiffpanel", diffTitle, nil, false)

local area = {staged = TR("Staged"), unstaged = TR("Unstaged"), untracked = TR("Untracked"), conflict = TR("Conflict")}
local change = {M = TR("Modified"), A = TR("Added"), D = TR("Deleted"), R = TR("Renamed"),
  C = TR("Copied"), T = TR("Type Changed"), U = TR("Conflict"), ["?"] = TR("Untracked")}
local state, timer, diffRequest
local jobs = {}
local visible = {}
local gitExe
local maxStatus, maxPatch = 16 * 1024 * 1024, 4 * 1024 * 1024

local function pathKey(value)
  if windows then value = value:gsub("\\", "/"):lower() end
  return (value:gsub("/+$", ""))
end

local function display(value)
  local text = FixUTF8((value:gsub("[%z\r\n\t]", " ")), "\239\191\189")
  return text
end

local function branchName(snapshot)
  if snapshot.branch == "(detached)" then
    return TR("Detached HEAD %s"):format((snapshot.oid or ""):sub(1, 7))
  end
  return display(snapshot.branch)
end

local function colors(background)
  local dark = background:Red()*0.299 + background:Green()*0.587 + background:Blue()*0.114 < 130
  return dark and {
    M = wx.wxColour(112, 184, 255), A = wx.wxColour(119, 210, 145), D = wx.wxColour(249, 133, 131),
    U = wx.wxColour(249, 133, 131), untracked = wx.wxColour(180, 161, 251),
  } or {
    M = wx.wxColour(19, 88, 157), A = wx.wxColour(29, 113, 56), D = wx.wxColour(170, 30, 43),
    U = wx.wxColour(170, 30, 43), untracked = wx.wxColour(103, 64, 163),
  }
end
local palette = colors(ide:GetProjectTree():GetBackgroundColour())
if wxstc.wxSTC_DIFF_ADDED then patch:StyleSetForeground(wxstc.wxSTC_DIFF_ADDED, palette.A) end
if wxstc.wxSTC_DIFF_DELETED then patch:StyleSetForeground(wxstc.wxSTC_DIFF_DELETED, palette.D) end

local function rowFor(path)
  return state and state.snapshot and state.snapshot.byPath[pathKey(path)]
end

local function markItem(tree, item, path, previous)
  local row = rowFor(path)
  if row then
    local color = row.area == "untracked" and palette.untracked or palette[row.code] or palette.M
    tree:SetItemTextColour(item, color)
  elseif previous and previous[pathKey(path)] then
    tree:SetItemTextColour(item, tree:GetForegroundColour())
  end
end

local function markTree(previous)
  local tree = ide:GetProjectTree()
  if not ide:IsValidCtrl(tree) then return end
  local root = tree:GetRootItem()
  if not root:IsOk() then return end
  local snapshot = state and state.snapshot
  tree:SetRootSuffix(snapshot and (" ["..branchName(snapshot).."]") or nil)
  if not snapshot and not previous then return end
  local function visit(parent)
    local item, cookie = tree:GetFirstChild(parent)
    while item:IsOk() do
      if tree:IsDirectory(item) or tree:IsDirMapped(item) then
        if tree:GetChildrenCount(item, false) > 0 then visit(item) end
      else
        markItem(tree, item, tree:GetItemFullName(item), previous)
      end
      item, cookie = tree:GetNextChild(parent, cookie)
    end
  end
  visit(root)
end

local function render()
  local selected = list:GetNextItem(-1, wx.wxLIST_NEXT_ALL, wx.wxLIST_STATE_SELECTED)
  local previous = visible[selected + 1]
  local snapshot = state and state.snapshot
  visible = snapshot and snapshot.rows or {}
  list:Freeze()
  list:DeleteAllItems()
  for index, row in ipairs(visible) do
    local file = row.oldPath and row.oldPath.." \226\134\146 "..row.path or row.path
    list:InsertItem(index - 1, display(file))
    list:SetItem(index - 1, 1, change[row.code] or row.code)
    list:SetItem(index - 1, 2, area[row.area])
    if previous and previous.path == row.path and previous.area == row.area then
      list:SetItemState(index - 1, wx.wxLIST_STATE_SELECTED, wx.wxLIST_STATE_SELECTED)
    end
  end
  list:Thaw()
  summary:SetLabel(not state and TR("Open a Git project to see its changes.")
    or state and state.error
    or snapshot and (TR("Git branch %s"):format(branchName(snapshot)).."  "
      ..(#visible == 0 and TR("No changes") or TR("%d changes"):format(#visible)))
    or TR("Reading Git status..."))
  panel:Layout()
end

local function setPatch(label, text)
  diffHeader:SetLabel(label)
  patch:SetReadOnly(false)
  local utf8 = FixUTF8(text:gsub("%z", ""), "\239\191\189")
  patch:SetTextDyn(utf8)
  patch:EmptyUndoBuffer()
  patch:GotoPos(0)
  patch:SetReadOnly(true)
  diffPanel:Layout()
end

local function executable()
  local configured = ide.config.path.git
  if type(configured) == "string" and configured ~= "" then
    return GetFullPathIfExists(wx.wxFileName.GetCwd(), configured)
  end
  if gitExe and wx.wxFileExists(gitExe) then return gitExe end
  for dir in (os.getenv("PATH") or ""):gmatch(windows and "[^;]+" or "[^:]+") do
    dir = dir:gsub('^"(.*)"$', "%1")
    if wx.wxIsAbsolutePath(dir) then
      gitExe = GetFullPathIfExists(dir, windows and "git.exe" or "git")
      if gitExe then return gitExe end
    end
  end
end

local function quote(value)
  if windows then
    value = value:gsub('(\\*)"', '%1%1\\"'):gsub("(\\+)$", "%1%1")
  else
    value = value:gsub('[\\"]', '\\%0')
  end
  return '"'..value..'"'
end

local function ensureTimer()
  if not timer:IsRunning() then timer:Start(75) end
end

local function runGit(cwd, args, limit, callback)
  local exe = executable()
  if not exe then
    callback(nil, "", TR("Git was not found. Install Git or set path.git in user.lua."))
    return
  end
  local command = {quote(exe), "--no-pager", "--no-optional-locks", "--literal-pathspecs",
    "-c", "core.fsmonitor=false", "-C", quote(cwd)}
  for _, arg in ipairs(args) do command[#command + 1] = quote(arg) end
  local chunks, size, shortened, errors = {}, 0, false, ""
  local pid, err = ide:ExecuteCommand(table.concat(command, " "), nil, function(data)
    local remaining = limit - size
    if #data > remaining then shortened = true end
    if remaining > 0 then
      chunks[#chunks + 1] = data:sub(1, remaining)
      size = size + #chunks[#chunks]
    end
  end, function(pid, code)
    jobs[pid] = nil
    callback(code, table.concat(chunks), errors, shortened)
  end, {raw = true, group = true, stderr = function(data) errors = (errors..data):sub(1, 4096) end})
  if pid then jobs[pid] = true; ensureTimer()
  else callback(nil, "", TR("Cannot start Git: %s"):format(err or "")) end
end

local function accept(s, snapshot, message)
  if s ~= state then return end
  local previous = s.snapshot and s.snapshot.byPath
  s.busy, s.snapshot, s.error = false, snapshot, message
  if snapshot then
    snapshot.root, snapshot.byPath = s.root, {}
    table.sort(snapshot.rows, function(a, b)
      if a.path ~= b.path then return a.path < b.path end
      return a.area < b.area
    end)
    for _, row in ipairs(snapshot.rows) do
      local key = pathKey(s.root.."/"..row.path)
      -- Prefer the worktree diff when a file is also staged.
      local old = snapshot.byPath[key]
      if not old or old.area == "staged" then snapshot.byPath[key] = row end
    end
  end
  markTree(previous)
  render()
end

local function readStatus(s)
  runGit(s.root, {"status", "--porcelain=v2", "--branch", "--untracked-files=all", "--renames", "-z"},
    maxStatus, function(code, output, errors, shortened)
      if s ~= state then return end
      if shortened then
        accept(s, nil, TR("Git status is too large to display."))
      elseif code == 0 then
        local snapshot = gitstatus.parse(output)
        accept(s, snapshot, not snapshot and TR("Could not read Git status.") or nil)
      else
        s.root = nil
        accept(s, nil, errors ~= "" and display(errors) or TR("Could not read Git status."))
      end
    end)
end

local function refresh(s)
  s.due, s.busy = nil, true
  if s.root then readStatus(s); return end
  runGit(s.project, {"rev-parse", "--show-toplevel"}, 65536, function(code, output, errors)
    if s ~= state then return end
    local root = output:gsub("\r?\n$", "")
    if code ~= 0 or root == "" then
      local notRepository = errors:find("not a git repository", 1, true)
      accept(s, nil, notRepository and TR("This project is outside a Git repository.")
        or errors ~= "" and display(errors) or TR("Could not read Git status."))
      return
    end
    s.root = root
    readStatus(s)
  end)
end

local function queue(delay)
  if not state then return end
  state.due = ide:GetTime() + (delay or 0)
  ensureTimer()
end

local function reset(project)
  local previous = state and state.snapshot and state.snapshot.byPath
  state = project and {project = project} or nil
  diffRequest = nil
  markTree(previous)
  render()
  setPatch(diffTitle, TR("Double-click a Git change to see its diff."))
end

timer = ide:AddTimer(frame, function()
  ide:GetOutput():ProcessStreams()
  local s = state
  if s and s.due and not s.busy and s.due <= ide:GetTime() then refresh(s) end
  if not next(jobs) and not (s and (s.due or s.busy)) then timer:Stop() end
end)

local function showDiff(row)
  local s = state
  if not s or not s.snapshot or not row then return false end
  local request = {}
  diffRequest = request
  local label = display(row.path).."  ["..area[row.area].."]"
  setPatch(label, TR("Loading Git diff..."))
  ide:ActivateNotebookPage(diffPanel)
  local args = {"diff", "--color=never", "--no-ext-diff", "--no-textconv", "--no-relative", "--find-renames"}
  if row.area == "staged" then args[#args + 1] = "--cached"
  elseif row.area == "untracked" then args[#args + 1] = "--no-index"
  elseif row.area == "conflict" then args[#args + 1] = "--cc" end
  args[#args + 1] = "--"
  if row.area == "untracked" then args[#args + 1] = "/dev/null"
  elseif row.oldPath then args[#args + 1] = row.oldPath end
  args[#args + 1] = row.path
  runGit(s.snapshot.root, args, maxPatch, function(code, output, errors, shortened)
    if s ~= state or diffRequest ~= request then return end
    if code == 0 or code == 1 and row.area == "untracked" then
      local text = output == "" and TR("No diff for this change.") or output
      if shortened then text = text.."\n\n"..TR("The diff was truncated.") end
      setPatch(label, text)
    else
      setPatch(label, errors ~= "" and errors or TR("Could not read Git diff."))
    end
  end)
  return true
end

local gitview = ide:AddPackage("core.gitview", {
  GetSnapshot = function() return state and state.snapshot end,
  Show = function() ide:ActivateNotebookPage(panel); queue() end,
  Refresh = function() queue() end,
  onProjectLoad = function() reset(ide:GetProject()); queue() end,
  onProjectClose = function() reset() end,
  onAppLoad = function()
    if not state and ide:GetProject() then reset(ide:GetProject()); queue() end
  end,
  onAppFocusSet = function() queue(0.2) end,
  onEditorSave = function() queue(0.2) end,
  onFiletreeFileRename = function() queue(0.2) end,
  onFiletreeFileDelete = function() queue(0.2) end,
  onFiletreeFileAdd = function(self, tree, item, path)
    if not tree:IsDirectory(item) and not tree:IsDirMapped(item) then markItem(tree, item, path) end
  end,
  onFiletreeFileRefresh = function(self, tree, item)
    local snapshot = state and state.snapshot
    if tree:IsRoot(item) and snapshot then tree:SetRootSuffix(" ["..branchName(snapshot).."]") end
  end,
  onMenuFiletree = function(self, menu, tree, event)
    local item = event:GetItem()
    local row = item:IsOk() and rowFor(tree:GetItemFullName(item))
    if not row then return end
    menu:AppendSeparator()
    menu:Append(diffId, TR("Show Git Diff"))
    menu:Connect(diffId, wx.wxEVT_COMMAND_MENU_SELECTED, function() showDiff(row) end)
  end,
  onAppClose = function()
    state, diffRequest = nil, nil
    timer:Stop()
    for pid in pairs(jobs) do
      if wx.wxProcess.Exists(pid) then wx.wxProcess.Kill(pid, wx.wxSIGKILL, wx.wxKILL_CHILDREN) end
    end
  end,
})

list:Connect(wx.wxEVT_COMMAND_LIST_ITEM_ACTIVATED, function(event)
  local index = event:GetIndex()
  if index < 0 then index = list:GetNextItem(-1, wx.wxLIST_NEXT_ALL, wx.wxLIST_STATE_SELECTED) end
  showDiff(visible[index + 1])
end)
ide:FindTopMenu("&View"):Append(viewId, title)
frame:Connect(viewId, wx.wxEVT_COMMAND_MENU_SELECTED, function() gitview:Show() end)
panel:Connect(refreshId, wx.wxEVT_COMMAND_BUTTON_CLICKED, function() gitview:Refresh() end)
render()
setPatch(diffTitle, TR("Double-click a Git change to see its diff."))
