local frame = ide:GetMainFrame()
local function command(id)
  frame:GetEventHandler():ProcessEvent(wx.wxCommandEvent(wx.wxEVT_COMMAND_MENU_SELECTED, id))
end

is(ide:GetHotKey("F12"), ID.GOTODEFINITION, "F12 invokes Go To Definition.")
is(ide:GetHotKey("Alt-F12"), ID.FOLD, "Fold All remains available on Alt+F12.")
ok(ide:GetToolBar():FindTool(ID.PREVIOUSEDIT) and ide:GetToolBar():FindTool(ID.NEXTEDIT),
  "The main toolbar has Previous and Next Edit Position buttons.")

local first = NewFile()
first:AppendTextDyn("local first = 1\n")
first:InsertTextDyn(6, "my")
first:InsertTextDyn(8, "New")
local second = NewFile()
second:AppendTextDyn("local second = 2")
second:GotoPos(second:GetLength())

command(ID.PREVIOUSEDIT)
is(ide:GetEditor(), first, "Previous Edit Position returns to the previously edited document.")
is(first:GetCurrentPos(), 11, "Typing at one location is coalesced and navigation reaches the final edit position.")
command(ID.NEXTEDIT)
is(ide:GetEditor(), second, "Next Edit Position returns to the more recent edit across tabs.")
is(second:GetCurrentPos(), second:GetLength(), "Next Edit Position restores the edit's caret position.")

for _, editor in ipairs({first, second}) do
  local document = ide:GetDocument(editor)
  document:SetModified(false)
  document:Close()
end
