-- OutRunners right-edge reference capture, started from a gameplay save state.
--
-- Our core and MAME disagree in a 7-pixel strip at the last columns of a line
-- (x=313..319 of the 320-wide display) whenever the sprite workload changes.
-- s32_fb_if keeps ONE run accumulator (run_msk/run_x0/run_xe/run_bufsel) that
-- both Multi 32 monitors pass through, so a boundary bug there is sensitive to
-- how the two monitors' runs interleave.  MAME clips sprites to
-- outerclip.max_x = 319 (415 in 416-mode) inside draw_one_sprite(), so its
-- output is the authority for what those columns should contain.
--
-- Dumps both screens as PNG so the edge columns can be diffed against the RTL
-- framebuffer, and records the sprite-control width bit that selects 320 vs 416.
local mach = manager.machine
local scr = {}
for tag, s in pairs(mach.screens) do scr[#scr + 1] = { tag = tag, dev = s } end
table.sort(scr, function(a, b) return a.tag < b.tag end)

local OUTDIR = "/mnt/d/Arcade/AI/s32/scratch/mame_edge"
local FRAMES = tonumber(os.getenv("EDGE_FRAMES") or "8")
local fr = 0

print(string.format("[edge] %d screen(s) found", #scr))
for i, s in ipairs(scr) do print(string.format("[edge]   screen %d: %s", i, s.tag)) end

_G.edge_probe = emu.add_machine_frame_notifier(function()
    fr = fr + 1
    if fr <= FRAMES then
        for i, s in ipairs(scr) do
            local w, h = s.dev.width, s.dev.height
            local path = string.format("%s/f%02d_screen%d.png", OUTDIR, fr, i - 1)
            s.dev:snapshot(path)
            if fr == 1 then
                print(string.format("[edge] screen %d visible area %dx%d", i - 1, w, h))
            end
        end
    end
    if fr >= FRAMES then
        print("[edge] captured " .. FRAMES .. " frames to " .. OUTDIR)
        mach:exit()
    end
end)
