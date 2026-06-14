-- DispelTracker: Arena dispel tracking with hover tooltips
-- /dispeltracker or /dst to toggle

local ADDON_NAME = "DispelTracker"
DispelTrackerDB  = nil

local debugMode = false

-- ============================================================
-- Constants
-- ============================================================

local ARENA_ZONES = {
    ["Nagrand Arena"]      = true,
    ["Blade's Edge Arena"] = true,
    ["Ruins of Lordaeron"] = true,
}

local MAX_SESSIONS  = 50
local WINDOW_WIDTH  = 360
local WINDOW_HEIGHT = 400
local ROW_HEIGHT    = 22
local MAX_VISIBLE   = 15

-- Plain white texture — used as a solid bar (no green StatusBar hover glow)
local BAR_TEXTURE = "Interface\\Buttons\\WHITE8x8"

local COLOR_DISPELLER = { r = 0.4,  g = 0.75, b = 1.0  }
local COLOR_TARGET    = { r = 1.0,  g = 0.65, b = 0.2  }
local COLOR_SESSION   = { r = 0.7,  g = 0.55, b = 1.0  }

local C_OFFENSIVE = { r = 1.0,  g = 0.5,  b = 0.15 }
local C_DEFENSIVE = { r = 0.35, g = 0.65, b = 1.0  }
local C_SPELL_OFF = { r = 1.0,  g = 0.75, b = 0.5  }
local C_SPELL_DEF = { r = 0.55, g = 0.8,  b = 1.0  }
local C_RESIST    = { r = 0.9,  g = 0.25, b = 0.25 }
local C_DIM       = { r = 0.55, g = 0.55, b = 0.55 }
local C_WHITE     = { r = 0.95, g = 0.95, b = 0.95 }

local CLASS_COLOR = {
    WARRIOR = "C79C6E", PALADIN = "F58CBA", HUNTER  = "ABD473",
    ROGUE   = "FFF569", PRIEST  = "FFFFFF", SHAMAN  = "0070DE",
    MAGE    = "69CCF0", WARLOCK = "9482C9", DRUID   = "FF7D0A",
    DEATHKNIGHT = "C41F3B",
}
local CLASS_LABEL = {
    WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter",
    ROGUE   = "Rogue",   PRIEST  = "Priest",  SHAMAN = "Shaman",
    MAGE    = "Mage",    WARLOCK = "Warlock", DRUID  = "Druid",
    DEATHKNIGHT = "Death Knight",
}

-- ============================================================
-- Logging
-- ============================================================

local function DBG(...)
    if debugMode then print("|cffffff00[DT DBG]|r", ...) end
end

local function LOG(...)
    print("|cff00cc88[DispelTracker]|r", ...)
end

-- ============================================================
-- Class lookup
-- ============================================================

local function LookupClass(name)
    local units = { "player", "target", "focus" }
    for i = 1, 4 do units[#units+1] = "party"  .. i end
    for i = 1, 5 do units[#units+1] = "arena"  .. i end
    for _, unit in ipairs(units) do
        if UnitName(unit) == name then
            local _, cf = UnitClass(unit)
            if cf then return cf end
        end
    end
    return nil
end

local function ClassLabel(classFile)
    if not classFile then return nil end
    local label = CLASS_LABEL[classFile] or classFile
    local hex   = CLASS_COLOR[classFile] or "aaaaaa"
    return "|cff" .. hex .. label .. "|r"
end

-- ============================================================
-- Data model
-- ============================================================

local currentSession = nil
local inArena        = false
local sessionCounter = 0
local forcedSession  = false
local ResetTotemMap  -- forward declaration; defined later in totem tracking section

local function FormatTime(t)
    return date("%m/%d %I:%M %p", t)
end

local function NewSession(zone)
    sessionCounter = sessionCounter + 1
    return { label = "Arena "..sessionCounter, zone = zone or "Unknown",
             startTime = time(), dispellers = {} }
end

local function EnsureDispeller(session, name)
    if not session.dispellers[name] then
        session.dispellers[name] = {
            class = LookupClass(name),
            total = 0, offensive = 0, defensive = 0,
            spellsUsed = {}, targets = {},
        }
    else
        if not session.dispellers[name].class then
            session.dispellers[name].class = LookupClass(name)
        end
    end
    return session.dispellers[name]
end

local function EnsureSpellUsed(entry, spellName)
    entry.spellsUsed[spellName] = entry.spellsUsed[spellName]
        or { offensive = 0, defensive = 0, resisted = 0 }
    return entry.spellsUsed[spellName]
end

local function RecordDispel(dispellerName, targetName, removedSpell, dispelSpell, auraType)
    if not currentSession then return end
    local entry = EnsureDispeller(currentSession, dispellerName)
    local isOff = (auraType == "BUFF")
    entry.total = entry.total + 1
    if isOff then entry.offensive = entry.offensive + 1
    else          entry.defensive = entry.defensive + 1 end

    local su = EnsureSpellUsed(entry, dispelSpell)
    if isOff then su.offensive = su.offensive + 1
    else          su.defensive = su.defensive + 1 end

    entry.targets[targetName] = entry.targets[targetName] or { total = 0, spells = {} }
    local t = entry.targets[targetName]
    t.total = t.total + 1
    if not t.spells[removedSpell] then
        t.spells[removedSpell] = { total = 0, via = {} }
    end
    local rs = t.spells[removedSpell]
    rs.total = rs.total + 1
    rs.via[dispelSpell] = (rs.via[dispelSpell] or 0) + 1

    DBG(dispellerName, isOff and "[OFF]" or "[DEF]", dispelSpell,
        "->", targetName, "| removed:", removedSpell)
end

local function RecordResist(dispellerName, targetName, dispelSpell)
    if not currentSession then return end
    local entry = EnsureDispeller(currentSession, dispellerName)
    local su    = EnsureSpellUsed(entry, dispelSpell)
    su.resisted = su.resisted + 1
    DBG(dispellerName, "RESISTED", dispelSpell, "on", targetName)
end

-- Team detection: a unit's own combat-log reaction flag tells us its team.
-- "friendly" = the player's team, "hostile" = the enemy team. Recorded once
-- per name per session (reaction can't change mid-arena).
local FRIENDLY_MASK = COMBATLOG_OBJECT_REACTION_FRIENDLY or 0x10
local function RecordTeam(name, flags)
    if not currentSession or not name or name == "" or not flags then return end
    currentSession.teams = currentSession.teams or {}
    if currentSession.teams[name] == nil then
        currentSession.teams[name] =
            (bit.band(flags, FRIENDLY_MASK) > 0) and "friendly" or "hostile"
    end
end

-- ============================================================
-- Helpers
-- ============================================================

local function SortedPairs(tbl, valFn)
    local keys = {}
    for k in pairs(tbl) do keys[#keys+1] = k end
    table.sort(keys, function(a,b) return valFn(tbl[a]) > valFn(tbl[b]) end)
    local i = 0
    return function()
        i = i + 1
        local k = keys[i]
        if k then return k, tbl[k] end
    end
end

local function ColorHex(c, text)
    return string.format("|cff%02x%02x%02x%s|r",
        math.floor(c.r*255), math.floor(c.g*255), math.floor(c.b*255), text)
end

local function AddLine(lines, text, c)
    c = c or C_WHITE
    lines[#lines+1] = { text=text, r=c.r, g=c.g, b=c.b }
end

-- ============================================================
-- Removed-spell importance tiers (color in tooltips)
-- ============================================================

local C_TIER_LEGENDARY = { r = 1.0,  g = 0.82, b = 0.0  }  -- gold (top tier)
local C_TIER_IMMUNITY = { r = 0.8,  g = 0.4,  b = 1.0  }  -- purple
local C_TIER_MAJOR    = { r = 1.0,  g = 0.55, b = 0.1  }  -- orange
local C_TIER_STRONG   = { r = 0.3,  g = 0.6,  b = 1.0  }  -- blue
local C_TIER_MINOR    = { r = 0.4,  g = 0.9,  b = 0.4  }  -- green
-- everything else falls through to the line's default color (grey/white)

local SPELL_TIER_COLORS = {}
local function tier(color, ...)
    for _, s in ipairs({...}) do SPELL_TIER_COLORS[s] = color end
end
-- Gold — legendary, the highest-value removals
tier(C_TIER_LEGENDARY, "Elemental Mastery")
-- Purple — absolute immunities / must-know removals
tier(C_TIER_IMMUNITY, "Divine Shield", "Ice Block", "Blessing of Protection",
     "Curse of Tongues", "Fear Ward")
-- Orange — game-changing cooldowns
tier(C_TIER_MAJOR, "Innervate", "Fel Domination", "Avenging Wrath",
     "Power Infusion", "Bloodlust", "Heroism", "Nature's Swiftness")
-- Blue — strong defensives + magic CC
tier(C_TIER_STRONG, "Power Word: Shield", "Earth Shield", "Ice Barrier",
     "Icy Veins", "Hammer of Justice", "Repentance", "Polymorph",
     "Entangling Roots", "Cyclone", "Fear", "Seduction", "Blessing of Sacrifice")
-- Green — HoTs / minor buffs
tier(C_TIER_MINOR, "Renew", "Regrowth", "Rejuvenation", "Inner Fire",
     "Water Shield", "Exhaustion", "Sated")

local function RemovedSpellColored(spellName)
    local c = SPELL_TIER_COLORS[spellName]
    if c then return ColorHex(c, spellName) end
    return spellName  -- no tier: inherit the line's default color
end

-- ============================================================
-- Tooltip builders
-- ============================================================

local function BuildDispellerTooltip(entry, name)
    local lines = {}
    local header = name
    local cl = ClassLabel(entry.class)
    if cl then header = header .. " — " .. cl end
    AddLine(lines, header, COLOR_DISPELLER)

    local off = entry.offensive or 0
    local def = entry.defensive or 0
    local totalResists = 0
    for _, su in pairs(entry.spellsUsed) do
        totalResists = totalResists + (su.resisted or 0)
    end

    local summary = "Total: "..entry.total
        .."  "..ColorHex(C_OFFENSIVE, off.." off")
        .."  "..ColorHex(C_DEFENSIVE, def.." def")
    if totalResists > 0 then
        summary = summary.."  "..ColorHex(C_RESIST, totalResists.." resisted")
    end
    AddLine(lines, summary, C_WHITE)
    AddLine(lines, " ", C_DIM)

    AddLine(lines, "Abilities used:", C_DIM)
    for spellName, su in SortedPairs(entry.spellsUsed,
            function(v) return (v.offensive or 0)+(v.defensive or 0)+(v.resisted or 0)
                + (v.casts or 0)*0.01 + (v.attempts or 0)*0.001 end) do
        local stripped = (su.offensive or 0) + (su.defensive or 0)
        local strippedStr
        if (su.offensive or 0) > 0 and (su.defensive or 0) > 0 then
            strippedStr = stripped.." stripped"
                .." ("..ColorHex(C_SPELL_OFF, su.offensive.." off")
                .." / "..ColorHex(C_SPELL_DEF, su.defensive.." def")..")"
        elseif (su.offensive or 0) > 0 then
            strippedStr = ColorHex(C_SPELL_OFF, stripped.." stripped (off)")
        elseif (su.defensive or 0) > 0 then
            strippedStr = ColorHex(C_SPELL_DEF, stripped.." stripped (def)")
        else
            strippedStr = "0 stripped"
        end
        local castStr
        if (su.casts or 0) > 0 then
            castStr = su.casts.." cast, "..strippedStr
        else
            castStr = strippedStr  -- totems and pre-cast-tracking data
        end
        local resistStr = ""
        if (su.resisted or 0) > 0 then
            resistStr = "  "..ColorHex(C_RESIST, su.resisted.." resisted")
        end
        local tickStr = ""
        if (su.attempts or 0) > 0 then
            tickStr = "  |cff888888("..su.attempts.." ticks)|r"
        end
        AddLine(lines, "  "..spellName.."  "..castStr..resistStr..tickStr, C_WHITE)
    end
    AddLine(lines, " ", C_DIM)

    AddLine(lines, "Targets:", C_DIM)
    for targetName, t in SortedPairs(entry.targets, function(v) return v.total end) do
        AddLine(lines, "  "..targetName.."  ("..t.total..")", COLOR_TARGET)
        for spellName, rs in SortedPairs(t.spells,
                function(v) return type(v)=="table" and v.total or v end) do
            local total = type(rs)=="table" and rs.total or rs
            local viaStr = ""
            if type(rs)=="table" and rs.via then
                local parts = {}
                for ds, cnt in pairs(rs.via) do
                    parts[#parts+1] = ds..(cnt>1 and " x"..cnt or "")
                end
                if #parts > 0 then
                    viaStr = "  |cff888888via "..table.concat(parts,", ").."|r"
                end
            end
            AddLine(lines, "    • "..RemovedSpellColored(spellName).."  x"..total..viaStr, C_DIM)
        end
    end
    return lines
end

local function BuildTargetTooltip(targetEntry, targetName, dispName)
    local lines = {}
    AddLine(lines, dispName.."  →  "..targetName, COLOR_TARGET)
    AddLine(lines, "Buffs removed: "..targetEntry.total, C_WHITE)
    AddLine(lines, " ", C_DIM)
    for spellName, rs in SortedPairs(targetEntry.spells,
            function(v) return type(v)=="table" and v.total or v end) do
        local total = type(rs)=="table" and rs.total or rs
        local viaStr = ""
        if type(rs)=="table" and rs.via then
            local parts = {}
            for ds, cnt in pairs(rs.via) do
                parts[#parts+1] = ds..(cnt>1 and " x"..cnt or "")
            end
            if #parts > 0 then
                viaStr = "  |cff888888via "..table.concat(parts,", ").."|r"
            end
        end
        AddLine(lines, "  • "..RemovedSpellColored(spellName).."  x"..total..viaStr, C_WHITE)
    end
    return lines
end

local function ShowRowTooltip(row, lines)
    if not lines or #lines == 0 then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    for _, line in ipairs(lines) do
        GameTooltip:AddLine(line.text, line.r, line.g, line.b, true)
    end
    GameTooltip:Show()
end

-- ============================================================
-- UI state
-- ============================================================

local uiState = {
    view = "sessions", sessionIndex = nil,
    dispellerName = nil, scrollOffset = 0,
}

-- ============================================================
-- UI construction
-- ============================================================

local mainFrame
local rows = {}
local titleText, sessionLabel, backBtn
local RefreshUI  -- forward declaration; defined after the view renderers

local function MakeRow(parent, index)
    local f = CreateFrame("Button", nil, parent)
    f:SetHeight(ROW_HEIGHT)
    f:SetPoint("TOPLEFT",  parent, "TOPLEFT",  4, -(index-1)*ROW_HEIGHT - 4)
    f:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -4, -(index-1)*ROW_HEIGHT - 4)

    -- Dark row background
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    bg:SetVertexColor(0, 0, 0, 0.3)

    -- Plain texture bar — avoids StatusBar's green hover highlight entirely
    local barTex = f:CreateTexture(nil, "BORDER")
    barTex:SetTexture(BAR_TEXTURE)
    barTex:SetPoint("TOPLEFT",    f, "TOPLEFT",    0,  1)
    barTex:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, -1)
    barTex:SetWidth(1)
    f.barTex = barTex

    local nameStr = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameStr:SetPoint("LEFT",  f, "LEFT",  6,    0)
    nameStr:SetPoint("RIGHT", f, "RIGHT", -110, 0)
    nameStr:SetJustifyH("LEFT")
    nameStr:SetTextColor(1, 1, 1)
    f.nameStr = nameStr

    local countStr = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countStr:SetPoint("RIGHT", f, "RIGHT", -6, 0)
    countStr:SetJustifyH("RIGHT")
    f.countStr = countStr

    local hl = f:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(f)
    hl:SetTexture("Interface\\Buttons\\WHITE8x8")
    hl:SetVertexColor(1, 1, 1, 0.07)

    f:SetScript("OnClick",  function(self) if self.onClick then self.onClick() end end)
    f:SetScript("OnEnter",  function(self) if self.tooltipLines then ShowRowTooltip(self, self.tooltipLines) end end)
    f:SetScript("OnLeave",  function() GameTooltip:Hide() end)

    return f
end

local function BuildUI()
    mainFrame = CreateFrame("Frame", "DispelTrackerFrame", UIParent, "BasicFrameTemplateWithInset")
    mainFrame:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
    mainFrame:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
    mainFrame:SetScript("OnDragStop",  mainFrame.StopMovingOrSizing)
    mainFrame:SetClampedToScreen(true)
    mainFrame:Hide()

    titleText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("TOP", mainFrame, "TOP", 0, -6)
    titleText:SetText("Dispel Tracker")

    sessionLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sessionLabel:SetPoint("TOP", titleText, "BOTTOM", 0, -2)
    sessionLabel:SetTextColor(0.7, 0.9, 1)
    sessionLabel:SetText("")

    backBtn = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    backBtn:SetSize(54, 18)
    backBtn:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 8, 8)
    backBtn:SetText("< Back")
    backBtn:SetScript("OnClick", function()
        if uiState.view == "targets" then
            uiState.view = "dispellers"; uiState.dispellerName = nil
        elseif uiState.view == "dispellers" then
            uiState.view = "sessions"; uiState.sessionIndex = nil
        end
        uiState.scrollOffset = 0
        RefreshUI()
    end)

    local scrollUp = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    scrollUp:SetSize(24, 18)
    scrollUp:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -36, 8)
    scrollUp:SetText("^")
    scrollUp:SetScript("OnClick", function()
        if uiState.scrollOffset > 0 then
            uiState.scrollOffset = uiState.scrollOffset - 1; RefreshUI()
        end
    end)

    local scrollDown = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    scrollDown:SetSize(24, 18)
    scrollDown:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -8, 8)
    scrollDown:SetText("v")
    scrollDown:SetScript("OnClick", function()
        uiState.scrollOffset = uiState.scrollOffset + 1; RefreshUI()
    end)

    local rowContainer = CreateFrame("Frame", nil, mainFrame)
    rowContainer:SetPoint("TOPLEFT",     mainFrame, "TOPLEFT",     6, -52)
    rowContainer:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -6, 34)

    for i = 1, MAX_VISIBLE do
        rows[i] = MakeRow(rowContainer, i)
    end

    mainFrame:EnableMouseWheel(true)
    mainFrame:SetScript("OnMouseWheel", function(_, delta)
        if delta > 0 then
            if uiState.scrollOffset > 0 then
                uiState.scrollOffset = uiState.scrollOffset - 1; RefreshUI()
            end
        else
            uiState.scrollOffset = uiState.scrollOffset + 1; RefreshUI()
        end
    end)
end

-- ============================================================
-- Row population
-- ============================================================

local function SetRowBar(row, frac, color)
    local w = row:GetWidth()
    if w < 1 then w = WINDOW_WIDTH - 20 end  -- fallback before first layout
    local c = color or COLOR_DISPELLER
    row.barTex:SetWidth(math.max(1, frac * w))
    row.barTex:SetVertexColor(c.r, c.g, c.b, 0.45)
end

local function PopulateRows(items)
    local offset = uiState.scrollOffset
    for i = 1, MAX_VISIBLE do
        local item = items[i + offset]
        local row  = rows[i]
        if item then
            row:Show()
            row.nameStr:SetText(item.label)
            row.countStr:SetText(item.rightText or "")
            if item.rightColor then
                row.countStr:SetTextColor(item.rightColor.r, item.rightColor.g, item.rightColor.b)
            else
                row.countStr:SetTextColor(1, 1, 0.6)
            end
            SetRowBar(row, item.barFrac or 0, item.color)
            row.onClick      = item.onClick
            row.tooltipLines = item.tooltipLines
        else
            row:Hide()
            row.onClick      = nil
            row.tooltipLines = nil
        end
    end
end

-- ============================================================
-- Off/def/resist label
-- ============================================================

local function OffDefLabel(total, off, def, resists)
    off = off or 0
    def = def or 0
    local parts
    if off > 0 and def > 0 then
        parts = ColorHex(C_OFFENSIVE, off.." off").." "..ColorHex(C_DEFENSIVE, def.." def")
    elseif off > 0 then
        parts = ColorHex(C_OFFENSIVE, total.." off")
    else
        parts = ColorHex(C_DEFENSIVE, total.." def")
    end
    if resists and resists > 0 then
        parts = parts.." "..ColorHex(C_RESIST, resists.."R")
    end
    return parts, C_WHITE
end

-- ============================================================
-- View renderers
-- ============================================================

local function RenderSessions()
    titleText:SetText("Dispel Tracker")
    sessionLabel:SetText("All Sessions  |cff888888(newest first)|r")
    backBtn:Hide()

    local sessions = DispelTrackerDB.sessions
    if #sessions == 0 then
        for i = 1, MAX_VISIBLE do rows[i]:Hide() end
        rows[1]:Show()
        rows[1].nameStr:SetText("|cff888888No sessions yet. Enter an arena.|r")
        rows[1].countStr:SetText("")
        SetRowBar(rows[1], 0, COLOR_SESSION)
        rows[1].onClick = nil; rows[1].tooltipLines = nil
        return
    end

    local maxTotal, built = 0, {}
    for i = #sessions, 1, -1 do
        local s, total = sessions[i], 0
        for _, d in pairs(s.dispellers) do total = total + d.total end
        if total > maxTotal then maxTotal = total end
        built[#built+1] = { s=s, idx=i, total=total }
    end
    maxTotal = math.max(maxTotal, 1)

    local items = {}
    for _, it in ipairs(built) do
        local s = it.s
        local click = (function(idx) return function()
            uiState.view="dispellers"; uiState.sessionIndex=idx
            uiState.scrollOffset=0; RefreshUI()
        end end)(it.idx)
        items[#items+1] = {
            label="|cffddbbff"..s.label.."|r  |cff888888"..(s.zone or "?").."|r",
            rightText=it.total.." dispels", barFrac=it.total/maxTotal,
            color=COLOR_SESSION, onClick=click,
        }
        items[#items+1] = {
            label="|cff555555  "..FormatTime(s.startTime).."|r",
            rightText="", barFrac=0, color=COLOR_SESSION, onClick=click,
        }
    end
    PopulateRows(items)
end

local function RenderDispellers(sessionIdx)
    local s = DispelTrackerDB.sessions[sessionIdx]
    if not s then return end
    titleText:SetText(s.label.."  |cff888888"..(s.zone or "").."|r")
    sessionLabel:SetText(FormatTime(s.startTime).."  —  Hover for full breakdown")
    backBtn:Show()

    local maxVal = 0
    for _, d in pairs(s.dispellers) do
        if d.total > maxVal then maxVal = d.total end
    end
    maxVal = math.max(maxVal, 1)

    local items = {}
    for name, d in SortedPairs(s.dispellers, function(v) return v.total end) do
        local totalResists = 0
        for _, su in pairs(d.spellsUsed) do totalResists = totalResists + (su.resisted or 0) end

        local off, def = d.offensive or 0, d.defensive or 0
        local barColor
        if off > def then barColor = C_OFFENSIVE
        elseif def > off then barColor = C_DEFENSIVE
        else barColor = COLOR_DISPELLER end

        local rightText, rightColor = OffDefLabel(d.total, off, def, totalResists)
        local cl = ClassLabel(d.class)
        -- Tint the name by team: green = your team, red = enemy team
        local team = s.teams and s.teams[name]
        local nameColored = name
        if team == "friendly" then
            nameColored = "|cff66dd66"..name.."|r"
        elseif team == "hostile" then
            nameColored = "|cffff5555"..name.."|r"
        end
        local nameStr = cl and (nameColored.." |cff555555—|r "..cl) or nameColored

        items[#items+1] = {
            label=nameStr, rightText=rightText, rightColor=rightColor,
            barFrac=d.total/maxVal, color=barColor,
            tooltipLines=BuildDispellerTooltip(d, name),
            onClick=(function(n) return function()
                uiState.view="targets"; uiState.dispellerName=n
                uiState.scrollOffset=0; RefreshUI()
            end end)(name),
        }
    end
    PopulateRows(items)
end

local function RenderTargets(sessionIdx, dispellerName)
    local s = DispelTrackerDB.sessions[sessionIdx]
    if not s then return end
    local d = s.dispellers[dispellerName]
    if not d then return end
    titleText:SetText(dispellerName)
    sessionLabel:SetText("Targets  ("..d.total.." total)  —  Hover to see spells")
    backBtn:Show()

    local maxVal = 0
    for _, t in pairs(d.targets) do if t.total > maxVal then maxVal = t.total end end
    maxVal = math.max(maxVal, 1)

    local items = {}
    for targetName, t in SortedPairs(d.targets, function(v) return v.total end) do
        items[#items+1] = {
            label=targetName, rightText=t.total,
            barFrac=t.total/maxVal, color=COLOR_TARGET,
            tooltipLines=BuildTargetTooltip(t, targetName, dispellerName),
        }
    end
    PopulateRows(items)
end

-- ============================================================
-- Refresh dispatcher
-- ============================================================

RefreshUI = function()
    if not mainFrame or not mainFrame:IsShown() then return end
    local v = uiState.view
    if     v == "sessions"   then RenderSessions()
    elseif v == "dispellers" then RenderDispellers(uiState.sessionIndex)
    elseif v == "targets"    then RenderTargets(uiState.sessionIndex, uiState.dispellerName)
    end
end

local function ToggleUI()
    if not mainFrame then BuildUI() end
    if mainFrame:IsShown() then
        mainFrame:Hide()
    else
        uiState.view="sessions"; uiState.scrollOffset=0
        mainFrame:Show(); RefreshUI()
    end
end

-- ============================================================
-- Arena session management
-- ============================================================

local function OnArenaEnter(zone)
    if inArena then return end
    inArena=true; forcedSession=false; currentSession=NewSession(zone)
    LOG("Arena session started: "..currentSession.label.." ("..(zone or "?")..")")
end

local function OnArenaExit()
    if not inArena then return end
    inArena = false
    ResetTotemMap()
    if currentSession then
        local total = 0
        for _, d in pairs(currentSession.dispellers) do total = total + d.total end
        if total > 0 then
            table.insert(DispelTrackerDB.sessions, currentSession)
            while #DispelTrackerDB.sessions > MAX_SESSIONS do
                table.remove(DispelTrackerDB.sessions, 1)
            end
            LOG("Session saved: "..currentSession.label.." — "..total.." dispels")
        else
            LOG("Arena ended with 0 dispels — not saved.")
        end
    end
    currentSession = nil
end

local function CheckZone()
    local zone = GetRealZoneText()
    DBG("Zone check:", zone)
    if ARENA_ZONES[zone] then
        -- A leftover forced session would swallow the real match — close it out first
        if forcedSession then
            forcedSession = false
            OnArenaExit()
        end
        OnArenaEnter(zone)
    elseif inArena and not forcedSession then
        OnArenaExit()
    end
end

-- ============================================================
-- Totem heuristic tracking
-- ============================================================

-- The server never sends a dispel event for passive totem cleanses, so we use
-- a process-of-elimination heuristic: if a DEBUFF disappears from a friendly
-- while a cleansing totem is active and no direct cure spell was just cast on
-- that target, credit the totem owner.

local TOTEM_DURATION    = 120  -- seconds (TBC Poison/Disease Cleansing Totem: 2 min)
local CURE_EXCLUSION    = 6    -- seconds — if a cure was cast within this window, skip

-- Spells that directly remove poisons/diseases (exclude from totem credit)
local DIRECT_CURE_SPELLS = {
    ["Cure Poison"]    = true,  -- Druid
    ["Abolish Poison"] = true,  -- Druid
    ["Cleanse"]        = true,  -- Paladin (removes poison + magic + disease)
    ["Cure Disease"]   = true,  -- Priest, Paladin
    ["Abolish Disease"]= true,  -- Priest
    ["Dispel Magic"]   = true,  -- Priest (magic debuffs)
    ["Remove Curse"]   = true,  -- Mage, Druid
    ["Cleanse Spirit"] = true,  -- Shaman (curse)
    -- Self-cleanses that also remove poisons/snares early
    ["Cloak of Shadows"]          = true,  -- Rogue
    ["Stoneform"]                 = true,  -- Dwarf racial
    ["Escape Artist"]             = true,  -- Gnome racial
    ["Medallion of the Alliance"] = true,  -- PvP trinket
    ["Medallion of the Horde"]    = true,
    ["Insignia of the Alliance"]  = true,
    ["Insignia of the Horde"]     = true,
}

-- Dispel spells whose casts we count via SPELL_CAST_SUCCESS ("5 cast, 3 stripped")
local DISPEL_CAST_SPELLS = {
    ["Purge"]               = true,  -- Shaman
    ["Dispel Magic"]        = true,  -- Priest
    ["Mass Dispel"]         = true,  -- Priest
    ["Cleanse"]             = true,  -- Paladin
    ["Purify"]              = true,  -- Paladin
    ["Cure Poison"]         = true,  -- Druid, Shaman
    ["Abolish Poison"]      = true,  -- Druid
    ["Cure Disease"]        = true,  -- Priest, Shaman
    ["Abolish Disease"]     = true,  -- Priest
    ["Remove Curse"]        = true,  -- Druid
    ["Remove Lesser Curse"] = true,  -- Mage
    ["Devour Magic"]        = true,  -- Warlock felhunter
}

-- totemGUID → { ownerName, totemSpell, expiresAt }
local activeTotemWindows = {}

-- targetName → GetTime() of last direct cure cast on them
local recentCures = {}

-- targetName → spellName → GetTime() of last application
-- Used to detect early removal vs natural expiry for non-stacking poisons
local debuffApplied = {}

-- Known poison debuff durations in seconds. Includes hunter stings (poison
-- dispel type without "Poison" in the name). A full SPELL_AURA_REMOVED is only
-- credited to the totem if it happened well before the duration would run out;
-- otherwise it's treated as natural expiry.
local POISON_DURATION = {
    ["Wound Poison"]        = 15,
    ["Deadly Poison"]       = 12,
    ["Crippling Poison"]    = 12,
    ["Mind-Numbing Poison"] = 10,
    ["Viper Sting"]         = 8,
    ["Serpent Sting"]       = 15,
    ["Scorpid Sting"]       = 20,
    ["Wyvern Sting"]        = 12,
}
local EARLY_REMOVAL_BUFFER = 1.5  -- seconds — if more time than this remains, it was actively removed

-- Any new water totem from the same shaman replaces the previous one
local WATER_TOTEMS = {
    ["Poison Cleansing Totem"]  = true,
    ["Disease Cleansing Totem"] = true,
    ["Healing Stream Totem"]    = true,
    ["Mana Spring Totem"]       = true,
    ["Mana Tide Totem"]         = true,
    ["Fire Resistance Totem"]   = true,
}

local TOTEM_PULSE_INTERVAL = 5  -- cleanse attempt on placement, then every 5s while alive

local function EndTotemWindow(guid, reason)
    local tw = activeTotemWindows[guid]
    if not tw then return end
    if tw.ticker then tw.ticker:Cancel() end
    activeTotemWindows[guid] = nil
    DBG("Totem window ended ("..reason.."):", tw.totemSpell, "by", tw.ownerName)
end

local function RecordTotemTick(ownerName, totemSpell)
    if not inArena or not currentSession then return end
    local entry = EnsureDispeller(currentSession, ownerName)
    local su    = EnsureSpellUsed(entry, totemSpell)
    su.attempts = (su.attempts or 0) + 1
    DBG("Totem tick", su.attempts, "-", totemSpell, "by", ownerName)
end

ResetTotemMap = function()
    for guid in pairs(activeTotemWindows) do
        EndTotemWindow(guid, "session end")
    end
    wipe(recentCures)
    wipe(debuffApplied)
end

local function GetActiveTotemOwner()
    local now = GetTime()
    local bestOwner, bestPlaced = nil, 0
    for guid, tw in pairs(activeTotemWindows) do
        if now > tw.expiresAt then
            activeTotemWindows[guid] = nil  -- lazy expire
        elseif tw.placedAt > bestPlaced then
            bestOwner  = tw.ownerName
            bestPlaced = tw.placedAt
        end
    end
    return bestOwner
end

-- ============================================================
-- Combat log
-- ============================================================

local function OnCombatLog()
    local _, subevent, _,
          sourceGUID, sourceName, sourceFlags, _,
          destGUID,   destName,   _, _,
          _, spellName, _,
          p15, extraSpellName, _, p18
        = CombatLogGetCurrentEventInfo()
    -- p15 = auraType for SPELL_AURA_REMOVED; extraSpellId for SPELL_DISPEL
    -- p18 = auraType for SPELL_DISPEL
    local auraType = p18  -- used by SPELL_DISPEL handlers below

    -- ── Totem placement (fires anywhere, so we can map before arena guard) ──
    if subevent == "SPELL_SUMMON" and WATER_TOTEMS[spellName] then
        -- Dropping any water totem replaces the shaman's previous one
        if sourceName then
            for guid, tw in pairs(activeTotemWindows) do
                if tw.ownerName == sourceName then EndTotemWindow(guid, "replaced") end
            end
        end
        if (spellName == "Poison Cleansing Totem" or spellName == "Disease Cleansing Totem")
           and destGUID and sourceName then
            local now = GetTime()
            local tw = {
                ownerName  = sourceName,
                totemSpell = spellName,
                placedAt   = now,
                expiresAt  = now + TOTEM_DURATION,
            }
            activeTotemWindows[destGUID] = tw
            RecordTeam(sourceName, sourceFlags)  -- shaman's team, for totem credit later
            -- First cleanse attempt fires the moment the totem is placed,
            -- then every 5s until it expires (ticker self-cancels), dies, or is replaced
            RecordTotemTick(sourceName, spellName)
            local remainingTicks = math.floor(TOTEM_DURATION / TOTEM_PULSE_INTERVAL)
            tw.ticker = C_Timer.NewTicker(TOTEM_PULSE_INTERVAL, function()
                RecordTotemTick(tw.ownerName, tw.totemSpell)
                if mainFrame and mainFrame:IsShown() then RefreshUI() end
            end, remainingTicks)
            DBG("Totem placed:", spellName, "by", sourceName, "(", TOTEM_DURATION, "s window)")
        end
        return
    end

    -- ── Totem death — shrink the window immediately ──
    if subevent == "UNIT_DIED" then
        if destGUID and activeTotemWindows[destGUID] then
            EndTotemWindow(destGUID, "died")
        end
        return
    end

    -- ── Track poison application/refresh times (for expiry detection) ──
    -- Refreshes and new stacks reset the duration, so always keep the latest time
    if (subevent == "SPELL_AURA_APPLIED" or subevent == "SPELL_AURA_APPLIED_DOSE"
        or subevent == "SPELL_AURA_REFRESH")
       and POISON_DURATION[spellName] and destName then
        debuffApplied[destName] = debuffApplied[destName] or {}
        debuffApplied[destName][spellName] = GetTime()
        return
    end

    if not inArena or not currentSession then return end

    -- Record each acting unit's team (their own reaction flag = their side)
    RecordTeam(sourceName, sourceFlags)

    if subevent == "SPELL_CAST_SUCCESS" then
        -- ── Count dispel casts (a cast may strip nothing — that's the point) ──
        if DISPEL_CAST_SPELLS[spellName] and sourceName and sourceName ~= "" then
            local entry = EnsureDispeller(currentSession, sourceName)
            local su    = EnsureSpellUsed(entry, spellName)
            su.casts = (su.casts or 0) + 1
            DBG("Dispel cast:", sourceName, spellName, "#"..su.casts)
            if mainFrame and mainFrame:IsShown() then RefreshUI() end
        end
        -- ── Direct cure cast — suppresses totem credit briefly ──
        if DIRECT_CURE_SPELLS[spellName] then
            local cureTarget = (destName and destName ~= "") and destName or sourceName
            if cureTarget then
                recentCures[cureTarget] = GetTime()
                DBG("Direct cure:", spellName, "on", cureTarget)
            end
        end
        return
    end

    -- ── Normal player dispels ──
    if subevent == "SPELL_DISPEL" then
        if not sourceName or not destName or not extraSpellName or not spellName then return end
        RecordDispel(sourceName, destName, extraSpellName, spellName, auraType)
        if mainFrame and mainFrame:IsShown() then RefreshUI() end
        return
    end

    if subevent == "SPELL_DISPEL_FAILED" then
        if not sourceName or not destName or not spellName then return end
        DBG("DISPEL_FAILED:", sourceName, spellName, "on", destName)
        RecordResist(sourceName, destName, spellName)
        if mainFrame and mainFrame:IsShown() then RefreshUI() end
        return
    end

    -- ── Heuristic totem cleanse ──
    if (subevent == "SPELL_AURA_REMOVED" or subevent == "SPELL_AURA_REMOVED_DOSE") and p15 == "DEBUFF" then
        if not (POISON_DURATION[spellName] or spellName:find("Poison")) then return end

        local owner = GetActiveTotemOwner()
        if not owner then return end

        local lastCure = recentCures[destName]
        if lastCure and (GetTime() - lastCure) < CURE_EXCLUSION then
            DBG("Totem heuristic skipped — direct cure just cast on", destName)
            return
        end

        -- Natural expiry also fires SPELL_AURA_REMOVED (all stacks drop at once).
        -- Credit the totem only if the poison still had real time left, measured
        -- from the most recent application/refresh.
        -- (A REMOVED_DOSE never happens on expiry — single stacks only drop to
        -- active removal — so doses skip this check.)
        if subevent == "SPELL_AURA_REMOVED" then
            local duration = POISON_DURATION[spellName]
            if duration then
                local applied = debuffApplied[destName] and debuffApplied[destName][spellName]
                if not applied then return end  -- never saw it applied; can't judge, skip
                local timeRemaining = duration - (GetTime() - applied)
                if timeRemaining <= EARLY_REMOVAL_BUFFER then
                    DBG("Totem skipped — likely natural expiry of", spellName, "(", timeRemaining, "s remaining)")
                    return
                end
            end
        end

        local totemLabel = "Poison Cleansing Totem"
        for _, tw in pairs(activeTotemWindows) do
            if tw.ownerName == owner then totemLabel = tw.totemSpell; break end
        end

        DBG("Totem cleanse (heuristic):", owner, "→", destName, "| removed:", spellName)
        RecordDispel(owner, destName, spellName, totemLabel, "DEBUFF")
        if mainFrame and mainFrame:IsShown() then RefreshUI() end
        return
    end
end

-- ============================================================
-- Test data
-- ============================================================

local function InjectTestData()
    local fake = {
        label="Test Arena", zone="Nagrand Arena",
        startTime=time()-300, dispellers={},
    }

    local function Add(disp, cls, target, removedSpell, dispelSpell, auraType, n)
        fake.dispellers[disp] = fake.dispellers[disp] or {
            class=cls, total=0, offensive=0, defensive=0, spellsUsed={}, targets={},
        }
        local d, off = fake.dispellers[disp], (auraType=="BUFF")
        for _ = 1, n do
            d.total = d.total + 1
            if off then d.offensive=d.offensive+1 else d.defensive=d.defensive+1 end
            d.spellsUsed[dispelSpell] = d.spellsUsed[dispelSpell]
                or {offensive=0, defensive=0, resisted=0}
            local su = d.spellsUsed[dispelSpell]
            if off then su.offensive=su.offensive+1 else su.defensive=su.defensive+1 end
            d.targets[target] = d.targets[target] or {total=0, spells={}}
            d.targets[target].total = d.targets[target].total + 1
            if not d.targets[target].spells[removedSpell] then
                d.targets[target].spells[removedSpell] = {total=0, via={}}
            end
            local rs = d.targets[target].spells[removedSpell]
            rs.total = rs.total + 1
            rs.via[dispelSpell] = (rs.via[dispelSpell] or 0) + 1
        end
    end

    local function AddResist(disp, cls, dispelSpell, n)
        fake.dispellers[disp] = fake.dispellers[disp] or {
            class=cls, total=0, offensive=0, defensive=0, spellsUsed={}, targets={},
        }
        local d = fake.dispellers[disp]
        d.spellsUsed[dispelSpell] = d.spellsUsed[dispelSpell]
            or {offensive=0, defensive=0, resisted=0}
        d.spellsUsed[dispelSpell].resisted = d.spellsUsed[dispelSpell].resisted + n
    end

    Add("Soulpatch", "PRIEST",  "Rogue-A",   "Blade Flurry",    "Dispel Magic", "BUFF",   3)
    Add("Soulpatch", "PRIEST",  "Rogue-A",   "Slice and Dice",  "Dispel Magic", "BUFF",   2)
    Add("Soulpatch", "PRIEST",  "Warrior-B", "Death Wish",      "Mass Dispel",  "BUFF",   2)
    Add("Soulpatch", "PRIEST",  "Druid-C",   "Entangling Roots","Dispel Magic", "DEBUFF", 4)
    AddResist("Soulpatch", "PRIEST",  "Mass Dispel",  3)
    AddResist("Soulpatch", "PRIEST",  "Dispel Magic", 1)

    Add("Wolftotem", "SHAMAN",  "Paladin-E", "Divine Shield",   "Purge", "BUFF", 1)
    Add("Wolftotem", "SHAMAN",  "Druid-C",   "Lifebloom",       "Purge", "BUFF", 5)
    Add("Wolftotem", "SHAMAN",  "Druid-C",   "Regrowth",        "Purge", "BUFF", 3)
    AddResist("Wolftotem", "SHAMAN",  "Purge", 2)

    Add("Holyhand",  "PALADIN", "Warrior-B", "Mortal Strike",   "Cleanse", "DEBUFF", 2)
    Add("Holyhand",  "PALADIN", "Rogue-A",   "Wound Poison",    "Cleanse", "DEBUFF", 4)

    sessionCounter = sessionCounter + 1
    fake.label = "Test Arena "..sessionCounter
    table.insert(DispelTrackerDB.sessions, fake)
    LOG("Test session injected: "..fake.label)

    if not mainFrame then BuildUI() end
    uiState.view="sessions"; uiState.scrollOffset=0
    mainFrame:Show(); RefreshUI()
end

-- ============================================================
-- Event frame
-- ============================================================

local frame = CreateFrame("Frame", "DispelTrackerEventFrame", UIParent)
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("PLAYER_LOGOUT")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == ADDON_NAME then
            DispelTrackerDB = DispelTrackerDB or {sessions={}}
            sessionCounter  = #DispelTrackerDB.sessions
            LOG("Loaded — "..#DispelTrackerDB.sessions.." saved sessions. /dst to open.")
        end
    elseif event == "PLAYER_LOGIN"           then CheckZone()
    elseif event == "ZONE_CHANGED_NEW_AREA"  then CheckZone()
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then OnCombatLog()
    elseif event == "PLAYER_LOGOUT" then
        if inArena and currentSession then OnArenaExit() end
    end
end)

-- ============================================================
-- Slash commands
-- ============================================================

SLASH_DISPELTRACKER1 = "/dispeltracker"
SLASH_DISPELTRACKER2 = "/dst"
SlashCmdList["DISPELTRACKER"] = function(msg)
    local cmd = msg:lower():match("^(%S+)") or ""
    if     cmd == ""       then ToggleUI()
    elseif cmd == "debug"  then
        debugMode = not debugMode
        LOG("Debug mode: "..(debugMode and "ON" or "OFF"))
    elseif cmd == "test"   then InjectTestData()
    elseif cmd == "zone"   then LOG("Zone: "..(GetRealZoneText() or "nil"))
    elseif cmd == "reset"  then
        DispelTrackerDB.sessions={}; sessionCounter=0
        LOG("All session data cleared.")
        if mainFrame and mainFrame:IsShown() then RefreshUI() end
    elseif cmd == "status" then
        LOG("In arena: "..tostring(inArena))
        LOG("Active session: "..(currentSession and currentSession.label or "none"))
        LOG("Saved sessions: "..#DispelTrackerDB.sessions)
    elseif cmd == "forcearena" then
        if inArena then
            LOG("Already in a session — use /dst stoparena to end it.")
        else
            inArena = true
            forcedSession = true
            currentSession = NewSession(GetRealZoneText() or "Forced")
            LOG("Forced session started: "..currentSession.label.." — dispels now recording anywhere.")
        end
    elseif cmd == "stoparena" then
        if not inArena then
            LOG("No active session.")
        else
            local countBefore = #DispelTrackerDB.sessions
            forcedSession = false
            OnArenaExit()
            if #DispelTrackerDB.sessions > countBefore then
                LOG("Session saved! Opening window...")
                if not mainFrame then BuildUI() end
                uiState.view = "sessions"; uiState.scrollOffset = 0
                mainFrame:Show(); RefreshUI()
            else
                LOG("Nothing to save — no dispels were recorded.")
            end
        end
    elseif cmd == "help"   then
        LOG("/dst              — toggle window")
        LOG("/dst debug        — verbose log (shows DISPEL_FAILED hits)")
        LOG("/dst test         — inject fake session")
        LOG("/dst forcearena   — start a session anywhere (for testing outside arenas)")
        LOG("/dst zone         — print current zone name")
        LOG("/dst status       — show tracking state")
        LOG("/dst reset        — clear all sessions")
    else
        LOG("Unknown command. /dst help for list.")
    end
end
