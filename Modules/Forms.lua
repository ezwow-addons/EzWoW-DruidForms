--===========================================================================
-- EzWoW - Druid Forms
-- Modules/Forms.lua : Learned forms, the one-key macros, the buttons & key binding
--===========================================================================
-- What a press does depends on the place ([swimming], [combat], [outdoors] ...),
-- read by the game's macro conditions at the press, and on what you are now
-- (caster, mounted, or which form). The latter is followed by a secure state
-- driver that swaps in the macro made for it. Both also work in combat, where an
-- addon may not change what a secure button does.
local _, ns = ...
local type, ipairs, pairs, pcall, tostring = type, ipairs, pairs, pcall, tostring

ns.forms = {}       -- kind -> { index, name, icon, spellID }
ns.kindAt = {}      -- stance bar index -> kind ("other" = a form this addon does not know)
ns.formCount = 0
ns.mount = nil      -- { name, icon } of the mount to use (a favorite first)
ns.prowl = nil      -- { name, icon } once Prowl is learned
local button, keyButton, header
local wheelArea, wheelView  -- form wheel: the secure area read on release, and what is drawn
local iconOnUpdate  -- the visible button's icon prediction (runs only while it is shown)

local CASTER_ICON = "Interface\\Icons\\ClassIcon_Druid"
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Spell IDs of the classic forms, plus words of the localized names (checked when the
-- IDs differ on this realm). Order matters: bear is matched before the others.
local KINDS = {
    { key = "bear", ids = { [5487] = true, [9634] = true },
      words = { "곰", "bear", "bär", "ours", "oso", "медвед", "熊" } },
    { key = "aquatic", ids = { [1066] = true },
      words = { "수중", "aquatic", "wasser", "aquatique", "acuática", "водн", "水栖", "水棲" } },
    { key = "cat", ids = { [768] = true },
      words = { "표범", "cat", "katze", "félin", "felina", "кош", "猎豹", "獵豹" } },
    { key = "travel", ids = { [783] = true },
      words = { "여행", "치타", "날쌘", "travel", "reise", "voyage", "viaje", "поход", "旅行" } },
    { key = "moonkin", ids = { [24858] = true },
      words = { "달빛야수", "moonkin", "mondkin", "sélénien", "lechúcico", "лунного", "枭兽", "梟獸" } },
}
local PROWL_IDS = { 9913, 6783, 5215 }

-- Where each form is learned, shown next to a choice that cannot be used yet
-- (a number = character level; "talent" = from the talent tree).
local LEARN_AT = { bear = 10, aquatic = 16, cat = 20, travel = 30, moonkin = "talent", prowl = 20 }
-- what a check box needs
ns.OPTION_FORM = { useAquatic = "aquatic", catProwl = "prowl" }
-- radio button choices
ns.COMBAT_CHOICES = { "bear", "cat", "caster", "moonkin" }
ns.OUTDOOR_CHOICES = { "travel", "mount", "cat" }
ns.MOD_CHOICES = { "bear", "cat", "travel", "aquatic", "moonkin", "mount" }
ns.MODIFIERS = { "shift", "ctrl", "alt" }

-- true when that choice can be used now
function ns.Available(kind)
    if kind == "caster" then return true end
    if kind == "mount" then return ns.mount ~= nil end
    if kind == "prowl" then return ns.prowl ~= nil end
    return ns.forms[kind] ~= nil
end

-- Label with "(level 30)" / "(talent)" / "(no mount)" added when it cannot be used yet.
function ns.FormLabel(text, kind)
    if not kind or ns.Available(kind) then return text end
    if kind == "mount" then return text .. " " .. ns:L("noMount") end
    local at = LEARN_AT[kind]
    if not at then return text end
    if at == "talent" then return text .. " " .. ns:L("learnTalent") end
    return text .. " " .. string.format(ns:L("learnLevel"), at)
end

-- name, icon of a spell
local function spellInfo(spellID)
    if C_Spell and type(C_Spell.GetSpellInfo) == "function" then
        local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
        if ok and type(info) == "table" and type(info.name) == "string" then return info.name, info.iconID end
    end
    if type(GetSpellInfo) == "function" then
        local ok, name, _, icon = pcall(GetSpellInfo, spellID)
        if ok and type(name) == "string" then return name, icon end
    end
    return nil
end

local function tryKnown(fn, spellID)
    if type(fn) ~= "function" then return false end
    local ok, known = pcall(fn, spellID)
    return ok and known == true
end

local function knownSpell(spellID)
    return tryKnown(_G.IsPlayerSpell, spellID)
        or tryKnown(C_SpellBook and C_SpellBook.IsSpellKnown, spellID)
        or tryKnown(_G.IsSpellKnown, spellID)
end

local function classify(spellID, name)
    for _, kind in ipairs(KINDS) do
        if kind.ids[spellID] then return kind.key end
    end
    local lower = (name or ""):lower()
    for _, kind in ipairs(KINDS) do
        for _, word in ipairs(kind.words) do
            if lower:find(word, 1, true) then return kind.key end
        end
    end
    return nil
end

local function scanProwl()
    ns.prowl = nil
    for _, spellID in ipairs(PROWL_IDS) do
        if knownSpell(spellID) then
            local name, icon = spellInfo(spellID)
            if name then ns.prowl = { name = name, icon = icon } end
            return
        end
    end
end

-- true when this character can ride the mount (riding skill, level, faction).
-- Where the player stands is not checked (indoors, a loading screen).
local function mountUsable(journal, mountID, isUsable)
    if type(journal.GetMountUsabilityByID) == "function" then
        local ok, usable = pcall(journal.GetMountUsabilityByID, mountID, false)
        if ok and type(usable) == "boolean" then return usable end
    end
    return isUsable == true
end

-- The mount for "mount" choices: one this character can ride, a favorite
-- first, else the first one collected. (2026-11-18: a level 43 druid with
-- Apprentice Riding got a mount that needs the next riding skill.)
-- A "yes" from the game always counts (checked 2026-11-22: in Travel Form it says yes for the
-- rideable mounts). A "no" is trusted only as a caster on the ground: in a form, on a mount, swimming,
-- falling, dead or on a flight path the last choice is kept and the scan waits for caster form.
-- (2026-11-22: scans in a form, and right after leaving one, left "(no mount)" for good.)
local function caster()
    if type(IsMounted) == "function" and IsMounted() then return false end
    if type(GetShapeshiftForm) == "function" and (GetShapeshiftForm() or 0) ~= 0 then return false end
    if type(IsSwimming) == "function" and IsSwimming() then return false end
    if type(IsFalling) == "function" and IsFalling() then return false end
    if type(UnitOnTaxi) == "function" and UnitOnTaxi("player") then return false end
    if type(UnitIsDeadOrGhost) == "function" and UnitIsDeadOrGhost("player") then return false end
    return true
end
ns.CanAskMountUsability = caster

-- Even as a caster the answer can lag: right after leaving a form or getting off
-- a mount every mount still came back as not usable, and "(no mount)" stayed
-- (2026-11-22, again). A scan that finds none keeps the last choice and asks
-- again (a second later, and on the next usability change or stop) up to
-- MOUNT_RETRIES times in a row before it believes there is none.
local MOUNT_RETRIES = 5

local function inAirOrWater()
    return (type(IsFalling) == "function" and IsFalling()) or (type(IsSwimming) == "function" and IsSwimming())
end

-- one look again a second later (landing and leaving the water send no event)
local function retryLater()
    if ns.mountRetryTimer or not (C_Timer and type(C_Timer.After) == "function") then return end
    ns.mountRetryTimer = true
    C_Timer.After(1, function()
        ns.mountRetryTimer = nil
        if ns.RetryMountScan then ns.RetryMountScan() end
    end)
end

local function scanMount()
    ns.mountScanWaiting = nil
    local journal = C_MountJournal
    if not (journal and type(journal.GetMountIDs) == "function" and type(journal.GetMountInfoByID) == "function") then
        ns.mount = nil
        return
    end
    local ok, ids = pcall(journal.GetMountIDs)
    if not ok or type(ids) ~= "table" then return end
    local found
    for _, mountID in ipairs(ids) do
        local okInfo, name, spellID, icon, _, isUsable, _, isFavorite, _, _, hidden, collected =
            pcall(journal.GetMountInfoByID, mountID)
        if okInfo and collected and not hidden and type(spellID) == "number"
            and mountUsable(journal, mountID, isUsable) then
            local castName = spellInfo(spellID) or name
            if type(castName) == "string" and (not found or (isFavorite and not found.favorite)) then
                found = { name = castName, icon = icon, favorite = isFavorite and true or false, id = mountID }
            end
        end
    end
    if found then
        ns.mount, ns.mountRetries = found, 0
        return
    end
    -- none: in a form, mounted, swimming, falling or dead the "no" may not hold;
    -- keep the last choice and look again once back as a caster on the ground
    if not caster() then
        ns.mountScanWaiting = true
        ns.mountRetries = 0
        if inAirOrWater() then retryLater() end
        return
    end
    ns.mountRetries = (ns.mountRetries or 0) + 1
    if ns.mountRetries > MOUNT_RETRIES then
        ns.mount = nil
        return
    end
    ns.mountScanWaiting = true
    retryLater()
end

-- a scan that had to wait: ask again now if the game can answer (only the mount;
-- the buttons and the options are redone when the choice changed). anyState: ask
-- in a form too (a "yes" counts there)
function ns.RetryMountScan(anyState)
    if not ns.mountScanWaiting then return end
    if not anyState and not caster() then
        if inAirOrWater() then retryLater() end
        return
    end
    local before = ns.mount and ns.mount.id
    scanMount()
    if (ns.mount and ns.mount.id) ~= before and ns.Refresh then ns.Refresh() end
end

-- Reads the stance bar (only learned forms are on it), Prowl and the mount.
function ns.ScanForms()
    wipe(ns.forms)
    wipe(ns.kindAt)
    ns.formCount = 0
    scanProwl()
    scanMount()
    if type(GetNumShapeshiftForms) ~= "function" then return end
    local okCount, count = pcall(GetNumShapeshiftForms)
    count = okCount and tonumber(count) or 0
    ns.formCount = count
    for index = 1, count do
        local ok, icon, _, _, spellID = pcall(GetShapeshiftFormInfo, index)
        local kind
        if ok and type(spellID) == "number" then
            local name = spellInfo(spellID)
            kind = name and classify(spellID, name)
            if kind and not ns.forms[kind] then
                ns.forms[kind] = { index = index, name = name, icon = icon, spellID = spellID }
            else
                kind = nil
            end
        end
        ns.kindAt[index] = kind or "other"
    end
end

-- What you are now: "caster", "mount", a form kind, or "other".
function ns.CurrentState()
    if type(IsMounted) == "function" and IsMounted() then return "mount" end
    local index = type(GetShapeshiftForm) == "function" and GetShapeshiftForm() or 0
    if not index or index == 0 then return "caster" end
    return ns.kindAt[index] or "other"
end

local function isForm(state) return state ~= "caster" and state ~= "mount" end

-----------------------------------------------------------------------------
-- What a press does
-----------------------------------------------------------------------------
-- The form the combat press goes to ("caster" = no form).
function ns.CombatKind()
    local kind = ns.db.combatForm
    if kind ~= "caster" and not ns.forms[kind] then
        kind = ns.forms.bear and "bear" or (ns.forms.cat and "cat" or "caster")
    end
    return kind
end

-- Out of combat: the target in water, outdoors and indoors (nil = stay as you are).
-- noMount: the mount can't be used right now (moving, or not here): the land form
-- (Travel, else Cat, else Bear) instead.
local function placeKinds(noMount)
    local f, db = ns.forms, ns.db
    local land = (f.travel and "travel") or (f.cat and "cat") or (f.bear and "bear")
    local outdoor = land
    if db.outdoorForm == "mount" and ns.mount and not noMount then
        outdoor = "mount"
    elseif db.outdoorForm == "cat" then
        outdoor = (f.cat and "cat") or (f.bear and "bear")
    end
    local water = (db.useAquatic and f.aquatic and "aquatic") or (outdoor ~= "mount" and outdoor) or land
    local indoor = db.indoorCat and ((f.cat and "cat") or (f.bear and "bear")) or nil
    return water, outdoor, indoor
end

-- The cases of a press, in order (the first true one counts), for one state.
-- cond = "swimming" | "combat" | "stealth" | "outdoors" | nil (= any other case);
-- target = a form kind, "mount", "prowl", "caster" (leave the form) or nil (nothing);
-- mode = "keep" (already in it: stay), "toggle" (already in it: leave) or
-- "reshift" (already in it: leave and shift again).
local function cases(state, noMount)
    local f, db = ns.forms, ns.db
    local list = {}
    local function add(cond, target, mode)
        list[#list + 1] = { cond = cond, target = target, mode = mode or "keep" }
    end
    local swimForm = db.useAquatic and f.aquatic ~= nil
    if swimForm then add("swimming", "aquatic") end
    local combat = ns.CombatKind()
    add("combat", combat, (db.combatReshift and combat == state) and "reshift" or "keep")
    if state == "mount" then
        -- get off; with "combat ready" also take the combat form
        add(nil, db.combatPrep and combat or nil)
    elseif db.combatPrep and (state == "travel" or state == "aquatic") then
        add(nil, combat)
    elseif db.catProwl and state == "cat" and ns.prowl then
        add("stealth", nil)
        add(nil, "prowl")
    else
        local water, outdoor, indoor = placeKinds(noMount)
        if not swimForm and water then add("swimming", water, "toggle") end
        add("outdoors", outdoor, "toggle")
        add(nil, indoor, "toggle")
    end
    return list
end

local function castToken(kind)
    if kind == "mount" then return ns.mount.name end
    if kind == "prowl" then return "!" .. ns.prowl.name end
    return "!" .. ns.forms[kind].name
end

-- What one case does from a state: { dismount, cancel, cast, target }.
-- A form is always left first: casting another form straight from one only
-- spends mana here.
local function actionOf(state, case)
    local a = { dismount = state == "mount" or nil }
    local target = case.target
    if target == nil then return a end
    if target == "caster" then
        a.cancel = isForm(state) or nil
        return a
    end
    if target == "prowl" then
        a.cast, a.target = castToken("prowl"), "prowl"
        return a
    end
    if target == state then
        if case.mode == "toggle" then
            if state == "mount" then a.dismount = true else a.cancel = true end
        elseif case.mode == "reshift" then
            a.cancel, a.cast, a.target = true, castToken(target), target
        end
        return a
    end
    if isForm(state) then a.cancel = true end
    a.cast, a.target = castToken(target), target
    return a
end

local function modifierCase(kind)
    return { target = kind, mode = kind == "mount" and "toggle" or "keep" }
end

local NOT = { swimming = "noswimming", combat = "nocombat", stealth = "nostealth", outdoors = "indoors" }

-- Turns the cases into macro lines: /dismount, /cancelform and /stopmacro with the
-- conditions of the cases that need them, then one /cast with a clause per case.
local function assemble(list, actions)
    local n = #list
    -- each case's exact condition: its own, plus "not" every earlier one
    local exact, earlier = {}, {}
    for i, case in ipairs(list) do
        local atoms, seen = {}, {}
        local function push(atom)
            if not seen[atom] then seen[atom] = true atoms[#atoms + 1] = atom end
        end
        if case.cond then push(case.cond) end
        for _, cond in ipairs(earlier) do push(NOT[cond]) end
        exact[i] = atoms
        if case.cond then earlier[#earlier + 1] = case.cond end
    end
    local lines = {}
    -- cmd for the cases where flag(i) is true; the last cases in a row are written
    -- as "none of the earlier ones" (the list always ends with an "any other" case)
    local function line(cmd, flag)
        local any = false
        for i = 1, n do if flag(i) then any = true break end end
        if not any then return end
        local k = n + 1
        while k > 1 and flag(k - 1) do k = k - 1 end
        local parts = {}
        for i = 1, k - 1 do
            if flag(i) then parts[#parts + 1] = "[" .. table.concat(exact[i], ",") .. "]" end
        end
        if k <= n and k > 1 then
            local atoms, seen = {}, {}
            for i = 1, k - 1 do
                local neg = list[i].cond and NOT[list[i].cond]
                if neg and not seen[neg] then seen[neg] = true atoms[#atoms + 1] = neg end
            end
            parts[#parts + 1] = "[" .. table.concat(atoms, ",") .. "]"
        end
        local conds = (k == 1) and "" or table.concat(parts)
        lines[#lines + 1] = cmd .. (conds ~= "" and (" " .. conds) or "")
    end
    line("/dismount", function(i) return actions[i].dismount end)
    line("/cancelform", function(i) return actions[i].cancel end)
    -- a case that casts nothing must not fall through to a later case's cast
    local lastCast = 0
    for i = 1, n do if actions[i].cast then lastCast = i end end
    line("/stopmacro", function(i) return not actions[i].cast and i < lastCast end)
    local clauses = {}
    for i = 1, n do
        local token = actions[i].cast
        if token then
            local cond = list[i].cond and ("[" .. list[i].cond .. "]") or ""
            local last = clauses[#clauses]
            if last and last.token == token then
                -- same spell as the clause before: one clause with either condition
                last.cond = (cond == "") and "" or (last.cond .. cond)
            else
                clauses[#clauses + 1] = { cond = cond, token = token }
            end
        end
    end
    if #clauses > 0 then
        local parts = {}
        for _, c in ipairs(clauses) do
            parts[#parts + 1] = (c.cond ~= "" and (c.cond .. " ") or "") .. c.token
        end
        lines[#lines + 1] = "/cast " .. table.concat(parts, "; ")
    end
    return table.concat(lines, "\n")
end

-- The macro for a press without Shift/Ctrl/Alt, from one state (default: now).
-- noMount: the variant for when the mount can't be used (default: now).
function ns.BuildMacro(state, noMount)
    state = state or ns.CurrentState()
    if noMount == nil then noMount = ns.mountBlocked end
    local list, actions = cases(state, noMount), {}
    for i, case in ipairs(list) do actions[i] = actionOf(state, case) end
    return assemble(list, actions)
end

local function actionMacro(a)
    local lines = {}
    if a.dismount then lines[#lines + 1] = "/dismount" end
    if a.cancel then lines[#lines + 1] = "/cancelform" end
    if a.cast then lines[#lines + 1] = "/cast " .. a.cast end
    return table.concat(lines, "\n") -- "" = do nothing (stay)
end

-- Shift / Ctrl = the chosen form (or mount), Alt = leave the form or get off.
-- Put on the buttons as shift-/ctrl-/alt- attributes: the game picks the one for
-- the keys held, also in combat.
function ns.ModifierMacros(state)
    state = state or ns.CurrentState()
    local db, mods = ns.db, {}
    if not db.useModifiers then return mods end
    for _, mod in ipairs({ "shift", "ctrl" }) do
        local kind = db[mod .. "Form"]
        if kind and ns.Available(kind) then mods[mod] = actionMacro(actionOf(state, modifierCase(kind))) end
    end
    mods.alt = state == "mount" and "/dismount" or (isForm(state) and "/cancelform" or "")
    return mods
end

-----------------------------------------------------------------------------
-- Form wheel: hold the key and a ring of forms opens at the mouse; move toward
-- one and let go. A tap, or letting go in the middle, does the usual press.
-- Also in combat: the game's secure code places an invisible area at the
-- cursor on the press and reads the mouse direction in it on the release.
-- What is drawn is a separate frame that only follows that area.
-----------------------------------------------------------------------------
local WHEEL_ORDER = { "bear", "cat", "travel", "mount", "aquatic", "moonkin", "caster" }  -- clockwise from the top
local WHEEL_MAX = #WHEEL_ORDER
local WHEEL_RADIUS = 96   -- ring of icons
local WHEEL_DEAD = 36     -- the middle: the usual press
local WHEEL_AREA = 2400   -- size of the invisible area (always around the mouse)

-- what is on the wheel now
function ns.WheelItems()
    local list = {}
    for _, kind in ipairs(WHEEL_ORDER) do
        if ns.Available(kind) then list[#list + 1] = kind end
    end
    return list
end

-- the item a mouse offset from the middle points at (0 = the middle); the same
-- sums as WHEEL_SNIPPET
function ns.WheelSector(dx, dy, n, dead)
    if n < 2 or dx * dx + dy * dy < dead * dead then return 0 end
    local a = math.atan2(dx, dy)
    if a < 0 then a = a + 2 * math.pi end
    return math.floor(a / (2 * math.pi) * n + 0.5) % n + 1
end

-- Runs in the game's secure code before the key button acts (also in combat).
-- Press: open the area at the mouse, do nothing yet. Release: the item the
-- mouse points at is the button "w<n>" (its macro is "*macrotext-w<n>").
-- Released in the middle: a tap is the usual press; a long hold does nothing.
-- The secure code has no clock, so "long" is: held past WHEEL_HOLD (marked by
-- the addon, out of combat only), or the mouse left the middle and came back
-- (secure "mouse entered" handlers of the strips around the middle; also in combat).
-- A press with Shift/Ctrl/Alt is the usual press with that key.
local WHEEL_SNIPPET = [[
    if not owner:GetAttribute("wheelon") then return end
    local area = owner:GetFrameRef("wheel")
    if down then
        -- a repeated press while held keeps the middle where it opened
        if area:IsShown() then return false end
        if owner:GetAttribute("keymods") and IsModifierKeyDown() then return false end
        owner:SetAttribute("wlong", nil)
        area:SetAttribute("moved", nil)
        area:ClearAllPoints()
        area:SetPoint("CENTER", "$cursor")
        area:Show()
        return false
    end
    if not area:IsShown() then return end
    local x, y = area:GetMousePosition()
    area:Hide()
    local long = owner:GetAttribute("wlong") or area:GetAttribute("moved")
    if not x then
        if long then return false end
        return
    end
    local size, dead = owner:GetAttribute("wsize"), owner:GetAttribute("wdead")
    local n = owner:GetAttribute("wn") or 0
    local dx, dy = (x - 0.5) * size, (y - 0.5) * size
    if n < 2 or dx * dx + dy * dy < dead * dead then
        if long then return false end
        return
    end
    local a = math.atan2(dx, dy)
    if a < 0 then a = a + 2 * math.pi end
    return "w" .. (math.floor(a / (2 * math.pi) * n + 0.5) % n + 1)
]]

-- Text for the settings window: the macros for what you are now.
function ns.MacroPreview()
    local text = { ns.BuildMacro() }
    local mods = ns.ModifierMacros()
    for _, mod in ipairs(ns.MODIFIERS) do
        if mods[mod] and mods[mod] ~= "" then
            text[#text + 1] = "\n" .. mod:sub(1, 1):upper() .. mod:sub(2) .. ":\n" .. mods[mod]
        end
    end
    return table.concat(text, "\n")
end

-----------------------------------------------------------------------------
-- Button
-----------------------------------------------------------------------------
local function rgba(c) return c[1], c[2], c[3], c[4] or 1 end

local function keyDownMode()
    if C_CVar and type(C_CVar.GetCVarBool) == "function" then
        local ok, value = pcall(C_CVar.GetCVarBool, "ActionButtonUseKeyDown")
        if ok then return value and true or false end
    end
    return type(GetCVarBool) == "function" and GetCVarBool("ActionButtonUseKeyDown") and true or false
end

function ns.BindingName()
    return "CLICK " .. ns.BUTTON_NAME .. ":LeftButton"
end

function ns.GetBoundKey()
    if type(GetBindingKey) ~= "function" then return nil end
    return (GetBindingKey(ns.BindingName()))
end

local function shortKey(key)
    if not key then return "" end
    key = key:gsub("SHIFT%-", "S"):gsub("CTRL%-", "C"):gsub("ALT%-", "A")
    key = key:gsub("MOUSEWHEELUP", "MwU"):gsub("MOUSEWHEELDOWN", "MwD"):gsub("BUTTON", "M")
    key = key:gsub("NUMPAD", "N")
    return key
end

-- A button's macro text holds at most 255 bytes (Korean names take 3 bytes a
-- letter). A longer macro (only in case: each one is short) is cut into parts:
-- each part ends with /click on a hidden button that runs the next part, so a
-- /stopmacro still ends the whole macro (the /click after it is never reached).
-- Each state has its own hidden buttons.
local MACRO_LIMIT = 255
local chainSets = {}

local function chainName(tag, index)
    return ns.BUTTON_NAME .. "Part" .. tag .. "_" .. index
end

local function chainButton(tag, index)
    local set = chainSets[tag]
    if not set then
        set = {}
        chainSets[tag] = set
    end
    local b = set[index]
    if not b then
        b = CreateFrame("Button", chainName(tag, index), UIParent, "SecureActionButtonTemplate")
        b:SetSize(1, 1)
        b:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -10, 10)
        b:RegisterForClicks("AnyUp", "AnyDown")
        b:SetAttribute("type", "macro")
        -- a plain "/click <name>" is a release: this button acts on release whatever
        -- the "cast on key down" setting, so the chain does not depend on it
        b:SetAttribute("useOnKeyDown", false)
        set[index] = b
    end
    return b
end

local function clearChain(tag, from)
    local set = chainSets[tag]
    if not set then return end
    for index = from, #set do set[index]:SetAttribute("macrotext", "") end
end

-- Returns the first part; the rest go onto the state's hidden buttons. Protected: out of combat.
local function splitMacro(macro, tag)
    if #macro <= MACRO_LIMIT then
        clearChain(tag, 1)
        return macro
    end
    local lines = {}
    for line in macro:gmatch("[^\n]+") do lines[#lines + 1] = line end
    local parts, current = {}, {}
    local size = 0
    local reserve = #("/click " .. chainName(tag, 99)) + 1 -- room for the "/click <next>" line
    for _, line in ipairs(lines) do
        if size > 0 and size + 1 + #line > MACRO_LIMIT - reserve then
            parts[#parts + 1] = current
            current, size = {}, 0
        end
        current[#current + 1] = line
        size = size + (size > 0 and 1 or 0) + #line
    end
    if #current > 0 then parts[#parts + 1] = current end
    for index = #parts - 1, 1, -1 do
        table.insert(parts[index], "/click " .. chainName(tag, index))
    end
    for index = 2, #parts do
        chainButton(tag, index - 1):SetAttribute("macrotext", table.concat(parts[index], "\n"))
    end
    clearChain(tag, #parts)
    return table.concat(parts[1] or {}, "\n")
end

-- States the driver tells apart: mounted, each stance bar form, caster.
local function stateList()
    local list = { { id = "m", cond = "[mounted]", state = "mount" } }
    for index = 1, ns.formCount do
        list[#list + 1] = { id = tostring(index), cond = "[form:" .. index .. "]", state = ns.kindAt[index] or "other" }
    end
    list[#list + 1] = { id = "0", state = "caster" }
    return list
end

local function driverText(list)
    local parts = {}
    for _, s in ipairs(list) do parts[#parts + 1] = (s.cond and (s.cond .. " ") or "") .. s.id end
    return table.concat(parts, "; ")
end

-- Runs in the game's secure code when the state changes (also in combat): puts that
-- state's macros on the key button and the visible button.
local STATE_SNIPPET = [[
    local key, bar = self:GetFrameRef("key"), self:GetFrameRef("bar")
    local keyMods = self:GetAttribute("keymods")
    local main = (self:GetAttribute("nomount") and self:GetAttribute("pm-" .. newstate)) or self:GetAttribute("p-" .. newstate)
    key:SetAttribute("macrotext", main)
    bar:SetAttribute("*macrotext1", main)
    local m = self:GetAttribute("shift-" .. newstate)
    bar:SetAttribute("shift-macrotext1", m)
    key:SetAttribute("shift-macrotext1", keyMods and m or nil)
    m = self:GetAttribute("ctrl-" .. newstate)
    bar:SetAttribute("ctrl-macrotext1", m)
    key:SetAttribute("ctrl-macrotext1", keyMods and m or nil)
    m = self:GetAttribute("alt-" .. newstate)
    bar:SetAttribute("alt-macrotext1", m)
    key:SetAttribute("alt-macrotext1", keyMods and m or nil)
    for i = 1, (self:GetAttribute("wn") or 0) do
        key:SetAttribute("*macrotext-w" .. i, self:GetAttribute("w" .. i .. "-" .. newstate))
    end
]]

-- the same as STATE_SNIPPET, from the addon (out of combat)
local function applyState(id)
    local keyMods = header:GetAttribute("keymods")
    local main = (header:GetAttribute("nomount") and header:GetAttribute("pm-" .. id)) or header:GetAttribute("p-" .. id)
    keyButton:SetAttribute("macrotext", main)
    button:SetAttribute("*macrotext1", main)
    for _, mod in ipairs(ns.MODIFIERS) do
        local m = header:GetAttribute(mod .. "-" .. id)
        button:SetAttribute(mod .. "-macrotext1", m)
        keyButton:SetAttribute(mod .. "-macrotext1", (keyMods and m) or nil)
    end
    for i = 1, (header:GetAttribute("wn") or 0) do
        keyButton:SetAttribute("*macrotext-w" .. i, header:GetAttribute("w" .. i .. "-" .. id))
    end
end

local function currentStateId(driver)
    if type(SecureCmdOptionParse) == "function" then
        local ok, id = pcall(SecureCmdOptionParse, driver)
        if ok and type(id) == "string" and id ~= "" then return id end
    end
    if type(IsMounted) == "function" and IsMounted() then return "m" end
    return tostring(type(GetShapeshiftForm) == "function" and GetShapeshiftForm() or 0)
end

-- Applies the macros to both buttons, plus the visible button's look and place.
-- Protected: out of combat.
function ns.ApplyButton()
    if not button then return end
    ns.RunAfterCombat("button", function()
        local db = ns.db
        -- key button: follows the "cast on key down" setting. A key bound with
        -- Shift/Ctrl/Alt (e.g. SHIFT-E) gets no modifier macros: that modifier is
        -- down on every press, so its macro would always win.
        local boundKey = ns.GetBoundKey()
        local keyMods = not (boundKey and boundKey:find("%-"))
        -- the wheel needs the press and the release; it acts on the release
        local wheelKinds = ns.WheelItems()
        local useWheel = db.useWheel and #wheelKinds >= 2
        if useWheel then
            keyButton:RegisterForClicks("AnyDown", "AnyUp")
            keyButton:SetAttribute("useOnKeyDown", false)
        else
            keyButton:RegisterForClicks(keyDownMode() and "AnyDown" or "AnyUp")
            keyButton:SetAttribute("useOnKeyDown", nil)
            wheelArea:Hide()
        end
        keyButton:SetAttribute("type", "macro")
        -- visible button: left = the macro ("*" = any keys held) or the Shift/Ctrl/Alt
        -- one, right = quick menu (no secure action)
        button:SetAttribute("*type1", "macro")
        header:SetFrameRef("key", keyButton)
        header:SetFrameRef("bar", button)
        header:SetAttribute("keymods", keyMods)
        header:SetAttribute("_onstate-df", STATE_SNIPPET)
        local states = stateList()
        -- outdoors on a mount: a second set for when the mount can't be used (moving,
        -- or not here); ns.UpdateMountBlock picks the set out of combat
        local mountVariant = db.outdoorForm == "mount" and ns.mount ~= nil
        header:SetAttribute("nomount", mountVariant and ns.mountBlocked or nil)
        for _, s in ipairs(states) do
            header:SetAttribute("pm-" .. s.id, mountVariant and splitMacro(ns.BuildMacro(s.state, true), s.id .. "m") or nil)
            header:SetAttribute("p-" .. s.id, splitMacro(ns.BuildMacro(s.state, false), s.id))
            local mods = ns.ModifierMacros(s.state)
            for _, mod in ipairs(ns.MODIFIERS) do header:SetAttribute(mod .. "-" .. s.id, mods[mod]) end
        end
        -- wheel: item i from each state (like Shift/Ctrl: the chosen form, or get on/off the mount)
        header:SetAttribute("wheelon", useWheel)
        header:SetAttribute("wn", useWheel and #wheelKinds or 0)
        header:SetAttribute("wsize", WHEEL_AREA)
        header:SetAttribute("wdead", WHEEL_DEAD)
        for i = 1, WHEEL_MAX do
            local kind = useWheel and wheelKinds[i] or nil
            keyButton:SetAttribute("*type-w" .. i, kind and "macro" or nil)
            if not kind then keyButton:SetAttribute("*macrotext-w" .. i, nil) end
            for _, s in ipairs(states) do
                header:SetAttribute("w" .. i .. "-" .. s.id,
                    kind and actionMacro(actionOf(s.state, modifierCase(kind))) or nil)
            end
        end
        if ns.RefreshWheelView then ns.RefreshWheelView(useWheel and wheelKinds or {}) end
        local driver = driverText(states)
        ns.driver = driver
        RegisterStateDriver(header, "df", driver)
        -- the driver reports changes only: put the current state's macros on now
        applyState(currentStateId(driver))
        button:SetSize(db.buttonSize, db.buttonSize)
        button:ClearAllPoints()
        local pos = db.buttonPos
        if type(pos) == "table" and pos[1] then
            button:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
        else
            button:SetPoint("CENTER", UIParent, "CENTER", 0, -230)
        end
        button:SetAlpha(db.showButton and 1 or 0)
        button:EnableMouse(db.showButton and true or false)
        -- no icon prediction while the button is hidden
        button:SetScript("OnUpdate", db.showButton and iconOnUpdate or nil)
        if db.showButton and iconOnUpdate then iconOnUpdate(button, 1) end
        button.hotkey:SetText(shortKey(ns.GetBoundKey()))
        button.combat:SetText(ns:L("short_" .. ns.CombatKind()))
        if ns.RefreshQuickMenu then ns.RefreshQuickMenu() end
    end)
end

-----------------------------------------------------------------------------
-- Mount or not: a mount can't be summoned while moving, nor where mounts are
-- not allowed, and a macro can't tell "moving". Out of combat the key's macros
-- follow it: the outdoor mount press then takes the land form (Travel, else Cat).
-- (The outdoor press is an out-of-combat case, so combat never needs it.)
-----------------------------------------------------------------------------
ns.moving = false
ns.mountBlocked = false
local mountHere = true

-- where you stand allows the mount (asked only as a caster: forms and riding change the answer)
local function readMountHere()
    local m, journal = ns.mount, C_MountJournal
    if not (m and m.id and journal and type(journal.GetMountUsabilityByID) == "function") then return true end
    if (type(IsMounted) == "function" and IsMounted())
        or (type(GetShapeshiftForm) == "function" and (GetShapeshiftForm() or 0) ~= 0) then
        return mountHere
    end
    local ok, usable = pcall(journal.GetMountUsabilityByID, m.id, false)
    if ok and type(usable) == "boolean" then return usable end
    return true
end

function ns.UpdateMountBlock()
    if not header or ns.InCombat() then return end
    mountHere = readMountHere()
    local blocked = ns.moving or not mountHere
    if blocked == ns.mountBlocked then return end
    ns.mountBlocked = blocked
    -- only with the mount as the outdoor choice is there a second set
    if not header:GetAttribute("pm-0") then return end
    header:SetAttribute("nomount", blocked or nil)
    applyState(currentStateId(ns.driver or ""))
end

local function condNow(cond)
    if cond == nil then return true end
    if cond == "swimming" then return (IsSwimming and IsSwimming()) and true or false end
    if cond == "combat" then
        return ns.InCombat() or ((UnitAffectingCombat and UnitAffectingCombat("player")) and true or false)
    end
    if cond == "stealth" then return (IsStealthed and IsStealthed()) and true or false end
    if cond == "outdoors" then return (IsOutdoors and IsOutdoors()) and true or false end
    return false
end

local function iconOf(kind)
    if kind == nil or kind == "caster" or kind == "other" then return CASTER_ICON end
    if kind == "mount" then return ns.mount and ns.mount.icon or FALLBACK_ICON end
    if kind == "prowl" then return ns.prowl and ns.prowl.icon or FALLBACK_ICON end
    local form = ns.forms[kind]
    return form and form.icon or FALLBACK_ICON
end

-- Icon of what the next press will do (shown only; the macros decide), worked out
-- with the same cases as the macros.
local function predictIcon()
    if not next(ns.forms) then return FALLBACK_ICON end
    local db = ns.db
    local state = ns.CurrentState()
    local a
    if db.useModifiers then
        if IsAltKeyDown() then return CASTER_ICON end
        local kind = (IsShiftKeyDown() and db.shiftForm) or (IsControlKeyDown() and db.ctrlForm) or nil
        if kind and ns.Available(kind) then a = actionOf(state, modifierCase(kind)) end
    end
    if not a then
        for _, case in ipairs(cases(state, ns.mountBlocked)) do
            if condNow(case.cond) then
                a = actionOf(state, case)
                break
            end
        end
    end
    if a and a.cast then return iconOf(a.target) end
    if a and (a.cancel or a.dismount) then return CASTER_ICON end
    return iconOf(state) -- stays as it is
end

local function kindLabel(kind)
    return kind and ns:L("form_" .. kind) or ns:L("form_none")
end

-----------------------------------------------------------------------------
-- What the wheel draws: a ring of icons with names around the middle (the
-- usual press). Not anchored to the secure area (that would make it secure
-- too): it reads where the area opened and goes there, also in combat.
-----------------------------------------------------------------------------
local WHEEL_ICON = 38
local WHEEL_HOLD = 0.2   -- a hold: the wheel shows, and the middle no longer does the usual press
local ROUND_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local CANCEL_ICON = "Interface\\RaidFrame\\ReadyCheck-NotReady"

local function roundTexture(parent, layer, size, sublevel)
    local t = parent:CreateTexture(nil, layer, nil, sublevel or 0)
    t:SetSize(size, size)
    if parent.CreateMaskTexture and t.AddMaskTexture then
        local mask = parent:CreateMaskTexture()
        mask:SetTexture(ROUND_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(t)
        t:AddMaskTexture(mask)
    end
    return t
end

local function buildWheelView()
    local S = ns.Style
    local size = (WHEEL_RADIUS + 46) * 2
    local v = CreateFrame("Frame", nil, UIParent)
    v:SetSize(size, size)
    v:SetFrameStrata("FULLSCREEN_DIALOG")
    v:EnableMouse(false)
    v:Hide()
    local rim = roundTexture(v, "BACKGROUND", size)
    rim:SetPoint("CENTER")
    -- see-through: the game world stays visible behind the wheel
    rim:SetColorTexture(S.accent[1], S.accent[2], S.accent[3], 0.22)
    local disc = roundTexture(v, "BORDER", size - 4)
    disc:SetPoint("CENTER")
    disc:SetColorTexture(0.04, 0.04, 0.05, 0.3)
    v.hub = roundTexture(v, "ARTWORK", WHEEL_DEAD * 2, 0)
    v.hub:SetPoint("CENTER")
    v.hub:SetColorTexture(0.18, 0.18, 0.2, 0.4)
    v.hubIcon = roundTexture(v, "ARTWORK", 30, 2)
    v.hubIcon:SetPoint("CENTER")
    v.items = {}
    for i = 1, WHEEL_MAX do
        local item = {}
        item.glow = roundTexture(v, "ARTWORK", WHEEL_ICON + 16, 1)
        item.glow:SetColorTexture(S.accent[1], S.accent[2], S.accent[3], 0.45)
        item.icon = roundTexture(v, "ARTWORK", WHEEL_ICON, 3)
        item.label = v:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        local path, fontSize = item.label:GetFont()
        if path then item.label:SetFont(path, fontSize, "OUTLINE") end
        v.items[i] = item
    end
    v.kinds = {}
    return v
end

local function setWheelHover(sel)
    local v = wheelView
    if v.sel == sel then return end
    v.sel = sel
    local S = ns.Style
    for i, item in ipairs(v.items) do
        local on = i == sel
        item.glow:SetShown(on and i <= #v.kinds)
        item.icon:SetAlpha(on and 1 or 0.72)
        item.icon:SetSize(on and WHEEL_ICON + 8 or WHEEL_ICON, on and WHEEL_ICON + 8 or WHEEL_ICON)
        if on then item.label:SetTextColor(rgba(S.accent)) else item.label:SetTextColor(1, 1, 1, 1) end
    end
    if sel == 0 then
        v.hub:SetColorTexture(S.accent[1], S.accent[2], S.accent[3], 0.4)
    else
        v.hub:SetColorTexture(0.18, 0.18, 0.2, 0.4)
    end
end

-- the items (out of combat, when the forms or settings change)
function ns.RefreshWheelView(kinds)
    if not wheelView then return end
    local v = wheelView
    v.kinds = kinds
    local n = #kinds
    for i, item in ipairs(v.items) do
        local kind = kinds[i]
        item.icon:SetShown(kind ~= nil)
        item.label:SetShown(kind ~= nil)
        item.glow:Hide()
        if kind then
            local angle = (i - 1) / n * 2 * math.pi
            local sx, cy = math.sin(angle), math.cos(angle)
            item.icon:ClearAllPoints()
            item.icon:SetPoint("CENTER", v, "CENTER", sx * WHEEL_RADIUS, cy * WHEEL_RADIUS)
            item.glow:ClearAllPoints()
            item.glow:SetPoint("CENTER", item.icon, "CENTER")
            item.icon:SetTexture(iconOf(kind))
            item.label:SetText(ns:L("form_" .. kind))
            -- the name outside its icon
            local lx, ly = sx * (WHEEL_RADIUS + 28), cy * (WHEEL_RADIUS + 28)
            local point = (sx > 0.35 and "LEFT") or (sx < -0.35 and "RIGHT") or (cy > 0 and "BOTTOM") or "TOP"
            item.label:ClearAllPoints()
            item.label:SetPoint(point, v, "CENTER", lx, ly)
        end
    end
    v.sel = nil
end

-- Follows the secure area: opens where it opened (after a short hold) and
-- lights the item the mouse points at, with the same sums as the release.
local function watchWheel()
    local v = wheelView
    if not wheelArea:IsShown() then
        if v.since then
            v.since = nil
            v:Hide()
        end
        return
    end
    local now = GetTime()
    if not v.since then
        v.since = now
        v.long, v.movedOut, v.cancelShown = false, false, nil
        local cx, cy = wheelArea:GetCenter()
        v.cx, v.cy = cx, cy
        if cx and cy then
            v:ClearAllPoints()
            v:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx, cy)
        end
        v.defaultIcon = predictIcon()
        v.sel = nil
    end
    if not (v.cx and v.cy) or #v.kinds < 2 then return end
    if now - v.since < WHEEL_HOLD then return end
    -- a hold: the middle does nothing now (the secure release reads this mark;
    -- in combat it can't be set, and only moving out and back counts)
    if not v.long and not ns.InCombat() then
        v.long = true
        header:SetAttribute("wlong", true)
    end
    if not v:IsShown() then v:Show() end
    local scale = UIParent:GetEffectiveScale() or 1
    local mx, my = GetCursorPosition()
    local dx, dy = mx / scale - v.cx, my / scale - v.cy
    if dx * dx + dy * dy >= WHEEL_DEAD * WHEEL_DEAD then v.movedOut = true end
    local cancel = v.long or v.movedOut
    if v.cancelShown ~= cancel then
        v.cancelShown = cancel
        v.hubIcon:SetTexture(cancel and CANCEL_ICON or v.defaultIcon)
    end
    setWheelHover(ns.WheelSector(dx, dy, #v.kinds, WHEEL_DEAD))
end

local function createWheel()
    -- invisible, secure (the secure code may only move protected frames in combat)
    wheelArea = CreateFrame("Frame", "EzWoWDruidFormsWheelArea", UIParent, "SecureFrameTemplate")
    wheelArea:SetSize(WHEEL_AREA, WHEEL_AREA)
    wheelArea:SetPoint("CENTER")
    wheelArea:EnableMouse(false)
    wheelArea:Hide()
    header:SetFrameRef("wheel", wheelArea)
    -- Four strips around the middle (only there while the key is held): the
    -- mouse moving into one marks the hold as "left the middle", in secure code.
    -- (A frame that opens under the mouse gets no "moved in" for its own area,
    -- so the middle itself can't tell when the mouse leaves it.)
    local d = WHEEL_DEAD
    local corners = {
        { "TOPLEFT", "TOPLEFT", 0, 0, "BOTTOMRIGHT", "BOTTOM", -d, 0 },   -- left
        { "TOPRIGHT", "TOPRIGHT", 0, 0, "BOTTOMLEFT", "BOTTOM", d, 0 },   -- right
        { "TOPLEFT", "TOP", -d, 0, "BOTTOMRIGHT", "CENTER", d, d },       -- above
        { "TOPLEFT", "CENTER", -d, -d, "BOTTOMRIGHT", "BOTTOM", d, 0 },   -- below
    }
    for _, c in ipairs(corners) do
        local strip = CreateFrame("Frame", nil, wheelArea, "SecureHandlerEnterLeaveTemplate")
        strip:SetPoint(c[1], wheelArea, c[2], c[3], c[4])
        strip:SetPoint(c[5], wheelArea, c[6], c[7], c[8])
        strip:EnableMouse(true)
        strip:SetFrameRef("area", wheelArea)
        strip:SetAttribute("_onenter", [[ self:GetFrameRef("area"):SetAttribute("moved", true) ]])
    end
    if type(SecureHandlerWrapScript) == "function" then
        pcall(SecureHandlerWrapScript, keyButton, "OnClick", header, WHEEL_SNIPPET)
    end
    wheelView = buildWheelView()
    local watcher = CreateFrame("Frame")
    watcher:SetScript("OnUpdate", watchWheel)
end

local function createButtons()
    -- hidden button the key binding clicks
    keyButton = CreateFrame("Button", ns.BUTTON_NAME, UIParent, "SecureActionButtonTemplate")
    keyButton:SetSize(1, 1)
    keyButton:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -10, 10)
    -- follows what you are now and swaps the macros
    header = CreateFrame("Frame", nil, UIParent, "SecureHandlerStateTemplate")
    createWheel()

    button = CreateFrame("Button", "EzWoWDruidFormsBar", UIParent, "SecureActionButtonTemplate,BackdropTemplate")
    button:SetMovable(true)
    button:SetClampedToScreen(true)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    ns.UIKit:ApplyBackdrop(button, 1, 0)
    button:SetBackdropColor(rgba(ns.Style.bgSecondary))
    button:SetBackdropBorderColor(rgba(ns.Style.border))
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetPoint("TOPLEFT", 2, -2)
    button.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local hl = button:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(button.icon)
    hl:SetColorTexture(1, 1, 1, 0.15)
    button.hotkey = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmallGray")
    button.hotkey:SetPoint("TOPRIGHT", -3, -3)
    -- combat choice in the corner (bear / cat ...), handy for feral druids
    button.combat = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    button.combat:SetPoint("BOTTOMLEFT", 3, 3)
    local path, size = button.combat:GetFont()
    if path then button.combat:SetFont(path, size, "OUTLINE") end
    button.combat:SetTextColor(rgba(ns.Style.accent))

    -- Ctrl + drag moves it; the click that ends a drag does nothing
    button:SetScript("OnDragStart", function(self)
        if ns.InCombat() or not IsControlKeyDown() then return end
        self.moving = true
        self:StartMoving()
    end)
    button:SetScript("OnDragStop", function(self)
        if not self.moving then return end
        self:StopMovingOrSizing()
        self.moving = false
        local point, _, relPoint, x, y = self:GetPoint(1)
        ns.db.buttonPos = { point, relPoint, math.floor((x or 0) + 0.5), math.floor((y or 0) + 0.5) }
        self.justMoved = true
        C_Timer.After(0.2, function() self.justMoved = false end)
    end)
    button:SetScript("PreClick", function(self)
        if self.justMoved and not ns.InCombat() then self:SetAttribute("*type1", nil) end
    end)
    button:SetScript("PostClick", function(self, mouse)
        if self.justMoved and not ns.InCombat() then self:SetAttribute("*type1", "macro") end
        if mouse == "RightButton" and ns.ToggleQuickMenu then ns.ToggleQuickMenu(self) end
    end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(ns.TITLE, rgba(ns.Style.accent))
        local key = ns.GetBoundKey()
        GameTooltip:AddLine(key and string.format(ns:L("tipKey"), key) or ns:L("tipNoKey"), rgba(ns.Style.textBody))
        GameTooltip:AddLine(string.format(ns:L("tipCombat"), ns:L("form_" .. ns.CombatKind())), rgba(ns.Style.textBody))
        local water, outdoor, indoor = placeKinds(ns.mountBlocked)
        GameTooltip:AddLine(string.format(ns:L("tipPlace"), kindLabel(water), kindLabel(outdoor), kindLabel(indoor)),
            0.75, 0.8, 0.85, true)
        GameTooltip:AddLine(ns:L("tipMouse"), rgba(ns.Style.accent))
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local elapsed = 0
    iconOnUpdate = function(self, dt)
        elapsed = elapsed + dt
        if elapsed < 0.15 then return end
        elapsed = 0
        self.icon:SetTexture(predictIcon())
    end
    button:SetScript("OnUpdate", iconOnUpdate)
end

-----------------------------------------------------------------------------
-- Settings lists (quick menu and settings window): check boxes for on/off,
-- radio buttons for picking one
-----------------------------------------------------------------------------
-- off = shown greyed (its switch is off); need = what it needs to be used
function ns.ChoiceRows()
    local modsOff = not ns.db.useModifiers
    return {
        { header = "secCombat" },
        { radio = "combatForm", choices = ns.COMBAT_CHOICES },
        { check = "combatReshift" },
        { header = "secPlace" },
        { check = "useAquatic", need = "aquatic" },
        { radio = "outdoorForm", prefix = "outdoorPrefix", choices = ns.OUTDOOR_CHOICES },
        { check = "indoorCat" },
        { check = "combatPrep" },
        { check = "catProwl", need = "prowl" },
        { header = "secWheel" },
        { check = "useWheel" },
        { header = "secMods" },
        { check = "useModifiers" },
        { radio = "shiftForm", prefix = "modShift", choices = ns.MOD_CHOICES, off = modsOff },
        { radio = "ctrlForm", prefix = "modCtrl", choices = ns.MOD_CHOICES, off = modsOff },
    }
end

function ns.SettingChanged()
    ns.ApplyButton()
    if ns.RefreshOptions then ns.RefreshOptions() end
    if ns.RefreshQuickMenu then ns.RefreshQuickMenu() end
end

-- Makes the widgets of one settings list once. fonts = { header =, text = }.
function ns.BuildChoiceWidgets(parent, fonts, boxSize)
    local widgets = {}
    for i, row in ipairs(ns.ChoiceRows()) do
        local w = {}
        if row.header then
            w.fs = parent:CreateFontString(nil, "OVERLAY", fonts.header)
            w.fs:SetJustifyH("LEFT")
        elseif row.check then
            local key = row.check
            w.choice = ns.UIKit:CreateChoice(parent, "check", fonts.text, boxSize)
            w.choice:SetScript("OnClick", function()
                ns.db[key] = not ns.db[key]
                ns.SettingChanged()
            end)
        else
            local key = row.radio
            if row.prefix then
                w.prefix = parent:CreateFontString(nil, "OVERLAY", fonts.text)
                w.prefix:SetJustifyH("LEFT")
            end
            w.choices = {}
            for j, kind in ipairs(row.choices) do
                local c = ns.UIKit:CreateChoice(parent, "radio", fonts.text, boxSize)
                c:SetScript("OnClick", function()
                    ns.db[key] = kind
                    ns.SettingChanged()
                end)
                w.choices[j] = c
            end
        end
        widgets[i] = w
    end
    return widgets
end

-- Fills and places a settings list from (x, y) inside width; returns the height used.
-- opts: gapX, gapY, headerH, sectionGap, headerX (header offset), line (draw a rule
-- under each header, as in the settings window).
function ns.LayoutChoiceWidgets(parent, widgets, x, y, width, opts)
    local db, S = ns.db, ns.Style
    local top = y
    for i, row in ipairs(ns.ChoiceRows()) do
        local w = widgets[i]
        if row.header then
            if y ~= top then y = y - opts.sectionGap end
            w.fs:ClearAllPoints()
            w.fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x + (opts.headerX or 0), y)
            w.fs:SetText(ns:L(row.header))
            w.fs:SetTextColor(rgba(S.accent))
            if opts.line then
                if not w.line then
                    w.line = parent:CreateTexture(nil, "ARTWORK")
                    w.line:SetColorTexture(S.border[1], S.border[2], S.border[3], 0.85)
                    w.line:SetHeight(1)
                end
                w.line:ClearAllPoints()
                w.line:SetPoint("TOPLEFT", parent, "TOPLEFT", x + (opts.headerX or 0), y - 20)
                w.line:SetPoint("TOPRIGHT", parent, "TOPLEFT", x + (opts.headerX or 0) + width, y - 20)
            end
            y = y - opts.headerH
        elseif row.check then
            local enabled = not row.off and (not row.need or ns.Available(row.need))
            w.choice:Set(ns.FormLabel(ns:L("opt_" .. row.check), row.need), db[row.check] and true or false, enabled)
            local _, h = w.choice:Layout(width)
            w.choice:ClearAllPoints()
            w.choice:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
            y = y - h - opts.gapY
        else
            local selected = row.radio == "combatForm" and ns.CombatKind() or db[row.radio]
            for j, kind in ipairs(row.choices) do
                w.choices[j]:Set(ns.FormLabel(ns:L("form_" .. kind), kind), selected == kind,
                    not row.off and ns.Available(kind))
            end
            if w.prefix then
                w.prefix:SetText(ns:L(row.prefix))
                w.prefix:SetTextColor(rgba(row.off and S.disabled or S.textBody))
            end
            local h = ns.UIKit:FlowChoices(parent, w.prefix, w.choices, x, y, width, opts.gapX, opts.gapY)
            y = y - h - opts.gapY
        end
    end
    return top - y
end

-----------------------------------------------------------------------------
-- Quick menu (right-click on the button)
-----------------------------------------------------------------------------
local menu
local MENU_W = 270
local MENU_FONTS = { header = "GameFontNormalSmall", text = "GameFontHighlightSmall" }

local function buildMenu()
    menu = CreateFrame("Frame", "EzWoWDruidFormsMenu", UIParent, "BackdropTemplate")
    menu:SetFrameStrata("DIALOG")
    menu:SetClampedToScreen(true)
    menu:EnableMouse(true)
    ns.UIKit:ApplyBackdrop(menu, 1, 1)
    menu:SetBackdropColor(ns.Style.bgPrimary[1], ns.Style.bgPrimary[2], ns.Style.bgPrimary[3], 0.98)
    menu:SetBackdropBorderColor(rgba(ns.Style.accent))
    menu:SetWidth(MENU_W)
    menu.widgets = ns.BuildChoiceWidgets(menu, MENU_FONTS, 14)
    menu.more = menu:CreateFontString(nil, "OVERLAY", MENU_FONTS.header)
    menu.actions = {}
    for i, action in ipairs({ "setKey", "options" }) do
        local b = CreateFrame("Button", nil, menu)
        b:SetHeight(18)
        b.action = action
        b.hl = b:CreateTexture(nil, "BACKGROUND")
        b.hl:SetAllPoints()
        b.hl:SetColorTexture(ns.Style.accent[1], ns.Style.accent[2], ns.Style.accent[3], 0.16)
        b.hl:Hide()
        b.text = b:CreateFontString(nil, "OVERLAY", MENU_FONTS.text)
        b.text:SetPoint("LEFT", 6, 0)
        b.text:SetTextColor(rgba(ns.Style.textBody))
        b:SetScript("OnEnter", function(self) self.hl:Show() end)
        b:SetScript("OnLeave", function(self) self.hl:Hide() end)
        b:SetScript("OnClick", function(self)
            menu:Hide()
            ns:OpenOptions()
            if self.action == "setKey" and ns.StartKeyCapture then ns.StartKeyCapture() end
        end)
        menu.actions[i] = b
    end
    menu.note = menu:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    menu.note:SetPoint("BOTTOMLEFT", 10, 6)
    menu.note:SetWidth(MENU_W - 20)
    menu.note:SetJustifyH("LEFT")
    menu.note:SetTextColor(rgba(ns.Style.warning))
    if UISpecialFrames then tinsert(UISpecialFrames, "EzWoWDruidFormsMenu") end
    menu:Hide()
    menu:SetScript("OnUpdate", function(self)
        -- close when the mouse is pressed somewhere else
        if (IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")) and not self:IsMouseOver()
            and not (button and button:IsMouseOver()) then
            self:Hide()
        end
    end)
end

function ns.RefreshQuickMenu()
    if not menu or not menu:IsShown() then return end
    local x, y = 12, -8
    local used = ns.LayoutChoiceWidgets(menu, menu.widgets, x, y, MENU_W - 24,
        { gapX = 8, gapY = 3, headerH = 16, sectionGap = 6, headerX = -4 })
    y = y - used - 6
    menu.more:ClearAllPoints()
    menu.more:SetPoint("TOPLEFT", x - 4, y)
    menu.more:SetText(ns:L("secMore"))
    menu.more:SetTextColor(rgba(ns.Style.accent))
    y = y - 16
    for _, b in ipairs(menu.actions) do
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", x - 6, y)
        b:SetPoint("TOPRIGHT", -6, y)
        b.text:SetText(ns:L("menu_" .. b.action))
        y = y - 18
    end
    local inCombat = ns.InCombat()
    menu.note:SetText(inCombat and ns:L("menuCombat") or "")
    menu:SetHeight(-y + 6 + (inCombat and 18 or 0))
end

function ns.ToggleQuickMenu(anchor)
    if not menu then buildMenu() end
    if menu:IsShown() then menu:Hide() return end
    menu:ClearAllPoints()
    -- placed by screen position, not anchored to the secure button: a frame anchored
    -- to a protected frame becomes protected too, and could not be shown/hidden in combat
    local left, top, bottom = anchor:GetLeft(), anchor:GetTop(), anchor:GetBottom()
    local ratio = (anchor:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
    local uiH = UIParent:GetHeight() or 768
    if not (left and top and bottom) then
        menu:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    elseif (top + bottom) / 2 * ratio < uiH / 2 then
        menu:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left * ratio, top * ratio + 4)
    else
        menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left * ratio, bottom * ratio - 4)
    end
    menu:Show()
    ns.RefreshQuickMenu()
end

-----------------------------------------------------------------------------
-- Key binding
-----------------------------------------------------------------------------
function ns.SetKey(key)
    ns.RunAfterCombat("binding", function()
        local name = ns.BindingName()
        local old = { GetBindingKey(name) }
        for _, oldKey in ipairs(old) do SetBinding(oldKey) end
        if key then SetBindingClick(key, ns.BUTTON_NAME, "LeftButton") end
        local set = type(GetCurrentBindingSet) == "function" and GetCurrentBindingSet() or 2
        pcall(SaveBindings, set)
        ns.ApplyButton()
        if ns.RefreshOptions then ns.RefreshOptions() end
    end)
end

-----------------------------------------------------------------------------
-- Start
-----------------------------------------------------------------------------
function ns.Refresh()
    if not ns.IsDruid() then return end
    ns.RunAfterCombat("scan", function()
        ns.ScanForms()
        ns.ApplyButton()
        if ns.RefreshOptions then ns.RefreshOptions() end
    end)
end

function ns.Start()
    _G.BINDING_HEADER_EZWOWDRUIDFORMS = ns.TITLE
    _G["BINDING_NAME_" .. ns.BindingName()] = ns:L("bindingName")
    if not ns.IsDruid() then return end
    createButtons()
    ns.Refresh()
    local events = CreateFrame("Frame")
    for _, event in ipairs({ "SPELLS_CHANGED", "UPDATE_SHAPESHIFT_FORMS", "LEARNED_SPELL_IN_TAB",
        "PLAYER_LEVEL_UP", "UPDATE_BINDINGS", "CVAR_UPDATE", "NEW_MOUNT_ADDED", "COMPANION_LEARNED" }) do
        pcall(events.RegisterEvent, events, event)
    end
    -- moving, and where the mount can be used
    local MOUNT_EVENTS = { PLAYER_STARTED_MOVING = true, PLAYER_STOPPED_MOVING = true,
        MOUNT_JOURNAL_USABILITY_CHANGED = true, ZONE_CHANGED_NEW_AREA = true, ZONE_CHANGED = true,
        UPDATE_SHAPESHIFT_FORM = true, PLAYER_MOUNT_DISPLAY_CHANGED = true, PLAYER_REGEN_ENABLED = true,
        PLAYER_ALIVE = true, PLAYER_UNGHOST = true }
    for event in pairs(MOUNT_EVENTS) do pcall(events.RegisterEvent, events, event) end
    ns.moving = (type(IsPlayerMoving) == "function" and IsPlayerMoving()) and true or false
    events:SetScript("OnEvent", function(_, event)
        if MOUNT_EVENTS[event] then
            if event == "PLAYER_STARTED_MOVING" then
                ns.moving = true
            elseif event == "PLAYER_STOPPED_MOVING" then
                ns.moving = false
            end
            -- the game says which mounts can be used changed: with none chosen, ask again
            -- (also after the tries above ran out, e.g. the mount list came in late)
            if event == "MOUNT_JOURNAL_USABILITY_CHANGED" and not ns.mount then
                ns.mountRetries = 0
                ns.mountScanWaiting = true
                ns.RetryMountScan(true)
            else
                -- a mount scan that had to wait (in a form, mounted, swimming, or the game said
                -- none for a moment): back as a caster, scan now
                ns.RetryMountScan()
            end
            ns.UpdateMountBlock()
        elseif event == "UPDATE_BINDINGS" or event == "CVAR_UPDATE" then
            ns.ApplyButton()
        else
            ns.Refresh()
        end
    end)
    ns.UpdateMountBlock()
    -- a mount made a favorite (or no longer one) in the mount journal: choose again (favorites first)
    if C_MountJournal and type(C_MountJournal.SetIsFavorite) == "function" and hooksecurefunc then
        pcall(hooksecurefunc, C_MountJournal, "SetIsFavorite", function()
            if C_Timer and C_Timer.After then C_Timer.After(0.5, ns.Refresh) else ns.Refresh() end
        end)
    end
end
