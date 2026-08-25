# Sega System 32 global profile contract

This is the persistent cross-chat routing record for the core.

## 2026-08-26: Multi 32 Title Fight background clip-mode correction

Observation: Title Fight's audience/background is absent in both the core and
MAME, while the flat backdrop and foreground remain. A clean MAME 0.289
frame-650 capture records `r1ff02=0x2960`, `r1ff04=0xd815`,
`r1ff06=0x8424`, `r1ff8e=0x0c00`; direct video-RAM lane reads show all selected
clip rectangles are `[0,0,319,223]`.

Evidence: The attached PCB frames show the audience. The strict headless
Verilator probe using that state produced 320 NBG0 and 320 NBG2 line-buffer
writes with zero opacity; clearing only `$1FF02` bits 11 and 13 produced 320
opaque pixels in both layers. MAME's current source labels those bits as page
wrapping disable with clipping as an unresolved interpretation. The independent
MAME2003-plus video path suppresses clipping for the observed Multi 32 mode
values `0x7be0`, `0x52a0`, `0x2960`, `0x5be0`, and `0x3be0`, with parity rules
for the last two.

Selected explanation: **INFERRED** — `rtl/video/s32_tilemap.sv` was treating
the Multi 32 page-wrap mode as a full-screen clip enable, so clip-out erased
NBG0/NBG2 before the mixer. The fix is register-driven and universal; it does
not add a Title Fight macro or a second production profile.

Verification and scope: The focused captured-state probe is the first gate;
the pre-fix result is retained in `tmp/codex-titlef-clip` and the post-fix
probe shows both background layers opaque in the captured line-160 media case.
The same probe shows NBG2 visible on transparent NBG0 lines 64 and 112. The
tilemap regression passed; universal profile/release-routing checks retain
unrelated pre-existing failures, and the full-core cold-boot build is blocked
by a stale `clk_v25` testbench pin. No Quartus/RBF build is part of this
iteration.

Known unknowns: No direct PCB register trace or schematic for this exact
clip/page-wrap assignment is available in the workspace, so full hardware
acceptance remains pending. The linked Shorts capture was inaccessible because
YouTube returned HTTP 403; the attached PCB frames are the visual hardware
evidence used here.

## 2026-08-25: Hard Dunk action-button metadata

The shipped Hard Dunk descriptors had regressed to two named actions and
`count="2"` in commit `ff7aa13`, even though the RTL still maps `j[4]..j[7]`
to the MAME low-nibble button inputs. The pinned MAME `harddunk` definition
(`reference/ga2-cycle-accuracy/07_emulator_sources/mame_current/src/mame/sega/segas32.cpp`,
lines 1770-1838) confirms the unchanged BUTTON1..BUTTON4 transport.

The first three-button metadata correction used a 36-character third label.
Main_MiSTer commit `0a8fb44ccec6d69c8b7f158abd5fe8065ab2bf4f`
stores each label in `joy_bnames[][32]` and parses comma fields with the
unbounded `substrcpy`, so that label required 37 bytes and crossed the slot
boundary. The arcade MRA loader consumes `names` and `default` but ignores the
`count` attribute; changing `count` alone never repaired the mapping contract.

The smallest correction remains descriptor-only: expose A/B/X as `Pass /
Steal`, `Shoot / Block`, and the prompt-safe `Special/Turbo/Screen`, with
`count="3"` retained as metadata. The first short-label edit accidentally used
only three `-` placeholders after the actions, shifting Start/Coin/Test/Service
from the RTL contract at joystick bits 11/12/13/14 down to 10/11/12/13. The
hardware symptom matched exactly: Test (bit 12) inserted a coin while the Coin
label drove Start (bit 11). Restoring the fourth placeholder fixes the first
causal producer without touching RTL.

Both World/Japan descriptors now parse with the expected names/count/default,
all labels fit the 23-character prompt budget, the system controls resolve to
bits 11/12/13/14, and the five focused Multi 32 control tests pass. The broader
generator/ROM-set suites retain unrelated pre-existing failures from obsolete
one-parent/clone expectations; no failure references this change. Physical
assignment on MiSTer remains the final acceptance step; no RBF rebuild is
required for an MRA-only correction.

MAME and independent arcade references still describe a fourth low-nibble
button bit; it remains available in the RTL transport but is intentionally not
named in this three-action UI until physical/gameplay evidence identifies its
required public function.

## 2026-08-24: descriptor-selected Multi 32 game support

The universal production profile now routes the common Sega System Multi 32
hardware to the supported OutRunners (`orunners`), Title Fight (`titlef`),
Hard Dunk (`harddunk`), and Stadium Cross (`scross`) parents and their emitted
regional clones. All use `Arcade-SegaSystem32Multi`; no per-game Quartus
revision or synthesis macro was added. Stadium Cross `scrossa` (linkable mode)
remains intentionally excluded.

Title Fight uses the existing dual I/O lanes for its four stick directions.
Hard Dunk enables the descriptor-gated mode-0 8255A at `0xc00060` and routes
players 3/6 through its A/B/C inputs. Stadium Cross selects its reversed
P1/P2 steering ADC channels, pedals, three-button control ports, and shared
three-bit MultiPCM bank write. The descriptor carries the title selector in
byte 4 bits 4:2; common video, RAM, clocks, and ROM layout remain unchanged.

Focused Icarus checks pass for the universal core, Hard Dunk PPI, Stadium
Cross sound-bank behavior, and MRA descriptor routing. Sequential Quartus
17.0.2 Analysis & Synthesis and Fitter runs passed for each title iteration;
the final Stadium Cross fit (`20260824-043006-450-fit`) reports 41,078/41,910
ALMs, 550/553 RAM blocks, 59 DSP blocks, and zero fitter errors. Physical
MiSTer input/gameplay verification and a post-change assembled RBF remain
pending for a separately authorized release build.

## 2026-08-23: independent P1/P2 paddle and spinner steering

The OutRunners top previously exposed P1/P2 signed analog-stick steering but
left MiSTer's dedicated absolute `paddle_0/1` and relative `spinner_0/1`
interfaces disconnected. The existing MSM6253 board and cockpit channel map
were already correct: P1 steering reaches channel 0 and P2 steering channel 3.

Each cockpit now has an independent OSD steering source: Analog Wheel (the
bit-identical default path), Paddle, Spinner, or Spinner Reverse. Paddle values
feed the ADC coordinate directly. Spinner toggle events accumulate their full
signed `-128..+127` deltas into a reset-centred, saturating `0x00..0xff`
virtual wheel so endpoint motion cannot wrap to the opposite lock. D-pad
left/right remain full-lock overrides, and pedal mapping is unchanged.

The focused driving-controls bench proves the original 255-coordinate analog
sweep, paddle center/endpoints, both spinner polarities including `-128`,
saturation, reset centering, reverse mode, digital priority, and P1/P2
independence. No framework, ADC serialization, clock, CDC, memory, raster,
audio, constraint, or generated-artifact change is part of this input adapter.
Physical MiSTer testing remains required to validate device enumeration,
preferred direction, and steering feel; no RBF was built in this iteration.

## 2026-08-22: Multi 32 service controls are per-screen

Observation: physical Test/Service inputs were ORed across `joystick_0` and
`joystick_1`, so either cockpit could assert both screens' service ports.

Evidence: `Arcade-SegaSystem32Multi.sv` previously drove both
`SERVICE12/SERVICE34` pairs from shared `test_btn`/`svc_btn` signals. The
pinned MAME `multi32_generic` definition in
`reference/ga2-cycle-accuracy/07_emulator_sources/mame_current/src/mame/sega/segas32.cpp`
defines independent `SERVICE12_A` and `SERVICE12_B` service-mode fields and
independent `SERVICE34_A`/`SERVICE34_B` push switches (lines 1411--1438).

Selected explanation: the shared top-level OR was the first causal producer of
the coupling. The smallest fix derives A's physical Test/Service pair from
`joystick_0` and B's pair from `joystick_1`; the OSD Service Mode bit remains a
deliberate global override. Coin/start lane mapping is unchanged.

Verification: `GlobalProfileContractTests.test_multi32_service_controls_are_local_to_each_screen`
passes and guards the four local mappings plus the absence of the old ORs.
The broader Python suite still has its pre-existing profile/build-contract
failures; no Quartus build or hardware run was performed for this input-only
change.

## 2026-08-18: generic JTFRAME lightgun layer for Alien 3 and Jurassic Park

The universal `Arcade-SegaSystem32` profile now instantiates a project-owned
generic MiSTer/JTFRAME-compatible positional-gun adapter for every descriptor
with `gun_aim` (currently Alien3 and Jurassic Park).  It accepts the signed
MiSTer analog axes, the HPS PS/2 relative-mouse packet and JTFRAME-ordered d-pad
events, scales to the native 320/416 x 224 raster, clamps relative motion, and
feeds the existing MSM6253 ADC channels.  P1 receives the shared PS/2 stream;
P2 retains analog/d-pad support because MiSTer exposes one mouse packet path.

The core-side RGB-only overlay preserves CE/HS/VS/DE and reproduces the
JTFRAME 8x8 crosshair footprint.  status[8] follows the JTFRAME Sinden-border
convention; status[34] enables the crosshair. Jurassic Park's existing status[31:30]/[33:32]
GunCon 2 SNAC selection remains a separate, descriptor-gated source override;
Alien3's `coin_swap` gate still keeps SNAC inactive.  No `sys/`, PLL, SDC,
MRA, descriptor, or generated artifact changed.

Evidence and provenance are pinned in `verif/donors/README.md`: JTCORES
`c990f843c7bd8eaf26179a0632bac1436cc05b52` and jlrh/taito-fpga
`405a68eac741918e627cda563cc1a0c219ed18fd` were inspected for interface
semantics only; no donor RTL was copied.  Focused `tb_lightgun`,
`tb_lightgun_overlay`, and the existing `tb_guncon_snac` pass under Icarus.
The Python profile suite retains its pre-existing release-staging failures
(missing historical MRAs); full native Verilator/core and physical MiSTer
lightgun acceptance remain pending. The exact physical Sinden border geometry is known platform/presentation
unknowns rather than silently compensated in RTL.

## 2026-08-25: MiSTer NVRAM upload read latency fixed

The saved-NVRAM failure was a transport-boundary defect, not Title Fight
service-menu state. The real wide HPS transaction captures `ioctl_din` on the
same `clk_sys` edge that advances `ioctl_addr` by two; the EEPROM's registered
port-B address therefore returned the previous 16-bit word after the first
word. A non-symmetric 64-word round-trip reproduced `3100, 3100, 3228, 3350`;
an erased image hid the defect because every word was `0xffff`.

The index-3 upload path now reads a coherent 64x16 logic shadow updated by the
same write enable/data used by loader, bulk erase/write, and serial writes.
The serial engine keeps its existing block-RAM port-A latency and physical
inversion. The shadow depth is the proven 93C46 x16 organization, not a CPU
decode-window allocation. The fix does not alter the MRA, byte ordering,
profile routing, reset behavior, or vendored HPS framework.

Evidence: the focused storage-backed HPS upload test passes all 64 words;
the EEPROM persistence and wide loader tests pass; universal and standard
profile lint and boot smoke pass. The required ModelSim regression is pending
because this checkout has no `vlog.exe`/`vsim.exe`; no final RBF was built and
physical MiSTer acceptance remains required.

## 2026-08-17: Alien 3 aiming fixed at the EEPROM producer

Real-ROM tracing proved the MiSTer analog byte reached Alien 3's MSM6253 and
V60 read loop unchanged. The game then applied its own calibrated coordinate
formula, `(2*raw-max-min)*160/(max-min)`, using fallback X bounds `0x7f..0x81`.
That two-count span converted one stick count into approximately 160 pixels;
the disappearing crosshair was therefore an off-screen coordinate, not a
sprite, texture, flicker-blend, GunCon, deadzone, or host-axis sensitivity bug.

The first causal failure was the shared 93C46 path. System 32 software uses
sequential READ while CS remains asserted, but the RTL stopped after one word
and returned pull-ups. In addition, factory index 2 had been conflated with
persisted index 3: raw factory x16 cells are big-endian, while index-3 NVRAM is
the core's internal-word stream. The EEPROM now streams and wraps through all
64 words; factory index 2 alone swaps each cell into serial-word order, while
index 3 remains byte-for-byte round-trip compatible.

The pre-fix Alien 3 receipt read `0xffff`, selected the ROM fallback, and
reported `min=0x7f max=0x81 span=2`. The rebuilt strict Verilator replay read
factory header word `0x3353`, did not execute the fallback write, and reported
`min=0x00 max=0xff span=255`; raw `0x81` then produced a 1--2-pixel result.
Directed narrow/WIDE loader tests distinguish index 2 from index 3, and the
EEPROM test now proves two-word streaming. No ADC scaling, renderer, raster,
clock, reset, CDC, SDC, PLL, audio, GunCon, MRA, or framework behavior changed.
Physical MiSTer gameplay remains the final hardware acceptance gate.

## 2026-08-17: Alien 3 GunCon support removed

MiSTer hardware testing continued to show unusably high Alien 3 analog-stick
sensitivity after the title-specific conditioner was removed. At user
direction, GunCon SNAC is no longer an Alien 3 capability. The existing
`coin_swap` descriptor bit identifies Alien 3's distinct gun-cabinet wiring;
the universal top now permits SNAC only when `gun_aim && !coin_swap`, which is
the Jurassic Park route. For Alien 3 this holds both SNAC enables false, keeps
`USER_OUT` idle, prevents packet coordinates from overriding the host axes,
and excludes GunCon buttons and coins. Alien 3 retains only the direct signed
MiSTer analog-stick/USB-lightgun bytes converted to the MSM6253 coordinate.

No ADC serialization, host-axis scaling, framebuffer, raster, clock, reset,
CDC, memory, MRA, SDC, PLL, or framework behavior changes. The profile
contract pins the Jurassic-only gate; focused profile, ADC, GunCon, and cold
game checks cover the affected shared path. Because the former coordinate
override already required explicit SNAC selection plus a valid packet, Alien
3 EEPROM calibration remains an open causal lead if hardware sensitivity does
not change after this removal.

## 2026-08-17: Alien 3 uses Jurassic Park's direct analog mapping

Physical MiSTer testing identified the actual disappearing-sight symptom as an
input-range problem: very small left-stick motion in Alien 3 drove the sight
off-screen, while the same controller had correct sensitivity in Jurassic
Park and worked normally in the service menu.  The first differing producer
was the Alien 3-only `s32_gun_aim` path added by commit `e31647aa`; it inserted
a nonlinear radial response, early endpoint saturation and adaptive filtering.
Jurassic Park instead converted each signed MiSTer host-axis byte directly to
the cabinet ADC coordinate with `axis ^ 8'h80`.

Alien 3 now uses that exact Jurassic Park host-axis mapping for both players
and both axes.  The title-specific conditioner and its focused test are
removed from the production manifest and regression list.  GunCon SNAC remains
an independent calibrated-coordinate override after a valid sample.  The
earlier uncommitted three-field sprite persistence experiment was also removed:
the crosshair was being moved outside the visible coordinate range, not lost
by the renderer.  No framebuffer, raster, ADC serialization, MRA, clock,
reset, CDC, memory, SDC, PLL, framework or pin behavior changes in this fix.

The source contract asserts all four host-axis fallbacks are direct and that
no Alien 3 conditioner remains.  Focused profile, GunCon, ADC and cold game
checks cover the shared route.  A physical MiSTer gameplay pass remains the
final sensitivity and on-screen-crosshair acceptance gate.

## 2026-08-17: additive Alien 3 analog-stick and GunCon input restoration

Post-change MiSTer testing proved that the endpoint-clamp-only correction
recorded below was insufficient: Alien 3's crosshair still disappeared as soon
as an analog stick moved, while the same stick remained usable in Jurassic
Park. Source history identifies the causal regression. Commit `acda56f2`
introduced GunCon by routing the raw MiSTer signed host-axis bytes directly to
the cabinet ADC conversion, replacing the previously passing `s32_gun_aim`
conditioner from commit `05d5f52b`. The GunCon transport is an additional input
source; it must not replace the analog-stick/USB source behavior.

The universal top now restores that exact conditioner for Alien 3's analog-
stick/USB branch. Its radial deadzone, response curve, pulled-in `0x08..0xf8`
endpoints, and error-sensitive settling are retained. Jurassic Park keeps its
already-working direct `0x00..0xff` host-axis mapping. GunCon remains a separate
per-player SNAC branch with its own normalization and overrides only the
selected player after a valid coordinate sample; until then the analog/USB
branch remains active.

The missing OSD choices were independently caused by `P1O...` prefixes without
a declared MiSTer subpage. Both gun-source selectors are now top-level entries;
P2 uses the lowercase `o` status bank required for bits 32 and 33. Focused
regressions execute the restored analog conditioner and the unchanged GunCon
transport, and the profile contract asserts the visible menu syntax and the
two independent mux branches. This supersedes the clamp-only implementation
below. No framebuffer, raster, ADC serialization, clock, reset, CDC, SDC,
memory, Quartus build, or RBF changed. A post-fix MiSTer run of both titles and
both source types remains the hardware acceptance gate.

Evidence identity: pre-change repository HEAD
`3e5d3caaf0b2ed4c4f1b93222d3a747cebd1553a`; GunCon regression commit
`acda56f279f3b31478b9327db553d26447eb2624`; last known working conditioner
commit `05d5f52b080b5d2c90d8cc3397a6af2bf27a27ca`; MAME 0.289 System 32 source
SHA-256 `D5438E3EC1CD5AB1A551041AA4C94E805E02D7B137754055AC0A7A7D46C34A98`.
The final focused receipts are `GUN AIM PASS`, `GUNCON SNAC PASS`, 28/28
profile-contract tests, and zero diagnostics from strict Verilator 5.050 lint
of `s32_gun_aim`. The native ModelSim suite passed full-core profile lint,
integration boot, 50/50 V60 differential seeds, extended soak, and V60 audit
tests before stopping at the pre-existing user-owned Arabian Fight MRA move
(two root MRAs found, three expected). The full Verilator ROM-boot closure
elaborated the new module/harness but could not produce generated C++ because
two fresh `R:` workspaces rejected the same file write; no RTL error preceded
that environment failure.

## 2026-08-17: Alien 3 positional-gun endpoint restoration

MiSTer hardware testing reproduced an Alien 3 cabinet-calibration failure. This
entry is retained as iteration history; the later additive-source restoration
above supersedes its endpoint-clamp-only implementation. A
full analog-stick excursion drove the MSM6253 gun channels to `0x00`/`0xff`,
placing the game's sight beyond its visible border. Jurassic Park remained
correct with that complete range. The earlier measured Alien 3 envelope of
`0x08..0xf8` was lost when the two games were restored onto one direct shared
gun-coordinate path.

The universal top now passes USB/analog-stick gun coordinates through a
descriptor-selected adapter. Jurassic Park remains byte-exact across
`0x00..0xff`; Alien 3 alone saturates each host axis at `0x08` and `0xf8`,
leaving every interior coordinate unchanged. GunCon SNAC bypasses this adapter
because its independent calibration was not part of the hardware observation.
This is a cabinet input-boundary correction, not a
renderer, crop, offset, smoothing, response-curve, or framebuffer workaround.
It adds no state, clock, reset, CDC, memory, latency, or constraint change.

An exhaustive focused regression checks all 256 coordinates on both players
and axes, including the old endpoint fingerprint. The real full-core Alien 3
and Jurassic Park headless replays and paired comparator receipts are retained
with the iteration evidence. No Quartus build or RBF was produced; a post-fix
MiSTer run remains required before claiming physical-hardware validation.

## 2026-08-17: Rad Mobile fast steering-event capture

MiSTer hardware testing established that a rapid left-stick excursion could
leave centre and return before Rad Mobile started its next MSM6253 channel-0
conversion. The former direct positional path then exposed only the final
centre coordinate, so the game never received the intervening steering event.

The universal top now feeds the existing accepted channel-0 load pulse back to
the driving adapter. For `DIGITAL_RADM` only, three 8-bit registers retain the
strongest excursion observed since the previous load and the latest coordinate
that must follow it. This makes a short excursion visible for exactly one ADC
conversion and then delivers the return coordinate, avoiding a new stuck
direction. Rad Rally and Slip Stream retain the direct positional path because
this behavior has only been observed and validated for Rad Mobile.

No clock, CDC, ADC serialization, deadzone, MRA, constraint, framebuffer, or
memory interface changed. The catcher costs 25 state bits and infers no M10K.
A headless focused regression reproduces the old center-to-left-to-center loss,
then checks left, right, strongest-of-several, return-to-centre, exhaustive
coordinate, direct reversal, and pedal behavior. Full universal-profile
Verilator lint and the Python profile/release suite pass. No Quartus build,
RBF, or post-fix MiSTer hardware run was performed in this iteration.

## 2026-08-17: Burning Rival restored to the universal profile

Burning Rival (`brival`, `brivalj`) is restored to the one universal standard-
board profile. MAME's `sega_system32_4p` I/O device is used with Burning Rival's
two-player, six-action-button input contract. The descriptor is `20 00 02` (PPI present,
`PROT_BRIVAL=2`), and the MRA controls are Light/Medium/Heavy Punch followed by
Light/Medium/Heavy Kick and Start/Coin/Test/Service, with defaults
`A,B,X,Y,R,L,Start,Select`. The names follow Sega's original instruction card,
whose upper row is weak/middle/strong punch and lower row is
weak/middle/strong kick; the English labels use the later guide's equivalent
[Light/Medium/Heavy terminology](https://gamefaqs.gamespot.com/arcade/566791-burning-rival/faqs/74783).
The scanned Sega card is preserved by LaunchBox as its
[Burning Rival controls image](https://images.launchbox-app.com/68128e45-e6c9-477e-8645-9685d397fafe.jpg).

The restoration is descriptor-selected RTL: the Burning Rival upper-button PPI
lane, the documented ROM-string protection copy/read trap, and its shared
protected-ROM cache client. No new profile, macro, clock, reset, memory block,
or constraint was added. Focused protection and profile/MRA tests cover this
scope; no Quartus build, RBF, or MiSTer hardware run was performed.

## 2026-08-17: Alien3 and Jurassic Park positional-gun restoration

Alien3: The Gun (`alien3`, `alien3u`, `alien3j`) and Jurassic Park (`jpark`,
`jparkj`, `jparkja`, `jparkjc`) are restored to the one universal standard-board
profile. Their descriptors select the existing MSM6253 ADC plus a direct
positional-gun path: MiSTer USB lightgun analog reports or the optional
GunCon-only SNAC transport adapted from the System11 Point Blank 2 reference
([pinned donor commit](https://github.com/misteraddons/SYSTEM11_MiSTer/commit/c2f2374386c28923d98588d25d509ea075ef9746)).
The adapter stores only a nine-byte response packet in registers and adds no
framebuffer or M10K-backed HUD state.

Alien3 keeps descriptor byte 1 bit 3 for its special SERVICE12 coin layout and
the Trigger/Button MRA assignment. Jurassic Park keeps its distinct one-button
Shoot assignment and the existing MAME compatibility patch at `0xC15A8`. GunCon
B/Cross is an additive coin source in the generic and Alien3 service maps; Alien3
retains its swapped COIN1/COIN2 positions. No Alien3 framebuffer/HUD blending
workaround is present or reintroduced.

This is a source, descriptor, MRA, and focused-regression restoration. No RBF
was built in this iteration and no CRT/lightgun hardware validation is claimed;
the first hardware test should verify SNAC pin polarity, GunCon calibration,
and the USB axis orientation on both titles.

Burning Rival is also present in the current universal descriptor/MRA tables
with its existing PPI/protection path; that pre-existing restoration is kept
separate from the gun transport above.

## 2026-08-17: direct positional driving wheel

Rad Mobile hardware testing reported that continuous left-stick sweeps could
pause at arbitrary intermediate steering positions until the stick moved
again. Rad Mobile, Rad Rally, and Slip Stream use the MSM6253 `ANALOG1` paddle
for steering, and pinned MAME 0.289 defines the same `0x80`-centred,
`0x00..0xff` Paddle for Rad Mobile and Rad Rally. The universal top inserted a
stateful low-rate IIR (`wheel_sm`) between MiSTer's current left-stick X report
and the ADC even though a positional wheel requires the current coordinate.

The established signed-to-offset conversion and centred subtractive deadzone
now feed MSM6253 channel 1 combinationally. The IIR register, divider, update
tick, and their retained intermediate coordinate are removed. This shared
change applies to every `ANALOG_DRIVING` descriptor; ADC serialization, channel
order, pedal mapping, player-port buttons, clocks, resets, and constraints are
unchanged. `tb_driving_controls` sweeps all 255 valid signed stick coordinates,
checks exact monotonic output, reverses directly between intermediate left and
right positions, and requires an immediate return to centre.

## 2026-08-17: Rad Mobile moving-controller response

Rad Mobile's Deluxe cabinet uses the 837-7753 moving controller over the first
315-5296: port G selects shared byte `C000-C010` as address `80-90`, port C is
the bidirectional data bus, and port D bit 4 is the active-low transfer strobe.
The EPR-13686 firmware uses `C008` bit 0 for a main-board request and bit 1 for
the controller response.  The universal core now implements the 315-5296's
per-port output latches/direction behavior and a descriptor-selected stationary,
healthy mailbox responder.  It does not model the Deluxe cabinet's analog motor
plant or energize physical motion.

Rad Mobile descriptor byte 0 is now `48`: bit 3 selects the MSM6253 ADC and bit
6 selects the moving-controller responder.  A guarded headless 40-frame
Verilator replay read `C008=02`, advanced from the old retry boundary at
`0x068236` through success PCs `0x068243` and `0x068251`, and repeated with an
identical normalized mailbox event stream.  The same model with descriptor bit
6 disabled did not reach `0x068243`.  Pinned MAME is retained as a reference-gap
lane because its driver explicitly does not emulate the motor board.

## 2026-08-14: Rad Mobile restored to the supported set

Rad Mobile (`radm`, `radmu`) is a first-class System 32 analog driving board
and is back in the production scope. It was dropped on 2026-08-05 while the
profile was temporarily narrowed to `ga2`+`arabfgt`; the narrowing was
explicitly temporary and the other standard parents have since been returned
one at a time (`holo`, `radr`, `spidman`, `slipstrm`, `darkedge`).

The 2026-08-14 scope restoration itself required no RTL change: the universal profile compiled with
`S32_GAME_ONLY_STD=1` already keeps the descriptor-gated MSM6253 driving ADC,
the shared driving analog defaults, and the `DIGITAL_RADM` player-port layout
in `Arcade-SegaSystem32.sv` (`radm_p1a`, `s32_pkg.sv:DIGITAL_RADM`). MAME's
`init_radm` installs no protection handler or ROM poke.  Its lack of a moving
controller is a known MAME emulation gap addressed by the 2026-08-17 work above.

Descriptor: `48 10 00 81 01` — b0 bit3 = MSM6253 ADC and bit6 = 837-7753
mailbox responder; b1[5:4] = `ANALOG_DRIVING`;
b2 = no protection and no EPR-14084 link; b3 = sprite metadata valid with a
2-bank (`0x800000`) sprite region; byte 4 = `DIGITAL_RADM`.

This restoration is a scope/packaging change. No RBF was built and no hardware
run was performed, so Rad Mobile carries no attract/frame-diff acceptance
evidence yet — see the acceptance matrix below.

## 2026-08-13: four game families removed (historical)

Alien3: The Gun, Burning Rival, Jurassic Park, and SegaSonic The Hedgehog were
temporarily outside the production profile. That scope decision and its
evidence remain historical; the 2026-08-17 entry above restores Alien3 and
Jurassic Park while the current working profile also carries Burning Rival.
SegaSonic remains excluded.

## 2026-08-12: universal-profile memory-budget reduction

System 32 does not load or execute MultiPCM sample ROMs, so the universal
profile now uses that otherwise-empty SDRAM aperture as mutable backing for the
RF5C68's 64 KiB wave RAM. The Z80-visible byte address, WAIT behavior, voice
fetches, writes, and logical `0xff` power-up contents are preserved. Before
releasing the ROM-load reset, the loader clears all 32,768 words in the
aperture; inverted byte storage then makes zero read as logical `0xff`, exactly
like the former internal memory. The SDRAM write port has a held-payload,
owner-tagged serializer with ROM-download priority; RF reads continue through
p4. No RF wave-data M10Ks or validity-map M10Ks remain.

The production-only, non-authoritative EPR-14084 native diagnostic shadow was
also removed from the source manifest and core integration. Rad Rally's
descriptor-selected behavioral link responder remains authoritative and its
MRAs no longer download unused diagnostic firmware planes.

The production protection RTL now contains the Dark Edge sequence, the
descriptor-selected J.League write hook, and the descriptor-selected real V25
path. Dormant and excluded-title responders are not synthesized; reserved
descriptor values resolve to no action.

These changes are estimated to save roughly 64 RAM blocks from RF wave memory,
plus any resources formerly retained by the disabled diagnostic shadow. The
estimate projects the universal design below the 90% RAM-block ceiling, while
the last accepted no-FP standard fit already put ALMs below 90%. No Quartus
map/fit, RBF, Verilator run, or MiSTer hardware validation has been performed;
the exact universal percentages remain unproven until the user authorizes the
FPGA-tool optimization pass.

## 2026-08-12: Air Rescue removed from production scope

Air Rescue requires two complete linked System 32 PCBs. The production core
does not claim that hardware boundary, so `arescue`, `arescueu`, and `arescuej`
are intentionally excluded from `tools/gen_mra.py`, tracked MRAs, releases, and
the supported-game table. The experimental peer-board, dual-V60, dual-PCB RAM,
peer-DDR, and uPD77P25 shadow paths have been removed from production sources
and manifests. This exclusion is a scope decision, not a claim that a
single-board mailbox substitute is sufficient.

## 2026-08-11: integrated CPU, memory and renderer throughput package

The universal production profile keeps the PCB V60 clock and every external data/I/O
bus cadence unchanged.  Instruction fetch, work RAM code, data, I/O, interrupts
and protection transactions all use the ordinary hardware-timed bus.

**2026-08-14 update:** the `V60 Fetch: Fast / PCB (Reset)` option described in
this and the 2026-08-10 entry below has been REMOVED, along with the wide
instruction-fetch datapath it selected.  The core always uses the PCB fetch
path.  The OSD entry is gone and `status[29]` is reserved/unused so every later
option keeps its bit assignment.  The entries below are retained as history.

The shared V60 overlaps the execute edge with sequential retirement only for
explicitly allowlisted register-result and no-writeback operations.  Memory,
RMW, iterative, privileged, exception and control-transfer paths retain their
general states.  The MOVW/DBR fixture improved from 2,101 to 1,845 clocks
(-12.2 %) with the same 12 physical reads; an unrolled register stream improved
from 2,370 to 2,114 clocks (-10.8 %) with identical ordered bus payloads.

V60 cache misses now request one aligned four-word p0 transaction instead of
four independent SDRAM transactions.  The transport improved from 52 to 16
`clk_ram` cycles (3.25x) and from four ACT commands to one, while exact
protection reads remain single-word non-bursts.  The production synchronous
cache is 64 lines instead of 32: a measured alternating conflict fixture drops
from eight misses to zero after warm-up.  The previous accepted report shows
this cache class used MLABs rather than M10Ks. The universal profile now returns
the cache to M10K storage to preserve memory-ALM slack; the new inference and
timing remain Quartus-unverified.

The tilemap retains tagged bitmap VRAM words for all lanes and caches exact
NBG0/NBG1 reciprocal results by their complete effective zoom-denominator key.
A 320-pixel 4bpp bitmap line improves from 969 to 490 renderer clocks and a
repeated NBG line from 555 to 493 with identical pixel/hash results.  The sprite
engine uses a guarded same-cache 1:1 continuation that sustains one pixel per
clock; cache boundaries, scaling, clipping and END handling retain the general
fallback, which is regression-run against the same 24-case pixel suite.

The demand-only sound-ROM cache is now four two-way sets with per-set LRU and
single-consumption stretched-ACK handling.  A two-stream conflict fixture drops
from 160 to eight SDRAM requests and from 1,119 to 359 system clocks, while the
LDIR-like demand count remains exactly 33.  Sparse framebuffer flushes skip only
64-bit words whose four-lane valid mask is zero: the normal fixture drops from
128 to two DDR writes, and shadow RMW from 128 reads plus 128 writes to two plus
two.  Dense flush, erase and scanout transaction counts are unchanged.

Focused Icarus/ModelSim equivalence, fallback, contention, backpressure and
profile-boot tests pass, as do 126 Python tests and all three release/MRA gates.
No Quartus build, RBF, STA or MiSTer hardware verification covers this package
yet; the previously built RBF predates these RTL changes.

## 2026-08-11: direct retained-loop DBcc/TB restore

The shared V60 now restores a complete retained fetch window directly from the
DBcc/TB decode edge when the taken branch target exactly matches the saved
window, the PFU is idle, and the target instruction's conservative predecode
length is present. Unknown target forms retain the ordinary `S_FILL` path;
there is no cross-instruction register speculation, no change to physical PCB
bus acceptance or cadence, and no change to non-loop branches. The 256-iteration
immediate-MOVW/DBR fixture improved from 2,609 to 2,101 `clk_sys` cycles
(-19.5%) with the same 12 physical fetch reads. The focused burst fixture
reported 36,225 cycles for its overlap-A case before that title-specific
fixture was retired.

## 2026-08-10: V60 throughput improvements

The universal production profile compiles the existing 8-byte ROM-cache instruction
port and exposed `V60 Fetch: Fast / PCB (Reset)`.  **Superseded 2026-08-14:**
that option and its wide instruction-fetch datapath have been removed; every
instruction prefetch now uses the shared, ce-gated 16-bit V60 adapter, the same
path the `PCB` setting selected.  Data, I/O, interrupt, video, audio and
protection traffic retain their PCB clocks and bus ordering, as they always
did.

The shared V60 now launches common displacement/register-indirect source reads,
destination reads and result writes as soon as their addresses/data are ready.
This removes serialized EA and request-setup bubbles while leaving acceptance,
completion and request re-arm on the unchanged physical bus. Standard MUL/MULU
uses an exact two-bit radix-4 step (16 iterations instead of 32); DIV/REM remain
unchanged because their existing latency is already at or faster than the
published V60 reference. Sequential fallback remains for complex modes.

The follow-up safe throughput package adds a registered exact-length successor
predecoder for common F2 and short instruction forms, retires resolved simple,
indexed, auto-update and deferred-address EAs directly from their producer
state, and uses a DBcc/TB hint to fill the existing retained-loop window to its
complete 24-byte capacity without increasing ordinary lookahead traffic. The
timing-sensitive live-window shift remains capped at four bytes;
there is no cross-instruction register-value speculation or external-bus timing
change. The 256-iteration loop fixture improved from 2,865 to 2,609 clocks and
from 14 to 12 physical fetch reads.

## 2026-08-10: restore busy-scene sprite throughput and completed ownership

System 32's cached-pixel path is again the algebraically identical two-stage
`R_PIXEL` -> `R_EMIT` pipeline.  A timing-oriented change had inserted
`R_PIXEL_DATA` between them, charging every ordinary destination pixel three
renderer clocks instead of two.  That 50% increase in pixel-stage work is
load-dependent: quiet scenes remain inside a field, while dense object lists
miss publication fields and make the entire sprite layer advance in steps.
Cache misses, sprite-RAM reads, skipped-word END scans, zoom, clipping,
priority and transparency retain their existing general paths and semantics.
The focused regression includes a cached-pixel cycle budget so the extra
per-pixel state cannot return silently.

Scanout also uses a completed physical sprite-framebuffer selector separate
from the CPU-visible logical A/B controller bit.  The renderer erases and draws
into a hidden work buffer, waits for the final framebuffer flush, marks it ready
at `R_DONE`, and publishes it at VBLANK start.  A third physical slot absorbs a
remaining overrun without erasing, rendering into, or exposing the scanned
buffer. Both corrections are part of the universal production profile and are
not game-gated.

Hardware recordings from Jurassic Park and Rad Rally showed the causal shape:
quiet/short sprite lists were smooth, while all trees, roadside objects, cars
and dinosaurs in dense scenes stepped together.  Road/tile scanout continued
smoothly, isolating the sprite renderer's field budget rather than V60 cadence
or one object's transparency.  The overrun regression also requires the third
slot and asserts that scanout cannot change until a complete field is
published.  Quartus/RBF and post-fix MiSTer hardware verification remain
pending.

## 2026-08-12: one universal production profile

The former split revisions are retired. `Arcade-SegaSystem32.qsf` is the only production
Quartus revision and contains the standard-board peripherals together with the
real NEC V25 core/cache/program memories. Descriptor fields select the V25
path for `ga2`/`arabfgt` and the existing HLE or optional I/O/protection paths
for other supported parents. This is a source/routing unification; it is not a
claim that the new combined shape has already been fit or timing-closed.

`rtl/s32_core.sv` is compiled once with the universal shape. `GAME_ONLY_STD`
keeps the descriptor-gated driving ADC, PPI, Dark Edge protection, and real
V25 path while still allowing single-screen resource trimming. Do not name a
macro after a specific game.

## Outputs

- `Arcade-SegaSystem32.rbf` / `Arcade-SegaSystem32.qsf`: every supported parent, including `ga2` and
  `arabfgt` (descriptor-selected real V25).
- No production image supports Multi 32 sets.

## 2026-08-17: Super Visual Football family restored

The universal profile now emits the four supported standard-board football sets
`svf`, `svs`, `jleague`, and `jleagueo`. The non-Rev-A `svfo` clone is
intentionally excluded from production MRAs. All supported sets use the `svf` two-player,
8-way/three-button input layout; the MRA labels are Shoot, Pass-A, and Pass-B.
The two J.League sets select `PROT_JLEAGUE` in descriptor byte 2 because MAME's
`init_jleague` installs the `0x20f700-0x20f705` protection write handler. The
European and Soccer sets retain `PROT_NONE`.

The production RBF remains `Arcade-SegaSystem32.rbf`; this is a descriptor and
shared protection-path extension, not a new Quartus revision or game macro.

## User-requested exclusions (2026-08-03, superseded for Alien3/Jurassic Park)

The original exclusion list covered `alien3`, `arescue`, `brival`, `dbzvrvs`,
`f1en`, `f1lap`, `jpark`, and `sonic`. Later source work supersedes the
`alien3`, `brival`, and `jpark` entries; the remaining parents stay excluded
from MRA generation and the production profile.

## Source of truth

`tools/gen_mra.py:RBF_BY_PARENT` is authoritative for MRA-to-RBF routing and
maps every supported parent to `"Arcade-SegaSystem32"`. `Arcade-SegaSystem32.qsf` is the only
production Quartus revision. `S32_PROFILE_STANDARD`, `S32_UNIVERSAL`,
`S32_V25_HW`, and `S32_GAME_ONLY_STD` define the universal hardware shape.
`S32_PROFILE_V25` and `S32_REAL_V25` must never be defined again. Any macro
named after a specific game (`S32_GA2_ONLY`,
`S32_SONIC_ONLY`, etc.) is a test legacy and must not be used to route a
shipped game. `S32_PCB_TIMING` is a common behavior flag for fixed production
timing and never selects a game or RBF.

## Feature placement (universal profile)

| Feature/change | `Arcade-SegaSystem32` |
|---|---:|---:|
| Shared V60, video, sprite, audio, I/O, loader, and dedicated V60 ROM cache | yes |
| MSM6253 driving ADC, PPI, Dark Edge, and J.League protection | descriptor-driven |
| Alien3/Jurassic Park USB lightgun and GunCon SNAC input | descriptor + OSD mode driven |
| Rad Rally communication HLE | descriptor-driven |
| Real NEC V25 core, program SDRAM, cache, FIFO, internal data RAM | compiled in via `rtl/cpu/v25/v25.qip` (`S32_V25_HW=1`), enabled by `has_v25` |
| V25 table/cadence selection | descriptor-driven (`v25_table`) |
| CPU Turbo | removed (V60 timing relies on fixed CE spacing) |
| V60 Fetch | removed; instruction fetch always uses the PCB bus (`status[29]` reserved) |
| Multi 32 second screen/peripheral hardware | no |
| HDMI shadow-mask post-process | compiled out (`MISTER_DISABLE_SHADOWMASK`) |
| CRT Adjust | not instantiated; native video and 4:3/custom aspect pass directly to the framework |
| Integer scaling | framework `video_freak` target-size calculation retained for Normal, V-Integer, and HV-Integer OSD modes |

The production QSF no longer forces the JT12 shift stores, V25 FIFOs, or V25
EEPROM replicas into MLABs. The V25 internal data-memory byte lanes and the
main-ROM cache explicitly target M10Ks. Sprite-ROM read verification remains
compiled for the universal real-V25 hardware and is enabled only when the
descriptor selects `has_v25 && !v25_table` (GA2, not Arabian Fight or standard
HLE titles).

## Evidence status (2026-08-01)

- 2026-08-12 315-5242 digital-output audit: the pinned SiliconRE M71064
  decap-derived material establishes a pixel-clocked 5-bit RGB output latch,
  blanking, greyscale, and component-nonzero shade/highlight controls. It does
  not establish a mismatch in the upstream System 32 offset/blend/shadow
  arithmetic. Functional video RTL therefore remains unchanged; the directed
  mixer regression now pins offset -> blend -> shadow -> clamp and final
  5-bit-to-8-bit latch expansion. No remaining evidence-backed digital video
  correction was identified; analog DAC levels and exact latch phase remain
  outside the current digital equivalence claim.

- Source/profile checks: passed.
- Python verification on 2026-08-13: 132 tests passed, with one
  environment-only skip; GA2, Arabian Fight, and Holosseum release checks
  passed.
- Native headless regression on 2026-08-13: all 41/41 tiers passed with one
  differential seed, including full-core soak, Dark Edge protection, driving
  I/O, real encrypted V25 firmware, and production SDRAM integration.
- The universal profile includes the V25 path, but no Quartus, Verilator, or
  hardware qualification is claimed for this source-only merge.
- The native full-core romboot model was rebuilt after correcting a
  verification-only bug that applied GA2 sprite/signature assertions to
  standard-profile descriptors. The GA2 predicate now uses the descriptor's
  V25/table boundary; a regression test protects that classification.
- Quartus fit/timing and physical hardware: intentionally not run for this
  profile-routing task.
- The pinned-MAME EPR-14084 link-status HLE is source-integrated for the radr
  descriptor, reuses the existing communication RAM, and passes focused map
  plus byte/wide ROM-loader tests. Full-core radr attract verification now
  passes the screenshot gate at frame 360 in the retained 420-frame run.
- 2026-08-16 direct-CRT timing audit: the production `s32_video.sv` path keeps
  416-mode lines at exactly 3,072 `clk_sys` cycles and 320-mode lines at
  exactly 3,075 cycles, with stable raw HSync pulse widths of 192/240 cycles.
  This preserves the earlier hardware-informed fix for consumer-CRT wobble
  caused by non-repeating NCO line cadence. `tb_video_mode` now measures both
  line periods and pulse-width stability. Focused strict headless Verilator
  validation passed; no Quartus build, RBF, or physical CRT test was run here.

## Current goal acceptance scope (2026-08-02)

The current user-directed gameplay/attract acceptance matrix covers true parent
sets only. Clone and regional revisions and all excluded or Multi 32 parents
are outside this audit. The active parents are `arabfgt`, `darkedge`, `ga2`,
`holo`, `radm`, `radr`, `slipstrm`, and `spidman`. (`radm` was added to
this list on 2026-08-14 when it was restored to the supported set; it has no
attract-gate evidence yet.)

## Universal-profile attract evidence (2026-08-01, in progress)

The acceptance gate for a game is a deterministic full-core Verilator run with
the image's own descriptor, `ROMBOOT DONE`, zero unexpected (non-IRQ) V60
exceptions, no terminal CPU freeze, zero tile/FB overrun counters, and a
retained **Verilator-generated** non-black screenshot that is visually
identifiable as the game's attract/demo state. The screenshot must come from
the same full-core Verilator run that supplies the diagnostics; a MAME
screenshot, MAME-only attract result, or non-attract boot/warning screen never
counts toward progress or promotion. A promoted result also retains a
scene-matched MAME screenshot comparison using the frame-diff ledger in
`docs/debug/frame-diff/journal.md`; comparison may crop only verified black
padding and must state any measured emulator-frame or scanline alignment.

MAME remains the behavioural reference only: its source and captures select
the timing window, inputs, expected landmarks, and hardware behaviour that the
Verilator run must reproduce. MAME evidence is recorded separately and cannot
close the attract gate.

The executable harness gate is `+REQUIRE_VERILATOR_SCREENSHOT` together with
`+DUMPAT=<frame>`: it fails if the requested PPM is absent, incomplete, or
entirely black, and reports the captured frame's non-black pixel count before
`ROMBOOT DONE`.

Current matrix status: the active Standard parents and both V25 parents remain
subject to the combined attract/frame-diff gate. `holo` retains its exact
scene-matched MAME image comparison, but is outside the current audit.

| Parent | Universal descriptor path | Evidence | Status |
|---|---|---|---|
| `holo` | standard | 85 frames; frame 80 shows the FBI anti-drug attract screen; `scratch/vromboot_out/holo_frame80.png`; exact MAME RGB match after documented crop and -1 scanline alignment | proven |
| `radr` | standard | 420-frame full-core Verilator run; frame 360 retained PPM/PNG shows the Rad Rally `Free Play`/SEGA attract screen; `ROMBOOT DONE`, `VERILATOR SCREENSHOT PASS` with 71,680 non-black pixels, IRQ-only vectors 40/41, zero freeze/tile/FB overruns; `scratch/radr_attract_win_20260801p/dump360.ppm` | proven |
| `radm` | standard | 2026-08-17 deterministic motor-mailbox closure: `C008=02`, old `0x068236` retry boundary advances through `0x068243`/`0x068251`; MAME motor-board lane is a documented reference gap; full attract/frame-diff remains pending | partial |
| `ga2` | real V25 | staged parent image and MAME attract references; universal-profile attract/frame-diff gate pending | pending |
| `arabfgt` | real V25 | staged parent image and MAME attract references; universal-profile attract/frame-diff gate pending | pending |
| all other in-scope media-present parents | standard/HLE | staged sweep or media/structural triage exists, but the attract gate is not yet closed | pending |

`ga2` and `arabfgt` are descriptor-selected real-V25 rows in the one universal
profile.

## Per-parent progress (2026-08-01)

The percentage is an evidence milestone, not an estimate of elapsed work:
25% = media staged/structural triage; 50% = rendered Verilator smoke boot with
no unexpected exception or video overrun; 75% = the MAME-selected timing
window was reached in Verilator but the Verilator attract marker, screenshot,
or visual review is still open; 100% = the full Verilator attract gate above is
closed. Only 100% counts as proven attract mode.

| Parent | Attract proven? | Progress | Current evidence / next gate |
|---|---:|---:|---|
| `holo` | no | historical attract capture retained; reactivated in the standard profile | rerun the combined attract/frame-diff gate |
| `ga2` | no | 50% | staged V25 parent image; real-V25 attract and MAME frame-diff gate pending |
| `arabfgt` | no | 50% | staged V25 parent image; real-V25 attract and MAME frame-diff gate pending |
| `radr` | no | not MAME-exact | **2026-08-05 pixel-exact MAME comparison** (`docs/radm-radr-bringup.md`) supersedes the "100%/screenshot-gate" verdict below, which also predates any MAME frame comparison. Frames 60-240 match MAME closely (0.67% differing, stable residual — static title/logo screen); from frame 300 onward the RTL diverges from MAME with no nearby-frame rescue (a genuine content divergence, not timing drift), recovering briefly at frame 480 then diverging again from 600 through 1740. Not yet root-caused. Historical context retained below since it reflects real, still-true findings (screenshot gate, IRQ vectors, zero overruns) — it just isn't evidence of MAME-exactness. 420-frame full-core Verilator attract run passed; retained frame-360 Rad Rally capture, `ROMBOOT DONE`, screenshot gate, IRQ-only vectors 40/41, and zero freeze/tile/FB overruns; MAME-derived CN/FG plus EPR-14084 link-status HLE remains descriptor-routed and focused-tested |
| `slipstrm` | no | Strict Verilator road continuation verified through RTL frame 4500 | **2026-08-09/11 deep trace** (`docs/slipstrm-bringup.md`): fixed a shared V60 RSR return that popped the correct PC but retained the CHLVL handler's stale prefetch window, then proved and fixed an MSM6253 bus-integration error that shifted neutral wheel `0x80` before the read mux sampled D7 (the game stored `0x00` and selected Time Trial instead of MAME's World Championship). Corrected RTL selects World Championship; scene-aligned car selection differs by 192/93,184 pixels (0.2065%) after the known one-pixel horizontal offset. An assertion-clean savable replay reached the post-stadium scene at RTL frame 4500; its forest edge, apron, road-to-horizon geometry, signs, and marshal align with pinned MAME frame 3600, so no draw-distance truncation was reproduced. Exact speed/frame alignment still requires MAME's pre-race HIGH-gear input state. |
| `spidman` | no | reactivated in the standard profile; current gate not rerun | run the Spider-Man attract gate |

MAME-only timing leads are retained for deterministic run planning of supported
parents. Spider-Man uses the 1200-frame title window; these windows replace old
short smoke assumptions when a parent is promoted through the full-core gate.

An earlier local MAME 0.285 `-validate` sweep returned zero for the previously
routed Standard parents, but that command does not prove that the ROM files are
available. A follow-up `-verifyroms radr` and runtime attempt on 2026-08-01
reported `romset "radr" not found` in `D:\Arcade\AI\mame\roms`; therefore no
MAME runtime/media audit is claimed here. The staged `roms/sim` images remain
the current Verilator media baseline, and this does not promote the RTL
attract gate.

## Future-chat checklist

Before editing:

1. Identify whether the change is common RTL, standard-only resource pruning,
   or real-V25-only resource/protection logic.
2. Keep common behavior in shared RTL; the one universal QSF contains both
   standard-board and V25 hardware.
3. Update `tools/gen_mra.py` if a set or parent changes; never hand-edit an
   MRA's `<rbf>`.
4. Run the source/profile validation commands in `AGENTS.md`.
5. Only run either build wrapper after explicit user authorization.

The next Rad Mobile acceptance run uses the repository adapter, which allocates
a unique `R:\Verilator` workspace and routes both build and simulation through
the installed safe launchers:

```bash
bash verif/verilator/run_romboot.sh radm 660 \
  +DUMPAT=600 +DUMPN=1 +REQUIRE_VERILATOR_SCREENSHOT +QUIET
```

## 2026-08-25: Hard Dunk buttons and Multi 32 video-output contract

Hard Dunk's World and Japan MRAs now expose the three cabinet action inputs as
`Pass / Steal`, `Shoot / Block`, and `Special Move / Turbo / Screen Toggle`,
with `count="3"`, `A,B,X` defaults, and exactly three placeholder slots before
Start/Coin/Test/Service. The previous descriptors declared three labels but
four placeholders while still using a two-button shape; MiSTer input assignment
stopped at the third action. The focused MRA/parser and generator-fidelity tests
pass.

The analog report had a direct project cause: the production QSF defined
`MISTER_DISABLE_YC=1`, compiling out the framework `yc_out` encoder and forcing
the analog connector to RGB, which cannot produce chroma on a SuperStation Y/C
split. That macro is removed; `sys/sys.qip` already includes `yc_out.sv`, and
PAL/NTSC phase, burst range, and Y/C enable remain host-configured through the
framework command path. The HDMI integration also widens the vendored scaler
input bound from `IHRES=512` to `1024`, covering the split compositor's 832-pixel
active / 1024-pixel total 416-mode raster.

The split compositor regression now checks 20 lines in each 416- and 320-mode,
including a frame-boundary mode transition, exact A/B stream order, seam width,
native line periods (3072/3075 `clk_sys` ticks), and HSync widths (192/240
ticks). Icarus passes this focused check. The 2026-08-24 RBF has not been
rebuilt from these changes and no physical MiSTer HDMI, S-Video, or CRT test was
run; final hardware acceptance remains pending. The full legacy Python profile
suite still has pre-existing trimmed-repository failures for old
`S32_OUTRUNNERS`/`S32_SYSTEM32_ONLY` expectations.
