"""Prevent future chats from re-adding non-OutRunners hardware to this repo.

This repository builds one production profile: OutRunners (Sega System
Multi 32, board 837-8676 / 171-6253C). The RTL, QSF and MRA generator no
longer carry the old multi-game "universal profile" machinery (real V25 MCU,
HLE protection selects, positional-gun/lightgun boards, the second YM3438,
per-game descriptor branches). These tests pin that shape so a future chat
cannot silently reintroduce another game's routing, macros or deleted
hardware modules.
"""

from pathlib import Path
from xml.etree import ElementTree
import re
import unittest

from tools.gen_mra import GAMES, RBF_BY_PARENT


ROOT = Path(__file__).parents[1]
MRA_DIR = ROOT / "releases"

OUTRUNNERS_SETS = {"orunners", "orunnersu", "orunnersj"}


class GlobalProfileContractTests(unittest.TestCase):
    def test_single_production_game_is_orunners_only(self) -> None:
        """The MRA generator must route only the OutRunners family.

        A future chat "restoring" another System 32/Multi 32 title only has
        to add a key back to GAMES; this catches that at the source before
        it ever reaches an .mra.
        """
        self.assertEqual(set(GAMES), {"orunners"})
        other_game_keys = {
            "ga2", "arabfgt", "brival", "darkedge", "holo", "alien3",
            "jpark", "radm", "radr", "spidman", "slipstrm", "svf",
            "jleague", "jleagueo", "sonic", "sonicp", "dbzvrvs", "f1en",
            "f1lap", "kokoroj", "kokoroj2",
        }
        self.assertTrue(other_game_keys.isdisjoint(GAMES))
        for path in MRA_DIR.glob("*.mra"):
            root = ElementTree.parse(path).getroot()
            setname = root.findtext("setname", "")
            parent = root.findtext("parent", setname)
            self.assertIn(setname, OUTRUNNERS_SETS, path.name)
            self.assertIn(parent, OUTRUNNERS_SETS, path.name)

    def test_exactly_one_universal_quartus_profile_exists(self) -> None:
        """One QPF/QSF builds the whole core; no per-game project files."""
        for name in ("Arcade-SegaSystem32Multi.qpf", "Arcade-SegaSystem32Multi.qsf"):
            self.assertTrue((ROOT / name).is_file(), name)
        for name in ("segas32v25.qpf", "segas32v25.qsf"):
            self.assertFalse((ROOT / name).exists(), name)
        for obsolete in ("s32", "s32v25", "segas32", "s32GoldenAxe", "s32ArabianFight"):
            self.assertFalse((ROOT / f"{obsolete}.qpf").exists(), obsolete)
            self.assertFalse((ROOT / f"{obsolete}.qsf").exists(), obsolete)

    def test_qsf_sets_outrunners_profile_and_no_legacy_macros(self) -> None:
        """The QSF must select S32_OUTRUNNERS and nothing from the old
        multi-game "universal profile" macro set."""
        qsf = (ROOT / "Arcade-SegaSystem32Multi.qsf").read_text(encoding="utf-8")
        self.assertIn('VERILOG_MACRO "S32_OUTRUNNERS=1"', qsf)
        self.assertIn('VERILOG_MACRO "S32_PCB_TIMING=1"', qsf)
        for macro in (
            "S32_SYSTEM32_ONLY", "S32_PROFILE_STANDARD", "S32_UNIVERSAL",
            "S32_GAME_ONLY_STD", "S32_V25_HW", "S80X86_PSEUDO_286_INT",
        ):
            self.assertNotIn(f'VERILOG_MACRO "{macro}=1"', qsf)
        for macro in ("S32_JT12_MLAB_SHIFTS=1", "S32_V25_MLAB_FIFO=1",
                      "S32_V25_MLAB_EEPROM=1"):
            self.assertNotIn(f'VERILOG_MACRO "{macro}"', qsf)
        self.assertNotIn('VERILOG_MACRO "S32_REAL_V25=1"', qsf)
        self.assertNotIn('VERILOG_MACRO "S32_PROFILE_V25=1"', qsf)
        self.assertNotIn("QIP_FILE rtl/cpu/v25/v25.qip", qsf)
        self.assertIn('VERILOG_MACRO "MISTER_DISABLE_SHADOWMASK=1"', qsf)
        for legacy in ("S32_GA2_ONLY", "S32_GOLDENAXE_ONLY", "S32_ARABFIGHT_ONLY",
                       "S32_V25_GAME_ONLY", "S32_SONIC_ONLY"):
            self.assertNotIn(f'VERILOG_MACRO "{legacy}=1"', qsf)
        # Sources live only in files.qip -- the QSF itself carries no
        # per-game SYSTEMVERILOG_FILE/QIP_FILE line of its own.
        self.assertNotIn("SYSTEMVERILOG_FILE", qsf)
        self.assertIn("source files.qip", qsf)

    def test_deleted_non_outrunners_hardware_paths_are_gone(self) -> None:
        """The V25 MCU, HLE protection, gun/lightgun and dual-FM hardware
        were deleted for OutRunners; catch anyone regenerating those files."""
        for relative in (
            "rtl/cpu/v25",
            "rtl/prot",
            "rtl/io/s32_lightgun.sv",
            "rtl/io/s32_guncon_snac.sv",
            "rtl/video/s32_lightgun_overlay.sv",
            "rtl/audio/s32_rf5c68.sv",
            "rtl/comm/epr14084",
        ):
            self.assertFalse((ROOT / relative).exists(), relative)

    def test_files_qip_has_no_dangling_references(self) -> None:
        """files.qip must not list any of the deleted OutRunners-era files."""
        qip = (ROOT / "files.qip").read_text(encoding="utf-8")
        for needle in (
            "rtl/cpu/v25", "rtl/prot/", "s32_lightgun", "s32_guncon_snac",
            "s32_lightgun_overlay", "s32_rf5c68", "epr14084",
        ):
            self.assertNotIn(needle, qip)

    def test_conf_str_has_no_gun_related_options(self) -> None:
        """P1/P2 Gun Input, Sinden Borders, Gun Crosshair and Gun Sensitivity
        were removed with the lightgun/SNAC hardware -- OutRunners has no
        positional-gun cabinet."""
        text = (ROOT / "Arcade-SegaSystem32Multi.sv").read_text(encoding="utf-8")
        for needle in (
            '"O[8],Sinden Borders,',
            '"O[34],Gun Crosshair,',
            '"O[37:36],Gun Sensitivity,',
            'P1 Gun Input',
            'P2 Gun Input',
        ):
            self.assertNotIn(needle, text)
        self.assertIn("gun_aim          = 1'b0", text)
        self.assertIn("coin_swap        = 1'b0", text)

    def test_multi32_second_screen_option_is_unconditional(self) -> None:
        """The Multi 32 second-screen CONF_STR entry used to be compiled out
        under `` `ifndef S32_SYSTEM32_ONLY ``; that macro no longer exists so
        the option must always be present."""
        text = (ROOT / "Arcade-SegaSystem32Multi.sv").read_text(encoding="utf-8")
        self.assertIn("`ifndef S32_SYSTEM32_ONLY", text)
        self.assertIn('"O[6],Screen (Multi32),A,B;"', text)
        self.assertIn("`ifdef S32_SYSTEM32_ONLY", text)
        self.assertIn("wire [23:0] game_rgb = status[6] ? rgb_b : rgb_a;", text)
        qsf = (ROOT / "Arcade-SegaSystem32Multi.qsf").read_text(encoding="utf-8")
        self.assertNotIn('VERILOG_MACRO "S32_SYSTEM32_ONLY=1"', qsf)

    def test_core_has_no_dangling_removed_hardware_references(self) -> None:
        """s32_i8255, the Rad Mobile motor mailbox, the V25 MCU and the HLE
        protection modules must not be instantiated in s32_core.sv -- only
        historical comments may still name them."""
        core = (ROOT / "rtl/s32_core.sv").read_text(encoding="utf-8")
        for module in (
            "s32_i8255", "s32_radm_motor_mailbox", "s32_v25", "s32_prot_",
        ):
            self.assertIsNone(
                re.search(re.escape(module) + r"\s+\w+\s*\(", core),
                f"{module} instantiation still present in s32_core.sv",
            )

    def test_v60_cadence_fix_is_the_only_v60_bus_shape(self) -> None:
        """The Sonic-era V60 timing fix is still the (only) production
        cadence path -- there is no longer a second profile to keep it
        shared with."""
        core = (ROOT / "rtl/s32_core.sv").read_text(encoding="utf-8")
        files_qip = (ROOT / "files.qip").read_text(encoding="utf-8")
        qsf = (ROOT / "Arcade-SegaSystem32Multi.qsf").read_text(encoding="utf-8")
        self.assertIn("module s32_v60_exec_cadence", core)
        self.assertIn("s32_v60_exec_cadence v60_cadence", core)
        self.assertIn(".ce(v60_exec_ce)", core)
        self.assertIn("s32_v60_bus vbus", core)
        self.assertIn(".clk(clk_sys), .ce(ce_cpu), .rst(rst)", core)
        self.assertIn("SYSTEMVERILOG_FILE rtl/s32_core.sv", files_qip)
        self.assertIn('VERILOG_MACRO "S32_OUTRUNNERS=1"', qsf)

    def test_v60_wide_fetch_is_always_on_with_no_osd_option(self) -> None:
        """The wide instruction-fetch transport is present and hardwired on.

        Its 2026-08-14 removal routed every V60 prefetch through the shared
        ce-gated 16-bit bus, multiplying p0 SDRAM traffic and starving the
        tile renderer's p1 port on its ~10% scanline margin. It is restored
        as a fixed capability: no OSD toggle, status[29] stays reserved,
        fast_v60 tied 1 in the top.
        """
        top = (ROOT / "Arcade-SegaSystem32Multi.sv").read_text(encoding="utf-8")
        core = (ROOT / "rtl/s32_core.sv").read_text(encoding="utf-8")
        cpu = (ROOT / "rtl/cpu/v60/s32_v60.sv").read_text(encoding="utf-8")
        # Hardwired on in the top; no OSD entry, no status-bit consumer.
        self.assertIn(".fast_v60(1'b1)", top)
        self.assertNotIn("O[29],V60 Fetch", top)
        # status[29] survives only in comments, never as a live signal
        # reference (e.g. "status[29:...]" or a bare use in logic).
        self.assertIsNone(re.search(r"status\[29\](?!\s+(is RESERVED|convention))", top))
        # Core and CPU plumbing present, compiled in for production.
        self.assertIn("input             fast_v60", core)
        self.assertIn(".FAST_IFETCH(`FAST_IFETCH_EN)", core)
        self.assertIn(".if_req(if_req)", core)
        self.assertIn("parameter        FAST_IFETCH = 1'b0", cpu)
        self.assertIn("use_fast_ifetch = FAST_IFETCH && fast_ifetch && fetch_is_rom", cpu)
        # status[29] stays allocated so later options keep their meaning.
        self.assertIn("status[29] is RESERVED", top)
        self.assertIn("O[28:27],Scale,Normal,V-Integer,HV-Integer;", top)
        # The surviving PCB prefetch path is unchanged.
        self.assertIn(".clk(clk_sys), .ce(ce_cpu), .rst(rst)", core)
        self.assertIn("reg        seq_pd_valid;", cpu)
        self.assertIn("function automatic [4:0] exact_need_at", cpu)
        self.assertIn("wire [4:0] pf_high = pf_loop_hint ? 5'd24 : 5'd20", cpu)
        self.assertIn("task automatic complete_ea_now", cpu)
        self.assertIn("wire pf_ack = bus_ack && (bus_owner == OWN_PF);", cpu)
        self.assertNotIn("cpu_turbo", top)

    def test_sprite_throughput_and_publication_are_intact(self) -> None:
        """Busy lists keep two-stage pixels and never expose an in-flight
        framebuffer -- this is a shared piece of RTL, not a profile-specific
        one, so it does not depend on any profile macro."""
        core = (ROOT / "rtl/s32_core.sv").read_text(encoding="utf-8")
        sprite = (ROOT / "rtl/video/s32_sprite.sv").read_text(encoding="utf-8")
        self.assertIn(".present(vbl_start), .vblank(vbl_end)", core)
        self.assertIn("fb_rd_buf_r <= spr_scan_buf", core)
        self.assertIn("function automatic [1:0] choose_work_buf", sprite)
        self.assertIn("ready_buf <= work_buf", sprite)
        self.assertIn("scan_buf <= ready_buf", sprite)
        self.assertIn("fb_wr_buf <= is_multi32", sprite)
        self.assertNotIn("R_PIXEL_DATA, R_DONE", sprite)
        self.assertIn("pixel_pen8     <= pixrow", sprite)
        self.assertIn("rs <= R_EMIT", sprite)

    def test_production_osd_has_no_debug_pause_or_aim_override(self) -> None:
        top = (ROOT / "Arcade-SegaSystem32Multi.sv").read_text(encoding="utf-8")
        self.assertNotIn("O[12],Pause", top)
        self.assertNotIn("Analog Aim Invert", top)
        self.assertNotIn("wire pause = status[12]", top)
        self.assertIn(".pause(1'b0)", top)

    def test_every_emitted_mra_routes_to_a_known_profile(self) -> None:
        self.assertEqual(RBF_BY_PARENT, {parent: "Arcade-SegaSystem32Multi" for parent in GAMES})
        seen = set()
        for path in MRA_DIR.glob("*.mra"):
            root = ElementTree.parse(path).getroot()
            parent = root.findtext("parent") or root.findtext("setname")
            if parent not in GAMES:
                continue
            seen.add(parent)
            expected_rbf = RBF_BY_PARENT[parent]
            self.assertEqual(root.findtext("rbf"), expected_rbf, path.name)
        self.assertTrue(seen)
        self.assertTrue(seen <= set(GAMES))

    def test_romboot_ga2_qualification_uses_descriptor_boundary(self) -> None:
        """A protection selector must not classify standard games as GA2.

        This descriptor-bit qualification predates the OutRunners-only
        conversion and no longer selects a shipped game, but it stays as a
        hardware-boundary regression guard for the raw descriptor decode
        used by the simulation harness.
        """
        text = (ROOT / "verif/common/tb_core_romboot.sv").read_text(
            encoding="utf-8")
        self.assertIn("ga2_qualification", text)
        self.assertIn("((b0 & 8'h06) == 8'h02)", text)
        self.assertIn(
            "ga2_qualification, board.has_adc, board.has_ppi",
            text,
        )
        self.assertNotIn("b2 != 1 && frames >= 70 && spr_px == 0", text)

    def test_romboot_attract_gate_requires_verilator_screenshot(self) -> None:
        """Promotion must be backed by a non-black frame from this run."""
        text = (ROOT / "verif/common/tb_core_romboot.sv").read_text(
            encoding="utf-8")
        self.assertIn("REQUIRE_VERILATOR_SCREENSHOT", text)
        self.assertIn("dump_nonblack_seen", text)
        self.assertIn("VERILATOR SCREENSHOT FAIL", text)

    def test_gun_lightgun_hardware_is_absent(self) -> None:
        """Positional-gun, lightgun overlay and GunCon SNAC hardware do not
        exist on OutRunners; catch any future chat re-adding them.

        Inverts the old "positional gun controls are present" contract now
        that the gun cabinet hardware (Alien 3 / Jurassic Park's boards) is
        out of scope for this repository.
        """
        text = (ROOT / "Arcade-SegaSystem32Multi.sv").read_text(encoding="utf-8")
        core = (ROOT / "rtl/s32_core.sv").read_text(encoding="utf-8")
        io = (ROOT / "rtl/io/s32_io.sv").read_text(encoding="utf-8")
        fb_if = (ROOT / "rtl/mem/s32_fb_if.sv").read_text(encoding="utf-8")
        combined = "\n".join((text, core, io, fb_if))
        self.assertNotIn("s32_guncon_snac", combined)
        self.assertIsNone(
            re.search(r"\bs32_lightgun(_overlay)?\s+\w+\s*\(", combined),
            "s32_lightgun/s32_lightgun_overlay instantiation still present",
        )
        self.assertNotIn("gun_adc", combined)
        self.assertNotIn("snac_p1_gun", combined)
        self.assertNotIn("snac_p2_gun", combined)
        self.assertNotIn("host_gun_p1_x", combined)
        self.assertNotIn("alien3_stick", combined)
        self.assertNotIn("alien3_gun_profile", combined)
        self.assertNotIn("alien3_hud_blend", combined)
        self.assertNotIn("rd_blend_buf", combined)
        # gun_aim/coin_swap are hardcoded 0 dead descriptor fields, not
        # removed outright (the board descriptor layout must stay stable),
        # but nothing may drive real behavior from them any more.
        self.assertIn("active_board.gun_aim          = 1'b0;", text)
        self.assertIn("active_board.coin_swap        = 1'b0;", text)
        for removed in (
            "has_track", "PROT_SONIC", "s32_trackball_stick", "s32_upd4701",
        ):
            self.assertNotIn(removed, combined)

    def test_darkedge_brival_protection_stubs_are_hardwired_off(self) -> None:
        """rtl/prot/s32_prot.sv (Dark Edge/Burning Rival HLE protection) was
        deleted. The dead PPI-port wiring that used to be descriptor-selected
        via prot_sel must now be permanently tied off, not still switching on
        a live descriptor field."""
        text = (ROOT / "Arcade-SegaSystem32Multi.sv").read_text(encoding="utf-8")
        self.assertNotIn("prot_sel", text)
        self.assertNotIn("PROT_DARKEDGE", text)
        self.assertNotIn("PROT_BRIVAL", text)
        self.assertIn("wire brival_inputs = 1'b0;", text)
        self.assertIn("wire darkedge_inputs = 1'b0;", text)

    def test_production_video_path_includes_core_side_crt_adjust(self) -> None:
        text = (ROOT / "Arcade-SegaSystem32Multi.sv").read_text(encoding="utf-8")
        files_qip = (ROOT / "files.qip").read_text(encoding="utf-8")
        regression = (ROOT / "verif/run_regression.ps1").read_text(encoding="utf-8")
        shell_regression = (ROOT / "verif/run_regression.sh").read_text(encoding="utf-8")
        self.assertIn('"O[9],CRT Adjust,Off,On;"', text)
        self.assertIn('"H1O[14:10],CRT H-Size,', text)
        self.assertIn('"H1O[21:15],CRT H-Position,', text)
        self.assertIn('"H1O[26:22],CRT V-Shift,', text)
        self.assertIn(".status_menumask({14'd0, ~status[9], 1'b0})", text)
        self.assertIn("crt_adjust #(\n", text)
        self.assertIn("crt_adjust_active", text)
        self.assertIn("crt_hs_ref_rise", text)
        self.assertIn(".vb_in     (core_vb)", text)
        self.assertIn(".AW        (10)", text)
        self.assertIn("crt_hpos_native", text)
        self.assertIn("- 9'sd97", text)
        self.assertIn('"O[28:27],Scale,Normal,V-Integer,HV-Integer;"', text)
        self.assertIn("video_freak s32_video_freak", text)
        self.assertIn("status[28:27]", text)
        self.assertIn("SYSTEMVERILOG_FILE rtl/crt_adjust.sv", files_qip)
        self.assertIn('"rtl/crt_adjust.sv",', regression)
        self.assertIn("rtl/video/*.sv rtl/crt_adjust.sv rtl/audio/", shell_regression)
        self.assertIn("wire hdmi_output_active", text)
        self.assertIn("!hdmi_output_active", text)
        self.assertIn("scandoubler_fx == 3'd0", text)
        self.assertIn("assign CE_PIXEL = crt_adjust_active ? crt_rd_ce : ce_pix_core;", text)
        self.assertIn("assign VGA_HS = crt_adjust_active ? crt_hs : core_hs;", text)
        self.assertIn("assign VGA_VS = crt_adjust_active ? crt_vs : core_vs;", text)

    def test_cache_memory_targets_m10k(self) -> None:
        """The V60 ROM cache still targets M10K block RAM. The V25's own
        M10K pragma pair was deleted along with rtl/cpu/v25/."""
        core = (ROOT / "rtl/s32_core.sv").read_text(encoding="utf-8")
        self.assertIn(
            '(* ramstyle = "M10K, no_rw_check" *) reg [CACHE_WIDTH-1:0] cache_mem',
            core,
        )

    def test_default_regressions_do_not_force_retired_mlab_branches(self) -> None:
        for relative in ("verif/run_regression.ps1", "verif/run_regression.sh"):
            runner = (ROOT / relative).read_text(encoding="utf-8")
            for macro in ("S32_JT12_MLAB_SHIFTS", "S32_V25_MLAB_FIFO",
                          "S32_V25_MLAB_EEPROM"):
                self.assertNotIn(macro, runner, relative)

    def test_driving_pedals_use_right_stick_with_a_b_fallbacks(self) -> None:
        """OutRunners' accelerator/brake are the right-stick Y/X axes with
        digital A/B fallbacks -- fed straight to the ADC now that the old
        gun_aim override ternary (shared with Alien 3/Jurassic Park's gun
        boards) has been removed along with the gun hardware."""
        text = (ROOT / "Arcade-SegaSystem32Multi.sv").read_text(encoding="utf-8")
        controls = (ROOT / "rtl/io/s32_driving_controls.sv").read_text(
            encoding="utf-8")
        self.assertIn(".joystick_r_analog_0(joystick_r_analog_0)", text)
        self.assertIn(".right_y(joystick_r_analog_0[15:8])", text)
        self.assertIn("stick_y < 0", controls)
        self.assertIn("stick_y > 0", controls)
        self.assertIn("digital_accel ? 8'hff", controls)
        self.assertIn("digital_brake ? 8'hff", controls)
        self.assertIn("assign adc_ch[1] = driving_accel;", text)
        self.assertIn("assign adc_ch[2] = driving_brake;", text)
        self.assertNotIn("gun_aim ? gun_adc", text)

    def test_driving_wheel_has_no_stateful_intermediate_position(self) -> None:
        text = (ROOT / "Arcade-SegaSystem32Multi.sv").read_text(encoding="utf-8")
        controls = (ROOT / "rtl/io/s32_driving_controls.sv").read_text(
            encoding="utf-8")
        self.assertIn(".left_x(joystick_l_analog_0[7:0])", text)
        self.assertIn(".right_y(joystick_r_analog_0[15:8])", text)
        self.assertIn("assign adc_ch[0] = driving_wheel;", text)
        self.assertNotIn("gun_aim ? gun_adc", text)
        self.assertIn("wheel_pending_valid", controls)
        self.assertIn("wheel_sample", controls)
        self.assertIn(".adc0_load(adc0_load)", text)
        core = (ROOT / "rtl/s32_core.sv").read_text(encoding="utf-8")
        self.assertIn("assign adc0_load = wr_stb && sel_adc", core)
        self.assertIn("(A[2:1] == 2'd0)", core)
        for stale_state in ("wheel_sm", "wheel_div", "wheel_tick"):
            self.assertNotIn(stale_state, text)

    def test_adc_is_always_present_real_hardware(self) -> None:
        """The 837-7536 MSM6253 A/D board is real OutRunners hardware, not a
        descriptor-gated optional peripheral -- GAME_ONLY_STD is always 1
        under S32_OUTRUNNERS so the "no ADC" arm is permanently dead, but the
        ADC instantiation and its sel_adc decode must stay present."""
        text = (ROOT / "rtl/s32_core.sv").read_text(encoding="utf-8")
        self.assertIn("if (GAME_ONLY && !GAME_ONLY_STD) begin : g_no_adc", text)
        self.assertIn("s32_msm6253 adc (", text)
        self.assertIn(
            "wire sel_adc   = sel_ioex && (A[5:3] == 3'b010) && cfg_has_adc",
            text,
        )
        self.assertIn("`ifdef S32_OUTRUNNERS", text)
        self.assertIn("localparam GAME_ONLY_STD = 1'b1;", text)

    def test_standard_shape_excludes_removed_game_hardware(self) -> None:
        """The Rescue Ambulance DSP, trackball input and Burning Rival's HLE
        protection module were all deleted -- none of them are OutRunners
        hardware."""
        core = (ROOT / "rtl/s32_core.sv").read_text(encoding="utf-8")
        top = (ROOT / "Arcade-SegaSystem32Multi.sv").read_text(encoding="utf-8")
        self.assertNotIn("s32_arescue_dsp dsp (", core)
        for removed in ("trackball",):
            self.assertNotIn(removed, (core + top).lower())
        self.assertNotIn("s32_prot_brival brival (", core)
        self.assertNotIn("s32_prot_", core)


if __name__ == "__main__":
    unittest.main()
