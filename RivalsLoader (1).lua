-- ╔══════════════════════════════════════════════════════╗
-- ║   RIVALS HUB v3.0  —  LOADER                        ║
-- ║   Paste ONE line into your executor:                 ║
-- ║                                                      ║
-- ║   loadstring(game:HttpGet("YOUR_RAW_URL",true))()   ║
-- ╚══════════════════════════════════════════════════════╝

-- 1. Upload RivalsScript.lua to a public GitHub repo
-- 2. Open the file → click "Raw" → copy the URL
-- 3. Replace YOUR_RAW_URL below with that link
-- 4. Run this loader in Synapse X / KRNL / Fluxus / etc.

local RAW_URL = "https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/RivalsScript.lua"

-- Guard: warn but still reload
if getgenv().RivalsHub_Loop then
    warn("[RivalsHub] Reloading...")
end

local ok, src = pcall(game.HttpGet, game, RAW_URL, true)
if not ok then
    warn("[RivalsHub] HTTP fetch failed: " .. tostring(src))
    warn("Make sure HTTP Requests are ON in executor settings.")
    return
end

local fn, err = loadstring(src)
if not fn then
    warn("[RivalsHub] Compile error: " .. tostring(err))
    return
end

fn()
