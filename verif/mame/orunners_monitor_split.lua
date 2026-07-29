-- OutRunners gameplay sprite-list census, started from a save state.
--
-- Multi 32 feeds BOTH monitors from a single sprite display list; bit 11 of
-- descriptor word 3 selects which monitor a sprite belongs to (MAME
-- segas32_v.cpp:1332, BIT(data[3],11) -> MULTISPR layer).  The MiSTer core
-- presents only one monitor at a time but still renders every descriptor into
-- four physical buffers, so if the list is split roughly evenly then roughly
-- half of the sprite-engine time and DDR3 framebuffer traffic in gameplay is
-- spent on pixels that are never displayed.
--
-- This walks the list exactly as sprite_render_list() does (top two bits of
-- word 0 are the command: 0=draw, 1=clip, 2=jump, 3=done) and reports the
-- per-frame census so that waste can be quantified instead of assumed.
local mach = manager.machine
local cpu  = mach.devices[":mainpcb:maincpu"]
local sp   = cpu.spaces["program"]

local OUT = "/mnt/d/Arcade/AI/s32/scratch/mame_sta/monitor_split.csv"
local FRAMES = tonumber(os.getenv("SPLIT_FRAMES") or "60")

local function rd(word_index)
    return sp:read_u16(0x400000 + word_index * 2)
end

local function census()
    local drawn, mon_a, mon_b, clips, jumps = 0, 0, 0, 0, 0
    local spritenum, entries = 0, 0
    while entries < 0x2000 do
        entries = entries + 1
        local base = (spritenum & 0x1fff) * 8
        local w0 = rd(base + 0)
        local cmd = (w0 >> 14) & 3
        if cmd == 0 then
            local w3 = rd(base + 3)
            drawn = drawn + 1
            if (w3 & 0x0800) ~= 0 then mon_b = mon_b + 1 else mon_a = mon_a + 1 end
            spritenum = spritenum + 1
        elseif cmd == 1 then
            clips = clips + 1
            spritenum = spritenum + 1
        elseif cmd == 2 then
            jumps = jumps + 1
            local target = w0 & 0x1fff
            if target == (spritenum & 0x1fff) then break end -- self-jump guard
            spritenum = target
        else
            break -- command 3 = done
        end
    end
    return drawn, mon_a, mon_b, clips, jumps, entries
end

local fh = io.open(OUT, "w")
fh:write("frame,drawn,mon_a,mon_b,clips,jumps,entries\n")

local fr = 0
_G.split_probe = emu.add_machine_frame_notifier(function()
    fr = fr + 1
    local drawn, a, b, c, j, e = census()
    fh:write(string.format("%d,%d,%d,%d,%d,%d,%d\n", fr, drawn, a, b, c, j, e))
    if fr % 20 == 0 then
        print(string.format("[split] frame %d drawn=%d monA=%d monB=%d", fr, drawn, a, b))
    end
    if fr >= FRAMES then
        fh:close()
        print("[split] wrote " .. OUT)
        mach:exit()
    end
end)
