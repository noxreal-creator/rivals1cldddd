-- ╔══════════════════════════════════════════════════════════════╗
-- ║          RIVALS HUB  v3.0  —  by RivalsHub                  ║
-- ║  loadstring(game:HttpGet("YOUR_RAW_URL",true))()             ║
-- ╚══════════════════════════════════════════════════════════════╝

-- ── Duplicate-load guard ──────────────────────────────────────
if getgenv and getgenv().RivalsHub_Loop then
    pcall(function() getgenv().RivalsHub_Loop:Disconnect() end)
end
do local old = game:GetService("CoreGui"):FindFirstChild("RivalsHub")
    if old then old:Destroy() end
end

-- ── Services ──────────────────────────────────────────────────
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local HttpService      = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui          = game:GetService("CoreGui")
local LocalPlayer      = Players.LocalPlayer

local function Cam() return workspace.CurrentCamera end

-- ── Config ────────────────────────────────────────────────────
local Cfg = {
    Aimbot = {
        Enabled     = false,
        FOV         = 150,
        Smoothness  = 8,      -- degrees/frame at 60fps; higher = snappier
        Prediction  = 0.08,   -- seconds ahead to predict target movement
        Target      = "Head",
        VisibleOnly = true,
        TeamCheck   = true,
        ShowFOV     = true,
        SilentAim   = false,  -- moves cursor instead of camera
        FOVColor    = Color3.fromRGB(255, 50, 90),
    },
    Skin = {
        ShirtId  = "", PantsId = "", FaceId = "",
        Transparency = 0,
    },
    ESP        = false,
    NoClip     = false,
    SpeedBoost = false,
    SpeedValue = 24,
    Wraps      = false,  -- unlock all weapon wraps
    Charms     = false,  -- unlock all charms
}

-- ── Connections pool (cleaned on unload) ──────────────────────
local Conns = {}
local function Track(c) Conns[#Conns+1] = c; return c end

-- ── Utility ───────────────────────────────────────────────────
local function IsAlive(p)
    local c = p.Character
    if not c then return false end
    local h = c:FindFirstChildOfClass("Humanoid")
    return h and h.Health > 0
end

local function GetVelocity(part)
    -- AssemblyLinearVelocity is the modern API
    return part.AssemblyLinearVelocity or Vector3.zero
end

local function IsVisible(part)
    local origin = Cam().CFrame.Position
    local dir    = part.Position - origin
    local rp     = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    local char = LocalPlayer.Character
    rp.FilterDescendantsInstances = char and {char} or {}
    local res = workspace:Raycast(origin, dir, rp)
    if not res then return true end
    return res.Instance == part or res.Instance:IsDescendantOf(part.Parent)
end

local function V2Center()
    local s = Cam().ViewportSize
    return Vector2.new(s.X*.5, s.Y*.5)
end

local function WorldToScreen(pos)
    local v, on = Cam():WorldToViewportPoint(pos)
    return Vector2.new(v.X, v.Y), on, v.Z
end

-- Delta-time-correct lerp angle (avoids frame-rate dependency)
local function LerpAngle(a, b, t)
    -- t in degrees/second; call with dt
    local diff = (b - a)
    local len  = diff.Magnitude
    if len < 0.0001 then return b end
    local step = math.min(len, t)
    return a + diff.Unit * step
end

-- ── NoClip ────────────────────────────────────────────────────
local ncConn
local function SetNoClip(on)
    if ncConn then ncConn:Disconnect(); ncConn = nil end
    local char = LocalPlayer.Character
    if on and char then
        local function nc(p) if p:IsA("BasePart") then p.CanCollide = false end end
        for _,p in char:GetDescendants() do nc(p) end
        ncConn = char.DescendantAdded:Connect(nc)
    end
end

-- ── Transparency ──────────────────────────────────────────────
local function ApplyTransp()
    local char = LocalPlayer.Character; if not char then return end
    for _,p in char:GetDescendants() do
        if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" then
            p.Transparency = Cfg.Skin.Transparency
        end
    end
end

-- ── Wraps & Charms unlock ─────────────────────────────────────
-- Rivals stores owned cosmetics in a RemoteFunction / ModuleScript.
-- We patch the client-side ownership tables so the loadout screen
-- thinks everything is unlocked. Server-authoritative games will
-- revert on equip; this makes items visible/selectable in the UI.
local function PatchCosmetics(enable)
    -- Strategy 1: find any OwnedItems / Inventory value objects under LocalPlayer
    for _, obj in LocalPlayer:GetDescendants() do
        if obj:IsA("StringValue") or obj:IsA("IntValue") then
            local n = obj.Name:lower()
            if enable and (n:find("wrap") or n:find("charm") or n:find("unlock") or n:find("owned")) then
                pcall(function() obj.Value = enable and 1 or 0 end)
            end
        end
        if obj:IsA("BoolValue") then
            local n = obj.Name:lower()
            if n:find("wrap") or n:find("charm") or n:find("owned") or n:find("unlock") then
                pcall(function() obj.Value = enable end)
            end
        end
    end

    -- Strategy 2: find and patch ModuleScript tables in ReplicatedStorage
    for _, mod in ReplicatedStorage:GetDescendants() do
        if mod:IsA("ModuleScript") then
            local n = mod.Name:lower()
            if n:find("cosmetic") or n:find("wrap") or n:find("charm") or n:find("inventory") or n:find("unlock") then
                local ok, t = pcall(require, mod)
                if ok and type(t) == "table" then
                    for k, v in pairs(t) do
                        if type(v) == "boolean" then
                            pcall(function() t[k] = enable end)
                        elseif type(v) == "number" then
                            pcall(function() t[k] = enable and 1 or v end)
                        elseif type(v) == "table" then
                            -- fill owned list tables
                            if k:lower():find("owned") or k:lower():find("unlock") then
                                pcall(function()
                                    if enable then
                                        local meta = getmetatable(v)
                                        if meta then
                                            setmetatable(v, {__index = function() return true end})
                                        end
                                    end
                                end)
                            end
                        end
                    end
                end
            end
        end
    end

    -- Strategy 3: hook RemoteFunction that checks ownership
    for _, rf in ReplicatedStorage:GetDescendants() do
        if rf:IsA("RemoteFunction") then
            local n = rf.Name:lower()
            if n:find("wrap") or n:find("charm") or n:find("owns") or n:find("hasitem") or n:find("unlock") then
                if enable then
                    pcall(function()
                        rf.OnClientInvoke = function() return true end
                    end)
                else
                    pcall(function()
                        rf.OnClientInvoke = nil
                    end)
                end
            end
        end
    end
end

-- ── Re-apply on respawn ───────────────────────────────────────
Track(LocalPlayer.CharacterAdded:Connect(function(char)
    task.wait(0.5)
    if Cfg.NoClip    then SetNoClip(true)                            end
    if Cfg.SpeedBoost then
        local h = char:WaitForChild("Humanoid",5)
        if h then h.WalkSpeed = Cfg.SpeedValue end
    end
    ApplyTransp()
end))

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  GUI                                                         ║
-- ╚══════════════════════════════════════════════════════════════╝
local CLR = {
    BG         = Color3.fromRGB(8,   8,   12),
    Panel      = Color3.fromRGB(15,  15,  22),
    PanelHi    = Color3.fromRGB(22,  22,  32),
    Border     = Color3.fromRGB(40,  40,  58),
    Accent     = Color3.fromRGB(88,  58,  210),
    AccentHi   = Color3.fromRGB(118, 83,  255),
    AccentGlow = Color3.fromRGB(70,  45,  170),
    Text       = Color3.fromRGB(232, 232, 245),
    Muted      = Color3.fromRGB(105, 105, 132),
    SubMuted   = Color3.fromRGB(65,  65,  85),
    ON         = Color3.fromRGB(55,  200, 105),
    OFF        = Color3.fromRGB(50,  50,  68),
    Red        = Color3.fromRGB(205, 50,  55),
    Green      = Color3.fromRGB(45,  185, 95),
    Gold       = Color3.fromRGB(220, 175, 55),
}

local TI      = TweenInfo.new
local TFAST   = TI(.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TMED    = TI(.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TSLIDE  = TI(.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

-- ── Root ScreenGui ────────────────────────────────────────────
local SG = Instance.new("ScreenGui")
SG.Name           = "RivalsHub"
SG.ResetOnSpawn   = false
SG.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
SG.DisplayOrder   = 999
SG.Parent         = CoreGui

-- ── Helper constructors ───────────────────────────────────────
local function Frame(parent, sz, pos, color, r)
    local f = Instance.new("Frame")
    f.Size             = sz
    f.Position         = pos
    f.BackgroundColor3 = color or CLR.Panel
    f.BorderSizePixel  = 0
    f.Parent           = parent
    if r then Instance.new("UICorner", f).CornerRadius = UDim.new(0, r) end
    return f
end

local function Stroke(parent, color, thickness)
    local s = Instance.new("UIStroke", parent)
    s.Color     = color or CLR.Border
    s.Thickness = thickness or 1
    return s
end

local function Label(parent, text, sz, pos, color, fs, font)
    local l = Instance.new("TextLabel")
    l.Text                   = text
    l.Size                   = sz
    l.Position               = pos
    l.BackgroundTransparency = 1
    l.TextColor3             = color or CLR.Text
    l.TextSize               = fs or 13
    l.Font                   = font or Enum.Font.GothamBold
    l.TextXAlignment         = Enum.TextXAlignment.Left
    l.TextTruncate           = Enum.TextTruncate.AtEnd
    l.Parent                 = parent
    return l
end

local function TextBox(parent, hint, sz, pos)
    local tb = Instance.new("TextBox")
    tb.PlaceholderText   = hint
    tb.Text              = ""
    tb.Size              = sz
    tb.Position          = pos
    tb.BackgroundColor3  = CLR.BG
    tb.TextColor3        = CLR.Text
    tb.PlaceholderColor3 = CLR.Muted
    tb.TextSize          = 12
    tb.Font              = Enum.Font.Gotham
    tb.BorderSizePixel   = 0
    tb.ClearTextOnFocus  = false
    tb.Parent            = parent
    Instance.new("UICorner", tb).CornerRadius = UDim.new(0, 6)
    Stroke(tb, CLR.Border, 1)
    return tb
end

-- Button with press-scale + tween color
local function Button(parent, text, sz, pos, cb, color)
    local base = color or CLR.Accent
    local hi   = base:Lerp(Color3.new(1,1,1), .12)
    local btn  = Instance.new("TextButton")
    btn.Text             = text
    btn.Size             = sz
    btn.Position         = pos
    btn.BackgroundColor3 = base
    btn.TextColor3       = CLR.Text
    btn.TextSize         = 12
    btn.Font             = Enum.Font.GothamBold
    btn.BorderSizePixel  = 0
    btn.AutoButtonColor  = false
    btn.Parent           = parent
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 7)

    btn.MouseEnter:Connect(function()
        TweenService:Create(btn, TFAST, {BackgroundColor3 = hi}):Play()
    end)
    btn.MouseLeave:Connect(function()
        TweenService:Create(btn, TFAST, {BackgroundColor3 = base}):Play()
    end)
    btn.MouseButton1Down:Connect(function()
        TweenService:Create(btn, TI(.07), {Size = sz - UDim2.new(0,2,0,2),
            Position = pos + UDim2.new(0,1,0,1)}):Play()
    end)
    btn.MouseButton1Up:Connect(function()
        TweenService:Create(btn, TI(.1), {Size = sz, Position = pos}):Play()
    end)
    btn.MouseButton1Click:Connect(cb)
    return btn
end

-- Toggle (pill) — returns set of refs so caller can update label color
local function Toggle(parent, text, yOff, tbl, key, onChange)
    local row = Frame(parent, UDim2.new(1,-20,0,30), UDim2.new(0,10,0,yOff), CLR.Panel)
    row.BackgroundTransparency = 1

    local lbl  = Label(row, text, UDim2.new(1,-52,1,0), UDim2.new(0,2,0,0), CLR.Text, 12)
    local pill = Frame(row, UDim2.new(0,40,0,22), UDim2.new(1,-42,0.5,-11),
        tbl[key] and CLR.ON or CLR.OFF, 11)
    local knob = Frame(pill, UDim2.new(0,18,0,18),
        tbl[key] and UDim2.new(0,20,0.5,-9) or UDim2.new(0,2,0.5,-9),
        Color3.new(1,1,1), 9)
    -- knob shadow feel
    Stroke(knob, Color3.fromRGB(0,0,0), .5)

    local function Sync()
        local on = tbl[key]
        TweenService:Create(pill, TFAST, {BackgroundColor3 = on and CLR.ON or CLR.OFF}):Play()
        TweenService:Create(knob, TFAST, {Position = on
            and UDim2.new(0,20,0.5,-9) or UDim2.new(0,2,0.5,-9)}):Play()
        lbl.TextColor3 = on and CLR.Text or CLR.Muted
    end
    Sync()

    pill.InputBegan:Connect(function(i)
        if i.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        tbl[key] = not tbl[key]
        Sync()
        if onChange then onChange(tbl[key]) end
    end)
    return row, lbl
end

-- Slider — snaps on click, drags continuously
local function Slider(parent, text, yOff, mn, mx, def, onChange)
    local row = Frame(parent, UDim2.new(1,-20,0,46), UDim2.new(0,10,0,yOff), CLR.Panel)
    row.BackgroundTransparency = 1

    local vLbl = Label(row, text..":  "..tostring(def),
        UDim2.new(1,0,0,18), UDim2.new(0,0,0,0), CLR.Text, 12)

    local track = Frame(row, UDim2.new(1,0,0,6), UDim2.new(0,0,0,26), CLR.OFF, 3)
    local rel0  = (def-mn)/(mx-mn)
    local fill  = Frame(track, UDim2.new(rel0,0,1,0), UDim2.new(0,0,0,0), CLR.Accent, 3)
    local thumb = Frame(track, UDim2.new(0,14,0,14), UDim2.new(rel0,-7,0.5,-7), Color3.new(1,1,1), 7)
    Stroke(thumb, CLR.AccentHi, 1.5)

    local drag = false
    local function UpdateFromX(mx2)
        local rel = math.clamp((mx2 - track.AbsolutePosition.X)/track.AbsoluteSize.X, 0, 1)
        local val = math.round(mn + rel*(mx-mn))
        TweenService:Create(fill,  TFAST, {Size     = UDim2.new(rel,0,1,0)}):Play()
        TweenService:Create(thumb, TFAST, {Position = UDim2.new(rel,-7,0.5,-7)}):Play()
        vLbl.Text = text..":  "..tostring(val)
        if onChange then onChange(val) end
    end

    track.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then
            drag = true
            UpdateFromX(UserInputService:GetMouseLocation().X)
        end
    end)
    Track(UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then drag = false end
    end))
    Track(RunService.RenderStepped:Connect(function()
        if drag then UpdateFromX(UserInputService:GetMouseLocation().X) end
    end))
    return row
end

-- ── Toast notification ────────────────────────────────────────
local function Toast(msg, color)
    local t = Frame(SG, UDim2.new(0,240,0,36), UDim2.new(0.5,-120,1,-60), CLR.Panel, 9)
    Stroke(t, color or CLR.Accent, 1)
    Label(t, msg, UDim2.new(1,-16,1,0), UDim2.new(0,12,0,0), color or CLR.Text, 12)
    t.BackgroundTransparency = 1
    TweenService:Create(t, TSLIDE, {BackgroundTransparency = 0,
        Position = UDim2.new(0.5,-120,1,-70)}):Play()
    task.delay(2, function()
        TweenService:Create(t, TMED, {BackgroundTransparency=1,
            Position = UDim2.new(0.5,-120,1,-50)}):Play()
        task.delay(.3, function() t:Destroy() end)
    end)
end

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  MAIN WINDOW                                                 ║
-- ╚══════════════════════════════════════════════════════════════╝
local Win = Frame(SG, UDim2.new(0,440,0,510), UDim2.new(0.5,-220,0.5,-255), CLR.BG, 12)
Win.ClipsDescendants = true
Stroke(Win, CLR.Border, 1)

-- Entrance animation
Win.Position = UDim2.new(0.5,-220,0.5,-265)
Win.BackgroundTransparency = 1
TweenService:Create(Win, TSLIDE, {
    Position            = UDim2.new(0.5,-220,0.5,-255),
    BackgroundTransparency = 0,
}):Play()

-- ── Title bar ─────────────────────────────────────────────────
local TBar = Frame(Win, UDim2.new(1,0,0,40), UDim2.new(0,0,0,0), CLR.Accent, 12)
Frame(TBar, UDim2.new(1,0,0.5,0), UDim2.new(0,0,0.5,0), CLR.Accent) -- flatten bottom

-- Accent glow strip below title
local glow = Frame(Win, UDim2.new(1,0,0,2), UDim2.new(0,0,0,40), CLR.AccentGlow)

-- Logo + title
Label(TBar, "  ⚡ RIVALS HUB", UDim2.new(1,-120,1,0), UDim2.new(0,0,0,0), CLR.Text, 15)
Label(TBar, "v3.0", UDim2.new(0,40,1,0), UDim2.new(0.5,-20,0,0), Color3.fromRGB(200,180,255), 10, Enum.Font.Gotham)

-- Control buttons
local function TBarBtn(lbl, xOff, col, cb)
    local b = Button(TBar, lbl, UDim2.new(0,26,0,26), UDim2.new(1,xOff,0.5,-13), cb, col)
    b.TextSize = 12
    return b
end
TBarBtn("✕", -32, CLR.Red,  function() SG:Destroy() end)
TBarBtn("—", -62, CLR.SubMuted, function()
    for _,c in Win:GetChildren() do
        if c ~= TBar and c ~= glow then
            c.Visible = not c.Visible
        end
    end
end)

-- Draggable
do
    local dragging, ds, sp = false, nil, nil
    TBar.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging, ds, sp = true, i.Position, Win.Position
        end
    end)
    Track(UserInputService.InputChanged:Connect(function(i)
        if dragging and i.UserInputType == Enum.UserInputType.MouseMoved then
            local d = i.Position - ds
            Win.Position = UDim2.new(sp.X.Scale, sp.X.Offset+d.X, sp.Y.Scale, sp.Y.Offset+d.Y)
        end
    end))
    Track(UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end))
end

-- ── Tab bar ───────────────────────────────────────────────────
local TABS      = {"Aimbot","Skinchanger","Wraps & Charms","Misc"}
local tabFrames = {}
local tabBtns   = {}

local TBarF = Frame(Win, UDim2.new(1,0,0,34), UDim2.new(0,0,0,42), CLR.Panel)
-- Separator line
Frame(Win, UDim2.new(1,0,0,1), UDim2.new(0,0,0,76), CLR.Border)

local function ActivateTab(name)
    for _, n in ipairs(TABS) do
        local on = (n == name)
        tabFrames[n].Visible = on
        TweenService:Create(tabBtns[n], TFAST, {
            TextColor3       = on and CLR.Text   or CLR.Muted,
            BackgroundColor3 = on and CLR.PanelHi or CLR.Panel,
        }):Play()
        -- active underline
        local ul = tabBtns[n]:FindFirstChild("Underline")
        if ul then
            TweenService:Create(ul, TFAST, {BackgroundColor3 = on and CLR.AccentHi or CLR.Panel}):Play()
        end
    end
end

for i, name in ipairs(TABS) do
    local tb = Instance.new("TextButton")
    tb.Text             = name
    tb.Size             = UDim2.new(1/#TABS, 0, 1, 0)
    tb.Position         = UDim2.new((i-1)/#TABS, 0, 0, 0)
    tb.BackgroundColor3 = CLR.Panel
    tb.TextColor3       = CLR.Muted
    tb.TextSize         = 11
    tb.Font             = Enum.Font.GothamBold
    tb.BorderSizePixel  = 0
    tb.AutoButtonColor  = false
    tb.Parent           = TBarF
    -- active underline indicator
    local ul = Frame(tb, UDim2.new(0.6,0,0,2), UDim2.new(0.2,0,1,-2), CLR.Panel, 1)
    ul.Name = "Underline"

    tabBtns[name] = tb

    -- Content frame (scrollable)
    local scroll = Instance.new("ScrollingFrame")
    scroll.Size              = UDim2.new(1,-20,1,-88)
    scroll.Position          = UDim2.new(0,10,0,82)
    scroll.BackgroundColor3  = CLR.Panel
    scroll.BorderSizePixel   = 0
    scroll.ScrollBarThickness= 3
    scroll.ScrollBarImageColor3 = CLR.AccentHi
    scroll.CanvasSize        = UDim2.new(0,0,0,0)
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroll.Visible           = false
    scroll.Parent            = Win
    Instance.new("UICorner", scroll).CornerRadius = UDim.new(0,8)
    -- inner padding
    local pad = Instance.new("UIPadding", scroll)
    pad.PaddingTop    = UDim.new(0,8)
    pad.PaddingBottom = UDim.new(0,12)
    local list = Instance.new("UIListLayout", scroll)
    list.Padding           = UDim.new(0, 6)
    list.SortOrder         = Enum.SortOrder.LayoutOrder
    list.FillDirection     = Enum.FillDirection.Vertical

    tabFrames[name] = scroll
    tb.MouseButton1Click:Connect(function() ActivateTab(name) end)
end
ActivateTab("Aimbot")

-- ── Section header helper ─────────────────────────────────────
local function Section(parent, title, order)
    local hdr = Frame(parent, UDim2.new(1,0,0,24), UDim2.new(0,0,0,0), CLR.PanelHi, 5)
    hdr.LayoutOrder = order or 0
    Label(hdr, "  "..title, UDim2.new(1,0,1,0), UDim2.new(0,0,0,0), CLR.AccentHi, 11, Enum.Font.GothamBold)
    return hdr
end

-- Helper: add a widget to a scrollframe with LayoutOrder
local function Add(frame, widget, order)
    widget.Parent      = frame
    widget.LayoutOrder = order or 0
    widget.Size        = UDim2.new(1, -8, 0, widget.Size.Y.Offset)
    return widget
end

-- ── Toggle row as its own frame for list layout ───────────────
local function ListToggle(parent, text, tbl, key, order, onChange)
    local row = Frame(parent, UDim2.new(1,-8,0,34), UDim2.new(0,0,0,0), CLR.PanelHi, 6)
    row.LayoutOrder = order

    local lbl  = Label(row, "  "..text, UDim2.new(1,-52,1,0), UDim2.new(0,0,0,0),
        tbl[key] and CLR.Text or CLR.Muted, 12)
    local pill = Frame(row, UDim2.new(0,40,0,22), UDim2.new(1,-46,0.5,-11),
        tbl[key] and CLR.ON or CLR.OFF, 11)
    local knob = Frame(pill, UDim2.new(0,18,0,18),
        tbl[key] and UDim2.new(0,20,0.5,-9) or UDim2.new(0,2,0.5,-9),
        Color3.new(1,1,1), 9)

    local function Sync()
        local on = tbl[key]
        TweenService:Create(pill, TFAST, {BackgroundColor3 = on and CLR.ON or CLR.OFF}):Play()
        TweenService:Create(knob, TFAST, {Position = on
            and UDim2.new(0,20,0.5,-9) or UDim2.new(0,2,0.5,-9)}):Play()
        TweenService:Create(lbl,  TFAST, {TextColor3 = on and CLR.Text or CLR.Muted}):Play()
    end
    Sync()
    pill.InputBegan:Connect(function(i)
        if i.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        tbl[key] = not tbl[key]
        Sync()
        if onChange then onChange(tbl[key]) end
    end)
    return row
end

local function ListSlider(parent, text, mn, mx, def, order, onChange)
    local row = Frame(parent, UDim2.new(1,-8,0,50), UDim2.new(0,0,0,0), CLR.PanelHi, 6)
    row.LayoutOrder = order

    local vLbl = Label(row, "  "..text..":  "..tostring(def),
        UDim2.new(1,0,0,18), UDim2.new(0,0,0,4), CLR.Text, 12)

    local track = Frame(row, UDim2.new(1,-16,0,6), UDim2.new(0,8,0,28), CLR.OFF, 3)
    local rel0  = (def-mn)/(mx-mn)
    local fill  = Frame(track, UDim2.new(rel0,0,1,0), UDim2.new(0,0,0,0), CLR.Accent, 3)
    local thumb = Frame(track, UDim2.new(0,14,0,14), UDim2.new(rel0,-7,0.5,-7), Color3.new(1,1,1), 7)
    Stroke(thumb, CLR.AccentHi, 1.5)

    local drag = false
    local function UX(mx2)
        local rel = math.clamp((mx2 - track.AbsolutePosition.X)/track.AbsoluteSize.X, 0, 1)
        local val = math.round(mn + rel*(mx-mn))
        TweenService:Create(fill,  TFAST, {Size     = UDim2.new(rel,0,1,0)}):Play()
        TweenService:Create(thumb, TFAST, {Position = UDim2.new(rel,-7,0.5,-7)}):Play()
        vLbl.Text = "  "..text..":  "..tostring(val)
        if onChange then onChange(val) end
    end

    track.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then
            drag = true; UX(UserInputService:GetMouseLocation().X)
        end
    end)
    Track(UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then drag = false end
    end))
    Track(RunService.RenderStepped:Connect(function()
        if drag then UX(UserInputService:GetMouseLocation().X) end
    end))
    return row
end

local function ListButton(parent, text, order, cb, color)
    local btn = Button(parent, text,
        UDim2.new(1,-8,0,32), UDim2.new(0,0,0,0), cb, color)
    btn.LayoutOrder = order
    return btn
end

local function ListTextBox(parent, hint, order)
    local tb = TextBox(parent, hint, UDim2.new(1,-8,0,30), UDim2.new(0,0,0,0))
    tb.LayoutOrder = order
    return tb
end

local function ListLabel(parent, text, order, color)
    local l = Label(parent, "  "..text, UDim2.new(1,-8,0,18), UDim2.new(0,0,0,0),
        color or CLR.Muted, 10, Enum.Font.Gotham)
    l.LayoutOrder = order
    return l
end

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  TAB: AIMBOT                                                 ║
-- ╚══════════════════════════════════════════════════════════════╝
local AF = tabFrames["Aimbot"]

Section(AF, "TARGETING", 0)
ListToggle(AF, "Aimbot Enabled",  Cfg.Aimbot, "Enabled",     1)
ListToggle(AF, "Silent Aim",      Cfg.Aimbot, "SilentAim",   2)
ListToggle(AF, "Visible Only",    Cfg.Aimbot, "VisibleOnly",  3)
ListToggle(AF, "Team Check",      Cfg.Aimbot, "TeamCheck",    4)
ListToggle(AF, "Show FOV Circle", Cfg.Aimbot, "ShowFOV",      5)

Section(AF, "PRECISION", 6)
ListSlider(AF, "FOV Radius",     30, 500, Cfg.Aimbot.FOV, 7, function(v)
    Cfg.Aimbot.FOV = v
end)
ListSlider(AF, "Snap Speed",     1, 30, Cfg.Aimbot.Smoothness, 8, function(v)
    Cfg.Aimbot.Smoothness = v
end)
ListSlider(AF, "Prediction (ms)", 0, 200, math.round(Cfg.Aimbot.Prediction*1000), 9, function(v)
    Cfg.Aimbot.Prediction = v / 1000
end)

Section(AF, "HITBOX", 10)
-- Hitbox selector with active highlight
local hitboxOpts = {"Head","Torso","HumanoidRootPart"}
local hitboxBtns = {}
local hbRow = Frame(AF, UDim2.new(1,-8,0,34), UDim2.new(0,0,0,0), CLR.PanelHi, 6)
hbRow.LayoutOrder = 11
for i, t in ipairs(hitboxOpts) do
    local b = Button(hbRow, t,
        UDim2.new(1/#hitboxOpts,-4,0,26),
        UDim2.new((i-1)/#hitboxOpts, i==1 and 4 or 2, 0.5,-13),
        function()
            Cfg.Aimbot.Target = t
            for _, hb in pairs(hitboxBtns) do
                TweenService:Create(hb, TFAST, {
                    BackgroundColor3 = hb == hitboxBtns[t] and CLR.AccentHi or CLR.Accent
                }):Play()
            end
        end, Cfg.Aimbot.Target == t and CLR.AccentHi or CLR.Accent)
    b.TextSize = 10
    hitboxBtns[t] = b
end

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  TAB: SKINCHANGER                                            ║
-- ╚══════════════════════════════════════════════════════════════╝
local SF = tabFrames["Skinchanger"]

Section(SF, "CLOTHING IDs", 0)
ListLabel(SF, "Shirt Asset ID", 1, CLR.Muted)
local shirtBox = ListTextBox(SF, "rbxassetid://...", 2)
ListLabel(SF, "Pants Asset ID", 3, CLR.Muted)
local pantsBox = ListTextBox(SF, "rbxassetid://...", 4)
ListLabel(SF, "Face Decal ID", 5, CLR.Muted)
local faceBox  = ListTextBox(SF, "rbxassetid://...", 6)

Section(SF, "APPEARANCE", 7)
ListSlider(SF, "Body Transparency", 0, 100, 0, 8, function(v)
    Cfg.Skin.Transparency = v/100
    ApplyTransp()
end)

Section(SF, "QUICK PRESETS", 9)
local presets = {
    {name="Default",    shirt="",                     pants=""                    },
    {name="Classic",    shirt="rbxassetid://585842",   pants="rbxassetid://585848" },
    {name="Invisible",  shirt="",                     pants="",    trans=100       },
    {name="All Black",  shirt="rbxassetid://12659393", pants="rbxassetid://12819319"},
}
local presetRow = Frame(SF, UDim2.new(1,-8,0,34), UDim2.new(0,0,0,0), CLR.PanelHi, 6)
presetRow.LayoutOrder = 10
for i, p in ipairs(presets) do
    Button(presetRow, p.name,
        UDim2.new(1/#presets,-3,0,26),
        UDim2.new((i-1)/#presets, i==1 and 3 or 2, 0.5,-13),
        function()
            shirtBox.Text = p.shirt or ""
            pantsBox.Text = p.pants or ""
            if p.trans then
                Cfg.Skin.Transparency = p.trans/100
                ApplyTransp()
            end
        end, CLR.AccentGlow)
end

ListButton(SF, "✔  Apply Skin", 11, function()
    local char = LocalPlayer.Character; if not char then return end
    Cfg.Skin.ShirtId = shirtBox.Text
    Cfg.Skin.PantsId = pantsBox.Text
    Cfg.Skin.FaceId  = faceBox.Text
    if Cfg.Skin.ShirtId ~= "" then
        local s = char:FindFirstChildOfClass("Shirt") or Instance.new("Shirt",char)
        s.ShirtTemplate = Cfg.Skin.ShirtId
    end
    if Cfg.Skin.PantsId ~= "" then
        local p = char:FindFirstChildOfClass("Pants") or Instance.new("Pants",char)
        p.PantsTemplate = Cfg.Skin.PantsId
    end
    if Cfg.Skin.FaceId ~= "" then
        local head = char:FindFirstChild("Head")
        local face = head and (head:FindFirstChild("face") or head:FindFirstChild("Face"))
        if face and face:IsA("Decal") then face.Texture = Cfg.Skin.FaceId end
    end
    ApplyTransp()
    Toast("✔ Skin applied!", CLR.Green)
end, CLR.Green)

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  TAB: WRAPS & CHARMS                                         ║
-- ╚══════════════════════════════════════════════════════════════╝
local WF = tabFrames["Wraps & Charms"]

Section(WF, "COSMETIC UNLOCK", 0)
ListLabel(WF, "Patches client-side cosmetic ownership.", 1, CLR.Muted)
ListLabel(WF, "Items appear selectable in the loadout UI.", 2, CLR.Muted)

ListToggle(WF, "Unlock All Wraps",  Cfg, "Wraps",  3, function(on)
    PatchCosmetics(on)
    Toast(on and "✔ Wraps unlocked!" or "Wraps locked.", on and CLR.Gold or CLR.Muted)
end)
ListToggle(WF, "Unlock All Charms", Cfg, "Charms", 4, function(on)
    PatchCosmetics(on)
    Toast(on and "✔ Charms unlocked!" or "Charms locked.", on and CLR.Gold or CLR.Muted)
end)

Section(WF, "MANUAL PATCH", 5)
ListLabel(WF, "Force-run the ownership patcher now.", 6, CLR.Muted)
ListButton(WF, "⚡ Run Cosmetic Patcher", 7, function()
    PatchCosmetics(true)
    Toast("Cosmetic patcher ran!", CLR.Gold)
end, CLR.Gold)

ListButton(WF, "↺ Revert Cosmetics", 8, function()
    PatchCosmetics(false)
    Toast("Cosmetics reverted.", CLR.Muted)
end, CLR.SubMuted)

Section(WF, "HOW IT WORKS", 9)
ListLabel(WF, "Scans ReplicatedStorage for owned-item", 10, CLR.Muted)
ListLabel(WF, "tables and hooks ownership RemoteFunctions.", 11, CLR.Muted)
ListLabel(WF, "Does not affect other players or the server.", 12, CLR.Muted)

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  TAB: MISC                                                   ║
-- ╚══════════════════════════════════════════════════════════════╝
local MF = tabFrames["Misc"]

Section(MF, "MOVEMENT", 0)
ListToggle(MF, "NoClip",     Cfg, "NoClip",     1, SetNoClip)
ListToggle(MF, "Speed Boost",Cfg, "SpeedBoost", 2, function(on)
    local h = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
    if h then h.WalkSpeed = on and Cfg.SpeedValue or 16 end
end)
ListSlider(MF, "Walk Speed", 16, 150, Cfg.SpeedValue, 3, function(v)
    Cfg.SpeedValue = v
    if Cfg.SpeedBoost then
        local h = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
        if h then h.WalkSpeed = v end
    end
end)

Section(MF, "VISUALS", 4)
ListToggle(MF, "ESP Nametags", Cfg, "ESP", 5, function()
    espDirty = true
end)

Section(MF, "ACTIONS", 6)
do
    local row = Frame(MF, UDim2.new(1,-8,0,34), UDim2.new(0,0,0,0), CLR.PanelHi, 6)
    row.LayoutOrder = 7
    Button(row, "Respawn",
        UDim2.new(0.5,-3,0,26), UDim2.new(0,4,0.5,-13),
        function() LocalPlayer:LoadCharacter() end)
    Button(row, "Unload",
        UDim2.new(0.5,-3,0,26), UDim2.new(0.5,2,0.5,-13),
        function() SG:Destroy() end, CLR.Red)
end
ListButton(MF, "Clear All ESP", 8, function()
    for _, pl in Players:GetPlayers() do
        local c = pl.Character
        local h = c and c:FindFirstChild("HumanoidRootPart")
        local b = h and h:FindFirstChild("ESPBillboard")
        if b then b:Destroy() end
    end
    Toast("ESP cleared.", CLR.Muted)
end, CLR.SubMuted)

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  AIMBOT ENGINE                                               ║
-- ╚══════════════════════════════════════════════════════════════╝

-- Drawing FOV circle
local FOVCircle
pcall(function()
    FOVCircle           = Drawing.new("Circle")
    FOVCircle.Visible   = false
    FOVCircle.Thickness = 1.5
    FOVCircle.Filled    = false
    FOVCircle.NumSides  = 90
    FOVCircle.Color     = Cfg.Aimbot.FOVColor
end)

local function GetBestTarget()
    local bestPart, bestDist = nil, math.huge
    local center = V2Center()

    for _, pl in Players:GetPlayers() do
        if pl == LocalPlayer then continue end
        if Cfg.Aimbot.TeamCheck and pl.Team == LocalPlayer.Team then continue end
        if not IsAlive(pl) then continue end

        local char = pl.Character
        local part = char:FindFirstChild(Cfg.Aimbot.Target)
        if not part then continue end

        -- Predict position: part + velocity * prediction_time
        local predicted = part.Position + GetVelocity(part) * Cfg.Aimbot.Prediction

        if Cfg.Aimbot.VisibleOnly then
            -- Visibility check against predicted position
            local cam    = Cam()
            local origin = cam.CFrame.Position
            local dir    = predicted - origin
            local rp = RaycastParams.new()
            rp.FilterType = Enum.RaycastFilterType.Exclude
            local myChar = LocalPlayer.Character
            rp.FilterDescendantsInstances = myChar and {myChar} or {}
            local res = workspace:Raycast(origin, dir, rp)
            if res and res.Instance ~= part and not res.Instance:IsDescendantOf(char) then
                continue
            end
        end

        local screen, onScreen = WorldToScreen(predicted)
        if not onScreen then continue end

        local dist = (screen - center).Magnitude
        if dist < Cfg.Aimbot.FOV and dist < bestDist then
            bestDist = dist
            bestPart = {part = part, predicted = predicted}
        end
    end
    return bestPart
end

-- ── ESP state ─────────────────────────────────────────────────
local espDirty = true  -- rebuild on first frame

local function RebuildESP()
    espDirty = false
    for _, pl in Players:GetPlayers() do
        if pl == LocalPlayer then continue end
        local char = pl.Character; if not char then continue end
        local hrp  = char:FindFirstChild("HumanoidRootPart"); if not hrp then continue end
        local existing = hrp:FindFirstChild("ESPBillboard")
        if Cfg.ESP then
            if not existing then
                local bb = Instance.new("BillboardGui", hrp)
                bb.Name         = "ESPBillboard"
                bb.Size         = UDim2.new(0,120,0,36)
                bb.StudsOffset  = Vector3.new(0,3.5,0)
                bb.AlwaysOnTop  = true
                local lbl = Instance.new("TextLabel", bb)
                lbl.Size                   = UDim2.new(1,0,0.6,0)
                lbl.Position               = UDim2.new(0,0,0,0)
                lbl.BackgroundTransparency = 1
                lbl.TextColor3             = Color3.fromRGB(255,75,75)
                lbl.TextSize               = 14
                lbl.Font                   = Enum.Font.GothamBold
                lbl.Text                   = pl.Name
                lbl.TextStrokeTransparency = 0.3
                -- Health bar
                local hbBG = Instance.new("Frame", bb)
                hbBG.Size = UDim2.new(1,0,0,4); hbBG.Position = UDim2.new(0,0,1,-4)
                hbBG.BackgroundColor3 = Color3.fromRGB(50,50,50); hbBG.BorderSizePixel = 0
                local hbFill = Instance.new("Frame", hbBG)
                hbFill.Name = "Fill"; hbFill.Size = UDim2.new(1,0,1,0)
                hbFill.BackgroundColor3 = CLR.Green; hbFill.BorderSizePixel = 0
                Track(RunService.Heartbeat:Connect(function()
                    local hum = char:FindFirstChildOfClass("Humanoid")
                    if hum then
                        hbFill.Size = UDim2.new(hum.Health/hum.MaxHealth,0,1,0)
                    end
                end))
            end
        else
            if existing then existing:Destroy() end
        end
    end
end

Track(Players.PlayerAdded:Connect(function()   espDirty = true end))
Track(Players.PlayerRemoving:Connect(function() espDirty = true end))

-- ── Main render loop ──────────────────────────────────────────
local lastESP = Cfg.ESP
local MainLoop = Track(RunService.RenderStepped:Connect(function(dt)
    local cam = Cam()

    -- FOV circle
    if FOVCircle then
        FOVCircle.Visible  = Cfg.Aimbot.ShowFOV and Cfg.Aimbot.Enabled
        FOVCircle.Radius   = Cfg.Aimbot.FOV
        FOVCircle.Position = Vector2.new(cam.ViewportSize.X*.5, cam.ViewportSize.Y*.5)
        FOVCircle.Color    = Cfg.Aimbot.FOVColor
    end

    -- Aimbot
    if Cfg.Aimbot.Enabled and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
        local res = GetBestTarget()
        if res then
            if Cfg.Aimbot.SilentAim then
                -- Silent aim: redirect bullet via moving mouse delta-matched to target screen pos
                local screen, on = WorldToScreen(res.predicted)
                if on then
                    local center = V2Center()
                    local delta  = screen - center
                    -- move mouse incrementally toward target
                    local step = math.min(delta.Magnitude, Cfg.Aimbot.Smoothness * dt * 60) / delta.Magnitude
                    mousemoverel(delta.X * step, delta.Y * step)
                end
            else
                -- Camera lerp — delta-time corrected, angular-speed based
                local targetCF = CFrame.new(cam.CFrame.Position, res.predicted)
                -- Convert smoothness (deg/frame@60fps) to alpha for this frame
                local angle   = math.deg(math.acos(math.clamp(
                    cam.CFrame.LookVector:Dot(targetCF.LookVector), -1, 1)))
                local alpha   = math.min(1, (Cfg.Aimbot.Smoothness * dt * 60) / math.max(angle, 0.001))
                cam.CFrame = cam.CFrame:Lerp(targetCF, alpha)
            end
        end
    end

    -- ESP dirty watch
    if Cfg.ESP ~= lastESP then lastESP = Cfg.ESP; espDirty = true end
    if espDirty then RebuildESP() end
end))

if getgenv then getgenv().RivalsHub_Loop = MainLoop end

-- ── Cleanup ───────────────────────────────────────────────────
SG.AncestryChanged:Connect(function()
    for _, c in Conns do pcall(function() c:Disconnect() end) end
    if FOVCircle then pcall(function() FOVCircle:Remove() end) end
    if ncConn    then pcall(function() ncConn:Disconnect() end) end
    if getgenv   then getgenv().RivalsHub_Loop = nil end
end)

Toast("⚡ RIVALS HUB v3.0 loaded!", CLR.AccentHi)
print("[RivalsHub v3.0] ✓ Loaded")
