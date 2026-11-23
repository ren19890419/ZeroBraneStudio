local ide = ide
local frame = ide:GetMainFrame()
local projectPackage = ide:GetPackage("core.project")
local menuId, manageId, defaultId = ID("project.runprofiles"), ID("project.runprofiles.manage"),
  ID("project.runprofiles.default")
local menu = ide:MakeMenu {
  {manageId, TR("Manage Profiles...")}, {},
  {defaultId, TR("Default Run Settings"), "", wx.wxITEM_RADIO},
}
ide:FindTopMenu("&Project"):Append(menuId, TR("Run and Debug Profiles"), menu)

local function trim(text) return (text or ""):match("^%s*(.-)%s*$") end

local function getProjectProfiles(settings, project)
  return (settings.runProfiles or {})[project] or {profiles = {}}
end

local function fullPath(project, path, directory)
  local filename = directory and wx.wxFileName.DirName(path) or wx.wxFileName(path)
  filename:Normalize(wx.wxPATH_NORM_ABSOLUTE + wx.wxPATH_NORM_DOTS, project)
  return filename:GetFullPath()
end

function ide:ResolveRunProfile(project, profile)
  local interpreter = profile.interpreter and self:GetInterpreter(profile.interpreter)
  if not interpreter then return nil, TR("The profile interpreter is unavailable.") end
  if profile.mode == "attach" then
    if not interpreter.fattachdebug then return nil, TR("This interpreter cannot attach to a debugger.") end
  elseif not interpreter.frun then
    return nil, TR("This interpreter cannot run a project.")
  elseif profile.args ~= "" and not interpreter.takeparameters then
    return nil, TR("This interpreter does not accept command line parameters.")
  end
  local entry = profile.entry ~= "" and fullPath(project, profile.entry)
  if not entry or not wx.wxFileExists(entry) then return nil, TR("Choose an existing entry file.") end
  local cwd = profile.cwd ~= "" and fullPath(project, profile.cwd, true) or nil
  if cwd and not wx.wxDirExists(cwd) then return nil, TR("Choose an existing working directory.") end
  return {project = project, mode = profile.mode, entry = entry, cwd = cwd,
    args = profile.args, interpreter = profile.interpreter}
end

local cachedProject, cachedProfile
function ide:GetRunProfile()
  local project = self:GetProject()
  if project ~= cachedProject then
    cachedProject = project
    cachedProfile = project and projectPackage:GetActiveRunProfile(project) or nil
  end
  return cachedProfile
end

function projectPackage:GetActiveRunProfile(project)
  local projectProfiles = getProjectProfiles(self:GetSettings(), project)
  return projectProfiles.profiles[projectProfiles.active]
end

local menuIds, menuNames = {}, {}
local function refreshMenu()
  local project = ide:GetProject()
  local projectProfiles = getProjectProfiles(projectPackage:GetSettings(), project)
  cachedProject, cachedProfile = project, projectProfiles.profiles[projectProfiles.active]
  for index = #menuNames, 1, -1 do menu:Delete(menuIds[index]) end
  menuNames = {}
  for name in pairs(projectProfiles.profiles) do menuNames[#menuNames + 1] = name end
  table.sort(menuNames)
  for index, name in ipairs(menuNames) do
    if not menuIds[index] then
      local slot = index
      local id = ID("project.runprofiles.item." .. slot)
      menuIds[slot] = id
      frame:Connect(id, wx.wxEVT_COMMAND_MENU_SELECTED, function()
        projectPackage:SelectRunProfile(ide:GetProject(), menuNames[slot])
      end)
    end
    menu:Append(menuIds[index], name:gsub("&", "&&"), "", wx.wxITEM_RADIO)
    if name == projectProfiles.active then menu:Check(menuIds[index], true) end
  end
  if not cachedProfile then menu:Check(defaultId, true) end
end

local function saveProjectProfiles(project, settings, projectProfiles)
  settings.runProfiles = settings.runProfiles or {}
  settings.runProfiles[project] = projectProfiles
  projectPackage:SetSettings(settings)
  if project == ide:GetProject() then refreshMenu() end
end

function projectPackage:SelectRunProfile(project, name)
  if not project then return end
  local settings = self:GetSettings()
  local profiles = getProjectProfiles(settings, project)
  if name and not profiles.profiles[name] then return end
  profiles.active = name
  saveProjectProfiles(project, settings, profiles)
  return true
end

function projectPackage:SaveRunProfile(project, profile, previousName)
  if not project then return end
  local name = trim(profile.name)
  if name == "" then return nil, TR("Enter a profile name.") end
  local settings = self:GetSettings()
  local profiles = getProjectProfiles(settings, project)
  if name ~= previousName and profiles.profiles[name] then return nil, TR("A profile with this name already exists.") end
  local config = {name = name, entry = trim(profile.entry), cwd = trim(profile.cwd), args = profile.args or "",
    mode = profile.mode == "attach" and "attach" or "launch", interpreter = profile.interpreter}
  local resolved, err = ide:ResolveRunProfile(project, config)
  if not resolved then return nil, err end
  if previousName then profiles.profiles[previousName] = nil end
  profiles.profiles[name] = config
  profiles.active = name
  saveProjectProfiles(project, settings, profiles)
  return true
end

local function manageProfiles()
  local project = ide:GetProject()
  if not project then return end
  local dialog = wx.wxDialog(frame, wx.wxID_ANY, TR("Run and Debug Profiles"))
  local saved = getProjectProfiles(projectPackage:GetSettings(), project)
  local profileNames = {}
  for name in pairs(saved.profiles) do profileNames[#profileNames + 1] = name end
  table.sort(profileNames)
  local choices = {TR("New Profile")}
  for _, name in ipairs(profileNames) do choices[#choices + 1] = name end
  local profiles = wx.wxChoice(dialog, wx.wxID_ANY, wx.wxDefaultPosition, wx.wxDefaultSize, choices)
  local form = wx.wxFlexGridSizer(0, 2, 8, 10)
  form:AddGrowableCol(1)
  local function add(label, control)
    local caption = wx.wxStaticText(dialog, wx.wxID_ANY, TR(label))
    form:Add(caption, 0, wx.wxALIGN_CENTER_VERTICAL)
    form:Add(control, 1, wx.wxEXPAND)
    return control, caption
  end
  local function text(label)
    return add(label, wx.wxTextCtrl(dialog, wx.wxID_ANY, "", wx.wxDefaultPosition, wx.wxSize(320, -1)))
  end
  add("Profile", profiles)
  local name = text("Name")
  local mode = add("Mode", wx.wxChoice(dialog, wx.wxID_ANY, wx.wxDefaultPosition, wx.wxDefaultSize,
    {TR("Launch"), TR("Attach to Remote Lua")}))
  local interpreterIds, interpreterNames = {}, {}
  for id in pairs(ide.interpreters) do interpreterIds[#interpreterIds + 1] = id end
  table.sort(interpreterIds)
  for _, id in ipairs(interpreterIds) do interpreterNames[#interpreterNames + 1] = ide:GetInterpreter(id):GetName() end
  local interpreter = add("Lua Interpreter", wx.wxChoice(dialog, wx.wxID_ANY, wx.wxDefaultPosition,
    wx.wxDefaultSize, interpreterNames))
  local entry = text("Entry File")
  local cwd, directoryLabel = text("Working Directory")
  local args = text("Command line parameters")
  local feedback = wx.wxStaticText(dialog, wx.wxID_ANY, TR("Paths can be absolute or relative to the project."))
  local delete = wx.wxButton(dialog, wx.wxID_ANY, TR("Delete Profile"))
  local buttons = wx.wxBoxSizer(wx.wxHORIZONTAL)
  buttons:Add(delete, 0)
  buttons:AddStretchSpacer(1)
  buttons:Add(wx.wxButton(dialog, wx.wxID_CANCEL, TR("Cancel")), 0, wx.wxRIGHT, 8)
  local save = wx.wxButton(dialog, wx.wxID_OK, TR("Save and Select"))
  buttons:Add(save, 0)
  local sizer = wx.wxBoxSizer(wx.wxVERTICAL)
  sizer:Add(form, 0, wx.wxEXPAND + wx.wxALL, 12)
  sizer:Add(feedback, 0, wx.wxEXPAND + wx.wxLEFT + wx.wxRIGHT + wx.wxBOTTOM, 12)
  sizer:Add(buttons, 0, wx.wxEXPAND + wx.wxLEFT + wx.wxRIGHT + wx.wxBOTTOM, 12)
  dialog:SetSizerAndFit(sizer)
  save:SetDefault()

  local function refreshMode()
    local attach = mode:GetSelection() == 1
    args:Enable(not attach)
    directoryLabel:SetLabel(attach and TR("Source Directory") or TR("Working Directory"))
    dialog:Layout()
  end
  local function loadProfile()
    local previous = profileNames[profiles:GetSelection()]
    local data = saved.profiles[previous] or {}
    name:SetValue(data.name or "")
    mode:SetSelection(data.mode == "attach" and 1 or 0)
    local id = data.interpreter or ide:GetInterpreter():GetFileName()
    interpreter:SetSelection(wx.wxNOT_FOUND)
    for index, candidate in ipairs(interpreterIds) do
      if candidate == id then interpreter:SetSelection(index - 1) break end
    end
    local document = ide:GetEditor() and ide:GetDocument(ide:GetEditor())
    local _, startFile = ide:GetProjectStartFile()
    entry:SetValue(data.entry or startFile or document and document:GetFilePath() or "")
    cwd:SetValue(data.cwd or "")
    args:SetValue(data.args or "")
    delete:Enable(previous ~= nil)
    refreshMode()
  end
  profiles:SetSelection(0)
  for index, stored in ipairs(profileNames) do
    if stored == saved.active then profiles:SetSelection(index) break end
  end
  loadProfile()
  profiles:Connect(wx.wxEVT_COMMAND_CHOICE_SELECTED, loadProfile)
  mode:Connect(wx.wxEVT_COMMAND_CHOICE_SELECTED, refreshMode)
  save:Connect(wx.wxEVT_COMMAND_BUTTON_CLICKED, function()
    local ok, err = projectPackage:SaveRunProfile(project, {
      name = name:GetValue(), mode = mode:GetSelection() == 1 and "attach" or "launch",
      interpreter = interpreterIds[interpreter:GetSelection() + 1], entry = entry:GetValue(),
      cwd = cwd:GetValue(), args = args:GetValue(),
    }, profileNames[profiles:GetSelection()])
    if ok then dialog:EndModal(wx.wxID_OK)
    else feedback:SetLabel(err or ""); dialog:Layout(); dialog:Fit() end
  end)
  delete:Connect(wx.wxEVT_COMMAND_BUTTON_CLICKED, function()
    local previous = profileNames[profiles:GetSelection()]
    if not previous then return end
    local settings = projectPackage:GetSettings()
    local stored = getProjectProfiles(settings, project)
    stored.profiles[previous] = nil
    if stored.active == previous then stored.active = nil end
    saveProjectProfiles(project, settings, stored)
    dialog:EndModal(wx.wxID_OK)
  end)
  dialog:ShowModal()
  dialog:Destroy()
end

frame:Connect(manageId, wx.wxEVT_COMMAND_MENU_SELECTED, manageProfiles)
frame:Connect(defaultId, wx.wxEVT_COMMAND_MENU_SELECTED, function() projectPackage:SelectRunProfile(ide:GetProject()) end)
frame:Connect(menuId, wx.wxEVT_UPDATE_UI, function(event) event:Enable(ide:GetProject() ~= nil) end)
local onProjectLoad = projectPackage.onProjectLoad
function projectPackage:onProjectLoad(project)
  onProjectLoad(self, project)
  refreshMenu()
end
refreshMenu()
