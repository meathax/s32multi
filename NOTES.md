# NOTES.md — MAME/Verilator differential-debug iteration log

## Infrastructure gate audit (2026-08-14, ga2 investigation)

Per the mister-mame-diff skill's MANDATORY INFRASTRUCTURE GATE, audited before divergence hunting:

1. **Frame-lockstep wired** — NOT PRESENT. No `scripts/run_frame_lockstep.py`,
   `assets/mame_frame_agent.lua`/`verilator_frame_server.cpp` equivalent exists in this repo.
   WAIVED for this pass per explicit task instruction (time-boxed single investigative pass).
   Used the skill's documented fallback instead: existing MAME PPM ladder
   (`scratch/mame_ga2_attract/*.png`, every 15 MAME-frames) + fresh targeted Verilator
   per-frame trace dumps from the existing `tb_core_romboot.sv` harness, diffed by inspection
   in ascending frame order.
2. **Milestone checkpoints** — NOT PRESENT for ga2 on the Verilator side (`--timing` build,
   `--savable` not combined per `s32-no-verilator-checkpoints` memory). Every run in this pass
   was a cold boot via `verif/verilator/run_romboot.sh ga2 <frames>`. No MAME save states were
   created either (session was launched fresh via `mame_launch` and free-run, not checkpointed).
   WAIVED — reruns in this pass were cheap (~150 frames, a few minutes) so cold boot was acceptable.
3. **RAM-hash gate before pixel gate** — NOT built (no per-frame RAM-hash export exists on the
   RTL side). The existing testbench instead exposes scalar per-frame counters/registers
   (`n_irq`, `n_intc_wr`, PC, `core.intc.pending/ctl[]`, sprite-engine counters, work-RAM word
   probes) via `$display`, which is what this pass used as the localization signal instead of a
   RAM hash. This is weaker than the mandated RAM-hash ladder but was sufficient to localize the
   divergence to an exact frame and PC.
4. **NOTES.md iteration log** — did not exist; created here.

These gaps are pre-existing project state, not introduced by this pass. Building the full
lockstep+checkpoint infrastructure for ga2 is recommended as a follow-up task before further
divergence hunting on this core, per the skill's own guidance.

---

## Iteration 1 — ga2 zero-sprite-pixels root cause (investigation only, no RTL fix applied)

**Scenario / first divergence before fix:** ga2 (Golden Axe: The Revenge of Death Adder),
`verif/verilator/run_romboot.sh ga2 150`, default `fast_v60=0` (current post-742c843 hardware
config). Testbench's own hard assertion fires: `tb_core_romboot.sv:2289 "GA2 reached gameplay
window without any sprite pixels"`. `spr_px` (cumulative sprite-framebuffer-write counter) is 0
across the entire run from frame 0 through the assertion.

**MAME MCP preflight/session status:** `ping` OK. `config_check` resolved
`D:\arcade\ai\mameexe\mame.exe`, cwd `D:\Arcade\AI\s32`, workdir `.mame_mcp` (rompath needed
explicit override). `audit_romset` with `rompath=D:\Arcade\AI\s32\roms` → `romset ga2 is good`.
`mame_launch` succeeded (title "Golden Axe: The Revenge of Death Adder (World, Rev B)"),
`mame_session_status` frame 2738 (free-ran during the launch bootWait). `mame_get_regs`/`mame_read_memory`
used only for a spot-check (device tag `:mainpcb:maincpu`); not used as golden reference because
MAME's free-run frame count (2738) was never aligned to the Verilator sim's reset-relative frame
count (150) — no frame-offset alignment was established (see gate item 1/frame-exactness rule 1,
waived). `mame_session_stop` called at teardown.

**MAME reference tainted:** NO for the read-only spot checks; the live session was never written to.
It was NOT used as a byte-exact reference for this iteration's conclusion (frame-offset alignment
was not built — see below), only as roughly-informative context and to confirm ROM/driver identity.

**Checkpoint used (or cold boot) / issue checkpoint saved:** Cold boot only, no checkpoints exist
for ga2 yet. No issue checkpoint saved (out of scope for this waived-infra pass).

**Alignment event and last-good / first-bad positions (Verilator side, sim-frame count from reset):**
- Last-good: sim frame 23 — `irq=10`, `intc=26`(climbing), PC actively varying (0x00132573,
  0x00132948, ...), `psw_ie=1` at frames 15-23, `core.intc.pending=0x02` (only masked
  `vblank_end` bit pending), `core.intc.ctl[6]` (mask)=`0x0e` constant, `core.intc.ctl[7]`
  (last ack write)=`0xfe` since frame 15.
- First-bad: sim frame 24 — `n_irq` reaches 11 (its final value for the rest of the run),
  `n_intc_wr` reaches 26 (its final value for the rest of the run), `core.intc.pending` becomes
  `0x03` (unmasked `vblank_start` bit, bit0, now set — `mask=0x0e` never masks bit0), so
  `irq_n` correctly asserts (0), but `core.v60.psw_ie` drops from 1 to 0 and **stays 0** for
  the remainder of the captured window (checked through frame 29 with instrumentation, and
  through frame 149 via the unchanging `n_irq`/`intc=26` in the uninstrumented full run).
  `core.v60.pc` parks in a 3-instruction loop: `00130820 → 00130826/0013082a → 00130820`,
  repeating unchanged for the rest of the 150-frame run (confirmed frames 24-149 in
  `scratch/ga2_divcheck/full_run.log`). The loop repeatedly reads work-RAM word(s) around
  byte address `0x20B146-0x20B152`, which stay constant at `0x0000` for the entire window
  (`--- last non-ROM reads ---` tail of the sim log).

**First mismatching state/register/address/event:** `core.v60.psw_ie` (V60 PSW interrupt-enable
bit, `rtl/cpu/v60/s32_v60.sv:134`) transitions 1→0 at sim frame 24, coincident with the 11th
(and final) accepted interrupt vector, and never returns to 1. This is the earliest wrong event
causally upstream of everything else observed:
- `core.intc` (`rtl/io/s32_intc`, `rtl/io/s32_io.sv:570-724`) stops seeing any further register
  writes (`ctl[7]`/ack stuck at `0xfe`, `n_intc_wr` frozen at 26) because the CPU that would
  issue those writes is stuck in a loop with interrupts disabled.
- The video timing generator (`s32_video`, `rtl/s32_core.sv:437-443`) and the sprite engine's
  automatic-mode vblank kick (`rtl/video/s32_sprite.sv:337-347`) both continue running
  correctly and independently of the V60 (`kick/frame≈223-224`, `vs_count` tracks 1:1 with sim
  frame number throughout) — ruling out the video/sprite pipeline itself as the fault. Confirmed
  by two Explore-agent RTL/MAME-source traces (see Root cause below).
- Sprite RAM is never repopulated with a real object list past frame 24 because the V60 program
  that would write it never resumes execution: `spr_cmd_cnt`/`core.sprite.scale_start` stays 0
  every frame (all descriptors decoded are degenerate/zero-sized, matching MAME's own documented
  model of an unpopulated/zero-filled spriteram — see MAME citations below), and the char-select
  object-spawn work-RAM probe block (`work_ram.mem['h2d0/'h2d3/'h2d8/'h2e8]`) stays all-zero for
  the whole run.
- Z80 sound core is also fully inactive the entire run (`snd_opcodes=0`, i.e.
  `core.sound.z_m1_n`/`z_mreq_n` never indicate an opcode fetch) — consistent with the V60 never
  reaching the later boot code that would release Z80 reset (`z80_reset = ~io0_cnt2`,
  `rtl/s32_core.sv:851`) via the 8255 PPI, since the V60 is parked before that point. Flagged as
  a downstream symptom, not independently investigated as a root cause in this pass.

**Root cause + evidence (incl. MAME source refs from D:\Arcade\AI\mame289):**
Two Explore-agent traces (RTL side and MAME side) independently confirmed the sprite-engine
kick itself is NOT the fault:
- RTL (`rtl/video/s32_sprite.sv`): the per-frame kick is `R_IDLE` exiting on
  `vblank_rise || vblank_pending` (`s32_sprite.sv:337`), driven purely by the free-running
  `s32_video` timing generator's `vbl_start`/`vbl_end` (`rtl/s32_core.sv:437-443`), with zero
  V60-bus/IO dependency in the `R_IDLE` exit condition. Sprite control register `ctl[3]` resets
  to `8'h00` (`s32_sprite.sv:305`) = automatic mode, so the engine renders every vblank even
  with no V60 writes at all. `fast_v60`/wide-fetch (commits 742c843/1d56109) only feeds the V60
  instruction-prefetch transport (`rtl/s32_core.sv:86,263-287`) and has no wire into
  `s32_sprite`'s `present`/`vblank`/`ctl_*`/`slist_*` ports.
- MAME (`segas32_v.cpp:318-348`): `update_sprites()` runs automatically 50µs after every VBLANK
  falling edge when `m_sprite_control[3]` bit1=0 (the zero-filled reset default,
  `segas32.cpp:618-619`), independent of CPU/game-code activity. `sprite_render_list()`
  (`segas32_v.cpp:1522,1544-1598`) always scans spriteram from a fixed index 0 up to 8192
  entries — no "start pointer" register, matching this RTL's `list_idx<=0` on every
  `R_RENDER` (`s32_sprite.sv:429-436`). MAME's own model conclusion: "sprites render from
  frame 1 onward automatically; you see nothing until the game's own boot/init code writes real
  entries into spriteram" — i.e., an idle/empty object list at boot is expected and matches this
  RTL's behavior up to frame 24. The divergence is that MAME's V60 program keeps running past
  that point and populates the list, while ours parks forever.

**Root cause hypothesis (not fully disambiguated within this pass's time-box):** the V60
program's interrupt handler entered on its 11th interrupt (sim frame ~23→24) does not complete
normally — it does not perform the expected acknowledgment write to the interrupt controller
(`ctl[7]`, `rtl/io/s32_io.sv` addr `3'd3`/`be[1]`, MAME's mirror `m_v60_irq_control[7]`
ack-AND semantics documented at `rtl/io/s32_io.sv:575-579`) and does not re-enable interrupts
(`psw_ie` never returns to 1). Instead, execution is parked in a 3-instruction poll loop at ROM
address `0x00130820-0x0013082a`, spinning on work-RAM word(s) near `0x20B146-0x20B152` that stay
zero for the whole window. This address is distinct from the previously-documented V25/DPRAM
mailbox region (`s32-v25-sim-vs-hw` memory: DPRAM off 0x80=V60 0xA00100) and from the
char-select object block (0x2005a0 area, `s32-ga2-select-issues` memory), so it is most likely a
different semaphore this pass did not identify — plausibly written by the Z80 sound CPU (which
never runs a single opcode in this sim) or by later V60 boot code the CPU never reaches. This
could not be fully disambiguated without a working V60/V25 disassembly view (MAME's live MCP
session here has no `-debug` debugger attached, so `cpu.debug:disassemble()` is unavailable) or
a byte-exact instruction-level MAME reference at the same program address — both out of this
pass's time-box.

**Change (files, one-line summary):** none. No RTL was modified. A temporary 3-line `$display`
was added to `verif/common/tb_core_romboot.sv` for diagnosis and was reverted via
`git checkout -- verif/common/tb_core_romboot.sv` before finishing (tree confirmed clean apart
from a pre-existing, unrelated `Arcade-SegaSystem32.qsf` modification present at session start).

**Targeted test:** N/A (investigation only). **Regressions:** not run (no RTL change).

**Checkpoints refreshed/invalidated:** none exist.

**New first divergence:** unchanged — this iteration only localizes and does not fix.

**Warnings/resource/timing delta:** N/A, no RTL touched.

**Open observability gaps / next action:**
1. No V60/V25 disassembly capability in this pass (no `-debug` MAME session, no local V60
   disassembler script). Next step: disassemble ROM bytes at `0x00130800-0x00130850` (both via
   MAME `-debug` and by reading the raw ROM image this repo loads) to identify the exact
   instructions and understand precisely what condition the poll loop is waiting on and what
   register/flag it is really testing.
2. No frame-offset alignment was established between MAME's free-run frame counter and the
   Verilator harness's reset-relative frame counter, so the MAME live session in this pass was
   not used as byte-exact ground truth for the frame-24 event — only as ROM/driver identity
   confirmation and general model corroboration (both Explore agents' MAME-source citations,
   which are frame-independent). Building that alignment (first VBLANK IRQ accepted after reset)
   is a prerequisite for a byte-exact MAME comparison at the exact divergent instruction.
3. Investigate whether the Z80 sound core's total inactivity (`snd_opcodes=0` for the whole run)
   is an independent bug or the expected consequence of the V60 never reaching the PPI write
   that releases `z80_reset` (`rtl/s32_core.sv:851`, `z80_reset = ~io0_cnt2`).
4. Confirm whether this same PC/frame-24 stall reproduces with `S32_REAL_V25` (real V25 core)
   rather than the HLE — per `s32-v25-sim-vs-hw` memory, this harness runs the HLE V25, and a
   full real-V25 run is currently infeasible in Verilator (too slow). If the stall is actually
   inside a V25-handshake wait, HLE incompleteness (not a V60/intc RTL bug) becomes the leading
   suspect and the recommended fix location changes.

---

## Iteration 1 (continued) — disassembly + register trace narrows root cause, no fix applied

**Follow-up scope (per coordinator instruction):** disassemble the stall PC region, compare
`DBR`/interrupt-controller ack semantics against MAME byte-for-byte, and either apply a confirmed
smallest RTL fix or report exactly what's blocked. Two more rounds of temporary `$display`
instrumentation were added to `verif/common/tb_core_romboot.sv` (register dump + work-RAM header
dump), used to capture evidence, then reverted with `git checkout` each time — no RTL was edited,
tree left clean apart from pre-existing unrelated modifications (see "Concurrent-session
collision" below).

**Disassembly (`D:\arcade\ai\mameexe\unidasm.exe -arch v60`, raw bytes pulled directly from
`roms/sim/ga2/maincpu.hex` at the file offset for V60 address 0x130800, i.e. this repo's actual
loaded ROM image, not a guess):**

```
130800: movz.hw [R19+], R9        ; R9 = header word at [R19], R19+=2
130803: div.w   #6, R9            ; R9 = header / 6  (outer-loop record count)
130806: mov.w   #10, R7
13080d: mov.w   #15CEAA, R6
130814: movz.hw [R19+], R17       ; \
130817: add.w   R6, R17           ;  \  outer-loop body (falls in
13081a: mov.h   [R19+], R18       ;  /  unconditionally, no R9==0 guard)
13081d: movz.hw [R19+], R8        ; /   R8 = inner-loop count
130820: movcu.h [R17], R7, [R18], R7   ; inner-loop body: block-copy R7 halfwords
130826: movea.h [R18](R7), R18         ; advance dest pointer
13082a: dbr     R8, 130820[PC]         ; inner DBR
13082e: dbr     R9, 130814[PC]         ; outer DBR
130832: rsr                            ; return from interrupt
```

This is a two-level counted-loop table unpacker (record = 3 words / 6 bytes at `[R19]`,
consumed by the outer body) that is the entire body of one interrupt handler (terminates in
`rsr`). The stall PCs from Iteration 1 (0x130820/0x130826/0x13082a) are exactly the inner-loop's
three instructions.

**Register trace across the stall (temporary `core.v60.r[6..9,17..19]` dump, sim frames 22-59,
`scratch/ga2_divcheck/divcheck2.log`):** at frame 24 (first-bad, matching the 11th accepted
interrupt from Iteration 1), `r9=00000000`, `r8=000091bc` (37308), `r6=0015ceaa`,
`r17=0015ceaa`, `r19=0020b14e`. `r8` decrements smoothly (~1500-1700/frame, consistent with a
real, executing loop) toward 0 through frame 48 (`r8=0000022a`=554). Between frame 48 and 49,
`r8` crosses zero and becomes `0xfffffc0c` (continues the *same* decrement rate as a huge
unsigned/negative value) instead of stopping, and simultaneously `r19` advances by exactly 6
bytes (`0x0020b14e` → `0x0020b154`) and `r17` changes to a freshly-loaded value (`0x0015d9aa`).
This proves the *outer* DBR loop (`13082e`, decrementing `r9`) executed exactly once more between
those two samples: `r9` was already `0` going in, `dbr r9` decremented it to `0xFFFFFFFF`
(`!= 0`), so it wrongly branched back to `130814` for one extra outer pass, which reloaded
`r8`/`r17`/`r18` from the table and re-entered the inner loop — which is now *also* running with
a corrupted, giant `r8`. The loop is not truly infinite in a hardware-broken sense; it is a
classic "decrement register started at zero, unconditionally-entered loop wraps to 0xFFFFFFFF and
takes ~4 billion iterations" runaway.

**Work-RAM content at the trigger (`core.work_ram.mem['h58a0..'h58a8]`, i.e. byte address
`0x20B140-0x20B150`, `scratch/ga2_divcheck/divcheck3.log`):** the header word at `[R19]`
(`0x0020b146`, word index `0x58a3`) reads exactly `0x0000` at frame 24 — this is the literal
source of `r9=0` after `div.w #6, R9`. Surrounding words: `58a0-58a2=0x0020` (repeated),
`58a3-58a5=0x0000` (three zero words, includes the header), `58a6=0x924e`, `58a7=0x0b00` — a
zero-filled block bounded by nonzero data, consistent with an unpopulated/not-yet-written table
slot rather than corrupted data.

**MAME source comparison — `DBR` is ruled out as an RTL bug:**
`rtl/cpu/v60/s32_v60.sv:1301-1302`:
```systemverilog
queue_reg_write(fb[1][4:0], rf_rdata_a - 1, 32'hffff_ffff);
branch_taken = cond_true(cc4) && (rf_rdata_a - 1) != 0;
```
`D:\Arcade\AI\mame289\src\devices\cpu\v60\op6.hxx:206-215` (`v60_device::opDBR`):
```cpp
uint32_t v60_device::opDBR(int reg) /* TRUSTED */
{
    m_reg[reg]--;
    if (m_reg[reg] != 0) { PC += (int16_t)OpRead16(PC + 2); return 0; }
    return 4;
}
```
Byte-for-byte identical semantics: unconditional decrement, branch iff the *decremented* value is
nonzero, no special case for entering with the register already at 0. The `cc4` condition-code
mapping was also checked against the actual instruction bytes (`c6 a8 f6 ff` / `c6 a9 e6 ff`):
`{opcode[0], fb[1][7:5]} = 4'b0101` for both, which this RTL's own decode table
(`rtl/cpu/v60/s32_v60.sv:1283`) maps to `cc4=4'ha` = `cond_true=1'b1` (always-true / plain `dbr`,
matching the disassembly's mnemonic and MAME's unconditional `opDBR`, not the sign-flag-gated
`4'h8` case). **Conclusion: given the confirmed real inputs (`r9=0` at loop entry), MAME's V60
core would execute the identical runaway.** This RTL's `DBR` decode/execute is not the bug.

**Interrupt entry/vector-fetch mechanism also checked and found architecturally correct
(`rtl/cpu/v60/s32_v60.sv:1184-1200` interrupt sampling only at `S_DECODE`/instruction boundary,
comment already documents a prior, unrelated ga2-freeze fix at `S_HALT`
resume-PC/`rtl/cpu/v60/s32_v60.sv:3730-3742`; `S_EXC_PUSH1..S_EXC_VEC`,
`rtl/cpu/v60/s32_v60.sv:3688-3708`, pushes PSW+return-PC then fetches the vector table entry at
`(sbr & ~0xfff) + exc_vector*4`+jumps — standard V60 mechanism, and critically **does not save or
restore any general-purpose register** on interrupt entry/exit, matching real V60 hardware). This
means `R6-R9,R17-R19` going into this ISR are exactly whatever the *interrupted main-loop code*
left them as — the game's own convention evidently keeps `R19` pointing at this queue/table
whenever interrupts are enabled, with the ISR trusting it unconditionally (no re-validation, no
zero-guard on the header count, no register save/restore of its own either).

**Root cause (confirmed, but not narrowly and safely fixable within this pass — see below):**
This is not a decode/execute/interrupt-controller correctness bug in this RTL — those are proven
architecturally correct and identical to MAME's modeled V60 semantics. The proximate cause is that
work RAM `0x20B146` (the record-count header this vblank ISR's queue-unpack loop reads
unconditionally) is `0` at the moment the 12th vblank interrupt is accepted in this sim, which is
a value real hardware/MAME must never present at the equivalent point (since games do not hang on
real System 32 hardware, and MAME's identical `opDBR` would runaway identically given the same
zero input). Two plausible upstream mechanisms, neither confirmed within this pass's remaining
budget:
1. **V60 instruction-level timing divergence** shifting *which exact instruction boundary* the
   vblank interrupt lands on relative to the main-loop code that is responsible for keeping this
   queue/header primed — i.e. our interrupt is accepted a small number of instructions earlier or
   later than real hardware would, catching `R19`'s target in a transient not-yet-populated state.
   This is consistent with the already-documented, explicitly risk-gated V60 per-instruction
   timing gap in memory `s32-v60-timing-reference-2026` (tier-1 Komoto/Saito/Mine table vs this
   RTL's flatter model; that memory already flags this class of fix as "gated on user risk
   decision, same class as declined Stage B" — i.e. large, cross-cutting, previously deferred, not
   a "smallest fix").
2. **A bug in whichever, currently-untraced, V60 code path is responsible for writing this
   queue/header** (the "producer" side — likely a different subroutine entirely, invoked from the
   main game loop, that queues background/decoration objects for this same vblank handler to
   unpack) — never writing a nonzero count before this particular interrupt, for reasons not yet
   investigated. This would require tracing a large, currently unmapped region of the ~1MB V60
   program, well beyond this pass's time-box.

**No RTL fix applied.** Forcing `DBR`/the loop to special-case an entering count of 0 would make
this RTL's V60 diverge from real V60 hardware's/MAME's own `opDBR` semantics (verified above) —
exactly the "paper over the symptom" move the task explicitly prohibits, since the *real* chip
does not special-case this either; the actual defect is upstream, in what value reaches this
loop, not in how the loop is executed. No candidate fix location has been isolated with enough
confidence to be "smallest and correct" per both mechanisms above; the next investigative step
(tracing the queue-producer code, or a V60 per-instruction cycle-count audit against tier-1
timing) is a substantially larger effort than this pass's time-box, is high-risk to shared
CPU-core timing (per the standing memory-note gate on the timing-table change), and was not
attempted speculatively.

**Concurrent-session collision noted:** partway through this pass, `git status --short` showed
uncommitted, in-progress changes to `rtl/s32_core.sv` and `rtl/video/s32_mixer.sv` that this
session did not make (a mixer/tilemap frame-latch change for an unrelated arabfgt
ocean/cutscene-banding issue, per its own inline comments) — consistent with the previously
documented risk of concurrent sessions sharing this worktree (see memory
`s32-ga2-select-issues.md`'s 2026-07-23 note). These files were left untouched and unreverted, as
they are not this session's work. This does not affect the V60/DBR/intc conclusions above (no
overlap with the touched files), but is recorded here since it affects the working-tree baseline
for anyone resuming this investigation.

**Targeted test / Regressions:** N/A — no RTL change was made in this continuation.

**Open next actions, in priority order:**
1. Trace the "producer" code that is supposed to populate the queue/table at work RAM
   `~0x20B140` with valid, nonzero-headed 6-byte records before this vblank interrupt fires —
   find where it's called from, and why it hasn't run (or hasn't finished) by the sim's 12th
   vblank. This is the most likely place a genuinely narrow, confirmable RTL bug (or a startup/
   boot-sequencing gap) would be found.
2. If (1) doesn't resolve it, a targeted (not full-core) instruction-level timing comparison
   between this RTL's V60 and MAME's V60 over the specific ~20-frame window before the stall
   (frames ~4-23) would show whether interrupt-relative instruction counts drift — this is a
   smaller, more scoped version of the large timing-table item already flagged in
   `s32-v60-timing-reference-2026`, and should be evaluated for risk before any timing-table RTL
   change is attempted.
3. Cross-check with `S32_REAL_V25` per Iteration 1's open item 4, since this ISR is unrelated to
   V25/protection and would presumably show the identical symptom, which would help rule in/out
   any V25-HLE-timing interaction with the main V60's interrupt cadence.

## Iteration 2026-08-15 — Golden Axe MAME attract reference only (differential incomplete)

Scenario / first divergence before fix: `ga2-cold-no-input-attract`; no RTL comparison was run in
this capture-only iteration. The requested MAME reference had previously been suspected of a
black-screen attract failure.

Completion status: **INCOMPLETE — paired MAME/Verilator differential not completed.** The MAME
lane exists, but the required Verilator and comparator receipts are missing.

Observation / violated invariant: **KNOWN** — pinned MAME 0.289 reaches a visible 320x224
no-credit attract/demo screen by frame 180; it is not a full-frame black output.

Evidence classification: **KNOWN**, MAME MCP preflight and two independent headless cold runs.
The complete manifest, scripts, logs, PNGs, state and hashes are in
`artifacts/mame-mcp/ga2/attract-20260815/manifest.json`. MAME executable SHA-256 is
`AF6966108D9B52C22465C6D50F4E5D50CC371B50F2D27DC443935F287AAD37A3`; external merged `ga2.zip`
SHA-256 is `C2B3F542369CA2B3B63EF6A4F66D7E8DF8FE8AE73907671041176E1DC850F575`.

Competing hypotheses + falsification tests: black MAME output versus capture/backend failure
versus a real emulation failure. The two clean `-video none -sound none -nothrottle` runs produced
byte-identical PNGs at frames 60, 120 and 180, falsifying nondeterministic MAME output and the
full-frame-black hypothesis for the pinned reference.

Selected earliest-causal explanation: not applicable; no RTL change selected. The MAME-only
reference artifact is bound to cold boot, no inputs, frame 180, 320x224, main V60 PC
`0x0013350B`; it is not a completed differential golden.

MAME MCP preflight/session status: ping PASS; config_check PASS; `ga2` ROM audit PASS; get_ioports
PASS; persistent session PASS; reference untainted.

Checkpoint used / issue checkpoint saved: no prior checkpoint. A supplementary live MAME state was
saved as `checkpoint/states/ga2/ga2-attract-menu-2772.sta`; use the exact frame-180 PNG as the
comparison reference because MAME's external frame counter is not restored by the MCP state load.

MAME-only targeted test: PASS — frame 60/120/180 PNG bytes identical across both clean runs.
Verilator receipt: MISSING. Comparator receipt: MISSING. Regressions: N/A — no RTL change. No
final RBF was built.

Known unknowns / next action: Verilator has not yet been driven to the same frame-180 barrier; the
next step is to compare its native 320x224 attract output and earliest liveness/state boundary
against this pinned golden.

## Iteration 2026-08-22 — framebuffer regression false failure resolved

Scenario: OutRunners width-control continuation plus focused `s32_fb_if` DDR protocol tests.

Observation: **KNOWN** — `tb_fb_if` reported seven failures beginning at the sparse-run check,
while a cycle monitor showed the two supposedly missing writes committing after the bench had
already sampled its counters and memory.

Evidence: at the `wr_end` edge, the bench's combinational completion expression briefly observed
`wr_end=0` before the DUT's nonblocking `pending` update became visible. It returned with zero
accepted writes; the requests then remained stable under DDR backpressure and committed normally.
The same two-cycle false completion reproduced independently in `tb_fb_if_throughput` for dense,
sparse, segmented and shadow runs. This falsified RTL request loss and selected a testbench
scheduling race as the first causal producer.

Smallest change: test-only edits to `verif/common/tb_fb_if.sv` and
`verif/common/tb_fb_if_throughput.sv`. Each run now crosses one full clock after deasserting
`wr_end` before testing the completion state. Both benches also connect `wr_can_start` and tie off
the unused second read lane explicitly. No synthesizable RTL, state, width, latency, clock, reset,
CDC, memory geometry, bus lane, constraint or generated file changed.

Verification: Icarus `FB IF PASS`; Icarus `FB THROUGHPUT PASS` with dense=128 writes,
sparse=2 writes, sparse-shadow=2 reads/2 writes; strict headless Verilator 5.050 with assertions
and `--threads 1` passed both benches with the same counts. Video-mode and split-screen composer
tests passed. A fresh full-project real-ROM OutRunners two-frame cold replay ended `ROMBOOT DONE`
and `GA2 DDR QUALIFICATION PASS`.

Paired evidence: MAME 0.289 executable SHA-256
`AF6966108D9B52C22465C6D50F4E5D50CC371B50F2D27DC443935F287AAD37A3`; ROM audit PASS. Two
clean MAME frame-300 captures were byte-identical (trace SHA-256
`0231A64A90AC3D440579981A9D6AD975CE591550941B3C6838155728AD57497F`) and observed
`r1ff00=0800`, width 320. Comparator receipt
`tmp/orunners-fbif-resolution/comparator-width.json` is admissible `MATCH`, prefix 2, SHA-256
`71F8005AB1CEA7EAC09135564D69B99063CCD78AA9058D6E005947A6ED279405`.

Completion: the seven-failure framebuffer blocker was a bench artifact and is closed. The packed
line-RAM RTL was not changed. Hardware confirmation of the separate forced-416 visual correction
still requires a fresh timing-clean RBF and MiSTer recording; no RBF was built in this iteration.

## Iteration 2026-08-23 — OutRunners MultiPCM output scale

Observation: **KNOWN** — two clean MAME 0.289 gameplay captures with sustained accelerator input
were deterministic, and raw MultiPCM slot 29 carried the engine sample, pitch, TL and LFO writes.
A focused headless Verilator replay measured the engine boundary at reference peak 4843 versus RTL
peak 1210, an exact 4:1 mismatch.

Evidence: MAME `gew.cpp` applies the Q12 envelope with `>>10` and then a pan/level table containing
`/4`, so those factors cancel before its final clamp. The RTL applied its normalized envelope and
also shifted the completed accumulator by two, retaining an extra quarter-scale attenuation. The
MAME System 32 route gains (MultiPCM 0.35, YM 0.15) already match `s32_audio_mix.sv` and were not
changed. The conclusion is **KNOWN** relative to the pinned MAME digital sound contract and
**INFERRED** relative to unmeasured PCB analog output.

Smallest change: remove only the final `>>>2` from both `s32_multipcm` output clamps. No register,
voice, route, FM/skid, clock, reset, CDC, memory, state or latency behavior changed. The focused
regression replays the captured engine slot/sample/TL/pitch/LFO shape and requires the emitted peak
to equal the pre-clamp reference accumulator.

Known unknown: PCB analog gain still requires hardware listening. No RBF was built in this
iteration.

Verification: strict headless Verilator 5.050 (`--threads 1`, assertions, timing and
`--sched-zero-delay`) reproduced the pre-fix boundary twice at 4843/1210 and the rebuilt result
twice at 4843/4843. Comparator receipt `artifacts/diff/orunners-engine/comparator-before.json`
records the old event-0 divergence; `comparator-after.json` is an admissible MATCH with prefix 1.
Focused MultiPCM, engine voice at ACK 30/100, cadence at 28/8 voices, audio-mixer differential,
sound-bus and both ZROM-cache configurations pass. The broad regression passed through its cold
boots, 50-seed V60 differential, soak, framebuffer, mixer, sprite and CPU tiers, then stopped at a
pre-existing six-assertion V25/MCU ROM-loader mapping failure. The Python suite likewise retains
12 pre-existing QSF/profile-contract failures in the dirty working tree; the three named release
check scripts from the project contract are absent. These unrelated blockers were not modified.

## Iteration 2026-08-23 — MultiPCM pan law and RBF build

Observation: **KNOWN** — the engine level correction closed the 4:1 output-scale mismatch, but
non-center pan codes still used binary RTL shifts instead of the MAME attenuation curve.

Evidence: pinned MAME 0.289 `src/mame/sega/segas32/gew.cpp` computes pan as `pan * (-12 dB) / 4`;
its fixed-point conversion truncates to Q10 gains `1024, 724, 513, 363, 257, 182, 128, 0` for
distances 0..7. The RTL previously used `>>>1/2/3` approximations. This is **KNOWN** for the
pinned digital MAME contract and **INFERRED** for the unmeasured PCB analog path.

Smallest change: replace only the `s32_multipcm` pan attenuation shifts with a Q10 lookup and
signed multiply. Center pan remains full stereo and pan 8 remains muted; codes 1..7 and 9..15
now use the exact MAME gains. No voice envelope, sample fetch, route, FM/YM, skid, clock, reset,
CDC, state or latency behavior changed.

Verification: strict headless Verilator 5.050 (`--threads 1`, assertions, timing,
`--sched-zero-delay`) and Icarus exhaustively passed 32 pan cases (positive/negative samples,
both channels). The corrected engine boundary still passes twice at reference/RTL peak 4843/4843.
Existing MultiPCM, mixer, sound-bus, ZROM-cache and cadence tests pass.

RBF build: Quartus Prime 17.0.2 Build 602, project/revision `Arcade-SegaSystem32Multi`, top
`sys_top`, device `5CSEBA6U23I7`, seed 4. The clean full compile, fit and assembler completed
and produced `output_files/Arcade-SegaSystem32Multi.rbf` (4,593,448 bytes, SHA-256
`49597E7B6BD4EE06BF727511557DDB263EE349A2A466A8A68604D366DD54E77E`). STA is not
acceptance-clean: seed 4 has setup WNS -0.195 ns (hold +0.247 ns). Bounded seed experiments
were recorded: seed 3 worsened setup to -0.364 ns; seed 2 improved setup to +0.258 ns but
introduced hold -0.463 ns. Seed 4 is restored in the QSF and the fresh seed-4 RBF is preserved;
no clock, SDC, false-path, or unrelated video workaround was applied. The RBF was not promoted
over the existing dated release because the hard timing gate remains open.

Known unknowns: PCB analog level and real MiSTer audio still require hardware listening; no
hardware load was performed. The next timing action is a causal ascal/HDMI congestion repair,
not an audio change.
