--===========================================================================
-- EzWoW - Druid Forms
-- UI/OptionsWindow.lua : Settings window (key capture), Blizzard launcher, slash
--===========================================================================
local _, ns = ...
local type, ipairs, pairs, tostring, pcall = type, ipairs, pairs, tostring, pcall

local UIKit = ns.UIKit
local configFrame, optionsPanel, donateBox, capture

local function rgba(c) return c[1], c[2], c[3], c[4] or 1 end
local function S() return ns.Style end

local FORM_ORDER = { "bear", "aquatic", "cat", "travel", "moonkin" }
local MODIFIER_KEYS = { LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true, UNKNOWN = true }

-----------------------------------------------------------------------------
-- Key capture
-----------------------------------------------------------------------------
local function finishCapture(key)
    capture:Hide()
    if key then
        local action = type(GetBindingAction) == "function" and GetBindingAction(key) or ""
        if action ~= "" and action ~= ns.BindingName() then
            ns.Print(string.format(ns:L("keyReplaced"), key, _G["BINDING_NAME_" .. action] or action))
        end
        -- Shift/Ctrl + this key bound elsewhere: those presses never reach this button
        if ns.db and ns.db.useModifiers and not key:find("%-") and type(GetBindingAction) == "function" then
            local taken = {}
            for _, mod in ipairs({ "SHIFT", "CTRL" }) do
                local combo = mod .. "-" .. key
                local other = GetBindingAction(combo) or ""
                if other ~= "" and other ~= ns.BindingName() then
                    taken[#taken + 1] = combo .. " (" .. (_G["BINDING_NAME_" .. other] or other) .. ")"
                end
            end
            if #taken > 0 then
                ns.Print(string.format(ns:L("keyModTaken"), table.concat(taken, ", ")))
            end
        end
        ns.SetKey(key)
    end
    if ns.RefreshOptions then ns.RefreshOptions() end
end

local function startCapture()
    if ns.InCombat() then
        ns.Print(ns:L("combatLater"))
        return
    end
    if not capture then
        capture = CreateFrame("Frame", nil, configFrame)
        capture:SetAllPoints(configFrame)
        capture:SetFrameLevel(configFrame:GetFrameLevel() + 50)
        capture:EnableMouse(true)
        capture:EnableKeyboard(true)
        capture:SetPropagateKeyboardInput(false)
        local shade = capture:CreateTexture(nil, "BACKGROUND")
        shade:SetAllPoints()
        shade:SetColorTexture(0, 0, 0, 0.75)
        capture.text = capture:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        capture.text:SetPoint("CENTER")
        capture.text:SetWidth(380)
        capture.text:SetTextColor(rgba(S().accent))
        capture:SetScript("OnKeyDown", function(_, key)
            if MODIFIER_KEYS[key] then return end
            if key == "ESCAPE" then finishCapture(nil) return end
            local combo = (IsAltKeyDown() and "ALT-" or "") .. (IsControlKeyDown() and "CTRL-" or "")
                .. (IsShiftKeyDown() and "SHIFT-" or "") .. key
            finishCapture(combo)
        end)
        capture:SetScript("OnMouseDown", function(_, mouse)
            local map = { MiddleButton = "BUTTON3", Button4 = "BUTTON4", Button5 = "BUTTON5" }
            if map[mouse] then finishCapture(map[mouse]) end
        end)
        capture:SetScript("OnMouseWheel", function(_, delta)
            finishCapture(delta > 0 and "MOUSEWHEELUP" or "MOUSEWHEELDOWN")
        end)
        capture:EnableMouseWheel(true)
    end
    capture.text:SetText(ns:L("pressKey"))
    capture:Show()
end

-- opens the settings window (never closes it)
function ns:OpenOptions()
    if configFrame and configFrame:IsShown() then
        configFrame:Raise()
        return
    end
    self:ToggleOptions()
end

-- opened from the quick menu
function ns.StartKeyCapture()
    if configFrame and configFrame:IsShown() then startCapture() end
end

-----------------------------------------------------------------------------
-- Donate popup
-----------------------------------------------------------------------------
local function showDonatePopup()
    if not donateBox then
        donateBox = CreateFrame("Frame", "EzWoWDruidFormsDonate", UIParent, "BackdropTemplate")
        donateBox:SetSize(390, 116)
        donateBox:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
        UIKit:ApplyBackdrop(donateBox)
        donateBox:SetBackdropColor(S().bgPrimary[1], S().bgPrimary[2], S().bgPrimary[3], 0.98)
        donateBox:SetBackdropBorderColor(rgba(S().accent))
        donateBox.label = donateBox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        donateBox.label:SetPoint("TOP", 0, -14)
        donateBox.label:SetTextColor(rgba(S().accent))
        local box, edit = UIKit:CreateEditBox(donateBox, 346, 27)
        box:SetPoint("TOP", 0, -43)
        box:SetFrameLevel(donateBox:GetFrameLevel() + 5)
        edit:SetText(ns.DONATE_URL)
        edit:HookScript("OnEditFocusGained", function(self) self:HighlightText() end)
        edit:SetScript("OnEscapePressed", function() donateBox:Hide() end)
        edit:SetScript("OnEnterPressed", function() donateBox:Hide() end)
        edit:SetScript("OnTextChanged", function(self, userInput) if userInput then self:SetText(ns.DONATE_URL) self:HighlightText() end end)
        donateBox.edit = edit
        local close = UIKit:CreateCloseButton(donateBox, function() donateBox:Hide() end)
        close:SetPoint("TOPRIGHT", -6, -6)
    end
    donateBox.label:SetText(ns:L("copy"))
    UIKit:ElevateModal(donateBox, 260)
    donateBox:Show()
    donateBox.edit:SetFocus()
    donateBox.edit:HighlightText()
end

-----------------------------------------------------------------------------
-- Settings window
-----------------------------------------------------------------------------
function ns:ToggleOptions()
    if not self.db then return end
    if configFrame then
        configFrame:SetShown(not configFrame:IsShown())
        if configFrame:IsShown() then configFrame:Raise() end
        return
    end
    local db = self.db
    configFrame = CreateFrame("Frame", "EzWoWDruidFormsConfig", UIParent, "BackdropTemplate")
    -- (taller than the screen: shrunk to fit, Libs/EzWoWGamePad)
    if ns.GamePad and ns.GamePad.KeepOnScreen then ns.GamePad.KeepOnScreen(configFrame) end
    configFrame:SetSize(440, 676)
    configFrame:SetPoint("CENTER")
    configFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    configFrame:SetToplevel(true)
    configFrame:SetClampedToScreen(true)
    configFrame:SetMovable(true)
    configFrame:EnableMouse(true)
    if UISpecialFrames then tinsert(UISpecialFrames, "EzWoWDruidFormsConfig") end
    UIKit:ApplyBackdrop(configFrame, 1, 1)
    configFrame:SetBackdropColor(rgba(S().bgPrimary))
    configFrame:SetBackdropBorderColor(rgba(S().border))
    configFrame:SetScript("OnHide", function() if capture then capture:Hide() end end)

    local top = UIKit:CreateHeader(configFrame, ns.TITLE)
    top.subtitle:SetWidth(320)
    local close = UIKit:CreateCloseButton(top, function() configFrame:Hide() end)
    close:SetPoint("TOPRIGHT", top, "TOPRIGHT", -10, -10)

    local headings = {}
    -- a section title with a rule under it; :Place(y) puts it at y
    local function section(key)
        local t = UIKit:CreateSectionLabel(configFrame, 20, 0)
        local line = configFrame:CreateTexture(nil, "ARTWORK")
        line:SetColorTexture(S().border[1], S().border[2], S().border[3], 0.85)
        line:SetHeight(1)
        headings[#headings + 1] = { fs = t, key = key }
        return {
            Place = function(_, y)
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 20, y)
                line:ClearAllPoints()
                line:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 20, y - 20)
                line:SetPoint("TOPRIGHT", configFrame, "TOPRIGHT", -20, y - 20)
            end,
        }
    end

    -- learned forms
    local learned = configFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    learned:SetPoint("TOPLEFT", 22, -68)
    learned:SetWidth(396)
    learned:SetJustifyH("LEFT")
    learned:SetTextColor(rgba(S().textMuted))

    -- 1. Key
    section("secKey"):Place(-104)
    local keyBtn = UIKit:CreateButton(configFrame, 290, 34, "", true, "GameFontNormal")
    keyBtn:SetPoint("TOPLEFT", 20, -130)
    keyBtn:SetScript("OnClick", startCapture)
    local clearKey = UIKit:CreateButton(configFrame, 104, 34, "", false, "GameFontHighlightSmall")
    clearKey:SetPoint("LEFT", keyBtn, "RIGHT", 6, 0)
    clearKey:SetScript("OnClick", function() ns.SetKey(nil) end)

    -- 2-4. In combat, out of combat, Shift/Ctrl/Alt: check boxes and radio buttons
    -- (the same list as the quick menu)
    local CHOICES_TOP = -178
    local choiceWidgets = ns.BuildChoiceWidgets(configFrame, { header = "GameFontNormal", text = "GameFontHighlight" }, 18)

    -- 5. Button
    local buttonSection = section("secButton")
    local showCheck = UIKit:CreateChoice(configFrame, "check", "GameFontHighlight", 18)
    showCheck:SetScript("OnClick", function()
        db.showButton = not db.showButton
        ns.ApplyButton()
        ns.RefreshOptions()
    end)
    local moveHint = configFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    moveHint:SetWidth(392)
    moveHint:SetJustifyH("LEFT")
    moveHint:SetTextColor(rgba(S().textMuted))
    local sizeLabel = configFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    local minus = UIKit:CreateButton(configFrame, 27, 27, "-", false, "GameFontNormalLarge")
    local sizeValue = configFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sizeValue:SetPoint("LEFT", minus, "RIGHT", 4, 0)
    sizeValue:SetWidth(40)
    local plus = UIKit:CreateButton(configFrame, 27, 27, "+", false, "GameFontNormalLarge")
    plus:SetPoint("LEFT", minus, "RIGHT", 48, 0)
    local function changeSize(delta)
        db.buttonSize = math.max(24, math.min(64, db.buttonSize + delta))
        ns.ApplyButton()
        ns.RefreshOptions()
    end
    minus:SetScript("OnClick", function() changeSize(-4) end)
    plus:SetScript("OnClick", function() changeSize(4) end)
    local resetBtn = UIKit:CreateButton(configFrame, 150, 27, "", false, "GameFontHighlightSmall")
    resetBtn:SetScript("OnClick", function()
        db.buttonPos = nil
        ns.ApplyButton()
    end)

    -- macro preview
    local macroSection = section("secMacro")
    local macroText = configFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    macroText:SetWidth(396)
    macroText:SetJustifyH("LEFT")
    macroText:SetJustifyV("TOP")
    macroText:SetTextColor(rgba(S().textMuted))

    local langBtn = UIKit:CreateButton(configFrame, 197, 28, "")
    langBtn:SetPoint("BOTTOMLEFT", 20, 32)
    local langItems = {}
    for i, v in ipairs(ns.LANGUAGE_OPTIONS) do langItems[i] = { value = v[1], text = v[2] } end
    ns.LanguageDropdown.Attach(langBtn, {
        items = langItems,
        colors = { accent = ns.Style.accent },
        get = function() return db.language end,
        set = function(code)
            db.language = code
            -- the key-binding name and the button's corner label are text too
            _G["BINDING_NAME_" .. ns.BindingName()] = ns:L("bindingName")
            if ns.ApplyButton then ns.ApplyButton() end
            ns.RefreshOptions()
        end,
    })
    local donateBtn = UIKit:CreateButton(configFrame, 197, 28, "", true)
    donateBtn:SetPoint("BOTTOMRIGHT", -20, 32)
    donateBtn:SetScript("OnClick", showDonatePopup)
    local foot = configFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    foot:SetPoint("BOTTOM", 0, 12)

    function ns.RefreshOptions()
        if not configFrame then return end
        ns.FitText(top.subtitle, ns:L("settingsSub"), 320, 10, 8)
        for _, h in ipairs(headings) do ns.FitText(h.fs, ns:L(h.key), 395, 13, 10) end

        local isDruid = ns.IsDruid()
        if not isDruid then
            learned:SetText(ns:L("notDruid"))
        else
            local names = {}
            for _, kind in ipairs(FORM_ORDER) do
                if ns.forms[kind] then names[#names + 1] = ns.forms[kind].name end
            end
            learned:SetText(#names > 0 and (ns:L("learned") .. " " .. table.concat(names, ", ")) or ns:L("noForms"))
        end

        local key = ns.GetBoundKey()
        keyBtn:SetLabel(key and string.format(ns:L("keyIs"), key) or ns:L("keyNone"))
        keyBtn:SetEnabledState(isDruid)
        clearKey:SetLabel(ns:L("keyClear"))
        clearKey:SetEnabledState(isDruid and key ~= nil)

        -- everything below the key section is placed top to bottom
        local y = CHOICES_TOP
        if isDruid then
            local used = ns.LayoutChoiceWidgets(configFrame, choiceWidgets, 22, y, 396,
                { gapX = 12, gapY = 5, headerH = 28, sectionGap = 10, headerX = -2, line = true })
            y = y - used - 8
        end
        for _, w in ipairs(choiceWidgets) do
            for _, part in pairs(w) do
                if type(part) == "table" and part.SetShown then part:SetShown(isDruid) end
            end
            if w.choices then for _, c in ipairs(w.choices) do c:SetShown(isDruid) end end
        end
        buttonSection:Place(y)
        y = y - 28
        showCheck:Set(ns:L("opt_showButton"), db.showButton and true or false, true)
        local _, showH = showCheck:Layout(396)
        showCheck:ClearAllPoints()
        showCheck:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 22, y)
        y = y - showH - 8
        moveHint:SetText(ns:L("moveHint"))
        moveHint:ClearAllPoints()
        moveHint:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 24, y)
        y = y - math.ceil(moveHint:GetStringHeight() or 12) - 10
        ns.FitText(sizeLabel, ns:L("buttonSize"), 120, 12, 9)
        sizeLabel:ClearAllPoints()
        sizeLabel:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 24, y - 7)
        minus:ClearAllPoints()
        minus:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 150, y)
        sizeValue:SetText(tostring(db.buttonSize))
        resetBtn:ClearAllPoints()
        resetBtn:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 270, y)
        resetBtn:SetLabel(ns:L("resetPos"))
        y = y - 27 - 16
        macroSection:Place(y)
        y = y - 26
        macroText:ClearAllPoints()
        macroText:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 22, y)
        macroText:SetText(isDruid and ns.MacroPreview() or "")
        -- grow the window so the macro never runs into the buttons below it
        local macroHeight = macroText:GetStringHeight() or 0
        configFrame:SetHeight(math.max(600, math.ceil(-y + macroHeight + 84)))
        langBtn:SetLabel(ns:L("language") .. ": " .. ns:GetLanguageDisplayLabel() .. " ▼")
        donateBtn:SetLabel(ns:L("donate"))
        local ver = ns.GetVersion()
        foot:SetText(ns.TITLE .. (ver ~= "" and (" v" .. ver) or "") .. "  ·  /ezdf")
        if optionsPanel and optionsPanel.refreshText then optionsPanel.refreshText() end
    end
    configFrame:SetScript("OnShow", ns.RefreshOptions)
    ns.RefreshOptions()
end

-----------------------------------------------------------------------------
-- Blizzard settings launcher & slash
-----------------------------------------------------------------------------
function ns:RegisterBlizzardOptions()
    if optionsPanel then return end
    optionsPanel = CreateFrame("Frame", "EzWoWDruidFormsOptionsPanel", UIParent)
    optionsPanel.name = ns.TITLE
    local icon = optionsPanel:CreateTexture(nil, "ARTWORK")
    icon:SetSize(32, 32)
    icon:SetPoint("TOPLEFT", 18, -18)
    icon:SetTexture(ns.MEDIA_PATH .. "Icon")
    local heading = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    heading:SetPoint("LEFT", icon, "RIGHT", 10, 0)
    heading:SetText(ns.TITLE)
    heading:SetTextColor(rgba(S().accent))
    local desc = optionsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    desc:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", 0, -14)
    desc:SetWidth(520)
    desc:SetJustifyH("LEFT")
    local open = UIKit:CreateButton(optionsPanel, 220, 28, "", true)
    open:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -18)
    open:SetScript("OnClick", function() ns:ToggleOptions() end)
    optionsPanel.refreshText = function()
        desc:SetText(ns:L("panelDesc"))
        open:SetLabel(ns:L("panelOpen"))
    end
    optionsPanel:SetScript("OnShow", optionsPanel.refreshText)
    -- fill the texts now: the settings window does not always fire OnShow
    optionsPanel.refreshText()
    if Settings and type(Settings.RegisterCanvasLayoutCategory) == "function" and type(Settings.RegisterAddOnCategory) == "function" then
        local ok, cat = pcall(Settings.RegisterCanvasLayoutCategory, optionsPanel, ns.TITLE)
        if ok and cat then pcall(Settings.RegisterAddOnCategory, cat) end
    end
end

SLASH_EZWOWDRUIDFORMS1 = "/ezdf"
SLASH_EZWOWDRUIDFORMS2 = "/드루이드"
SLASH_EZWOWDRUIDFORMS3 = "/ezwowdruidforms"
SlashCmdList.EZWOWDRUIDFORMS = function()
    if not ns.db then return end
    ns:ToggleOptions()
end
