"""Non-Quartus regression tests for the Windows RBF build pipeline.

These tests deliberately use synthetic Quartus summaries and disposable batch
files.  They must never start Quartus, Qsys, SSH, or an FPGA build.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[1]
TOOLS = REPO_ROOT / "tools"
POWERSHELL = shutil.which("pwsh") or shutil.which("powershell")


def run_powershell_file(
    script: Path,
    arguments: Iterable[str] = (),
    *,
    env: dict[str, str] | None = None,
    timeout: int = 30,
) -> subprocess.CompletedProcess[str]:
    """Run a PowerShell helper directly (never a Quartus executable)."""

    if not POWERSHELL:
        raise unittest.SkipTest("PowerShell is not installed")
    command = [
        POWERSHELL,
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script),
        *map(str, arguments),
    ]
    return subprocess.run(
        command,
        cwd=REPO_ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
        check=False,
    )


def decode_json_output(output: str) -> dict[str, object]:
    """Decode a JSON object even if PowerShell emitted a short status prefix."""

    decoder = json.JSONDecoder()
    for offset, character in enumerate(output):
        if character != "{":
            continue
        try:
            value, _ = decoder.raw_decode(output[offset:])
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            return value
    raise AssertionError(f"PowerShell output did not contain JSON:\n{output}")


class SyntheticQuartusProject:
    """Minimal report fixture accepted by tools/report-quartus.ps1."""

    revision = "segas32"
    seed = 2

    def __init__(self) -> None:
        self._temporary = tempfile.TemporaryDirectory(prefix="s32-pipeline-")
        self.root = Path(self._temporary.name)
        self.output = self.root / "output_files"
        self.output.mkdir()
        (self.root / "rtl").mkdir()
        (self.root / "sys").mkdir()
        (self.root / "tools").mkdir()

        self.quartus_root = self.root / "fake-quartus"
        (self.quartus_root / "quartus").mkdir(parents=True)
        self.write(
            self.quartus_root / "quartus" / "version.txt",
            "Version=17.0.2.602\nQuartus Prime Version 17.0.2 Build 602 Lite Edition\n",
        )

        self.write(
            self.root / f"{self.revision}.qpf",
            f'PROJECT_REVISION = "{self.revision}"\n',
        )
        self.write(
            self.root / f"{self.revision}.qsf",
            "set_global_assignment -name FAMILY \"Cyclone V\"\n"
            f"set_global_assignment -name SEED {self.seed}\n"
            "set_global_assignment -name SYSTEMVERILOG_FILE rtl/core.sv\n",
        )
        self.write(self.root / "rtl" / "core.sv", "module core; endmodule\n")
        self.write(self.root / "sys" / "sys_top.sv", "module sys_top; endmodule\n")
        self.write(self.root / "tools" / "make_pll.tcl", "# synthetic input\n")

        now = time.time()
        self.input_stamp = now - 300
        self.map_stamp = now - 240
        self.fit_stamp = now - 180
        self.sta_stamp = now - 120
        self.rbf_stamp = now - 60
        for path in (
            self.root / f"{self.revision}.qpf",
            self.root / f"{self.revision}.qsf",
            self.root / "rtl" / "core.sv",
            self.root / "sys" / "sys_top.sv",
            self.root / "tools" / "make_pll.tcl",
        ):
            os.utime(path, (self.input_stamp, self.input_stamp))

    def close(self) -> None:
        self._temporary.cleanup()

    @staticmethod
    def write(path: Path, content: str | bytes) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            path.write_bytes(content)
        else:
            path.write_text(content, encoding="utf-8", newline="\n")

    @staticmethod
    def stamp(paths: Iterable[Path], timestamp: float) -> None:
        for path in paths:
            os.utime(path, (timestamp, timestamp))

    def create_reports(self, *, slack: float = 0.125, seed: int | None = None) -> None:
        fit_seed = self.seed if seed is None else seed
        map_summary = self.output / f"{self.revision}.map.summary"
        map_report = self.output / f"{self.revision}.map.rpt"
        fit_summary = self.output / f"{self.revision}.fit.summary"
        fit_report = self.output / f"{self.revision}.fit.rpt"
        sta_summary = self.output / f"{self.revision}.sta.summary"
        sta_report = self.output / f"{self.revision}.sta.rpt"
        asm_report = self.output / f"{self.revision}.asm.rpt"
        rbf = self.output / f"{self.revision}.rbf"

        self.write(map_summary, "Analysis & Synthesis Status : Successful\n")
        self.write(
            map_report,
            "; Estimate of Logic utilization (ALMs needed) ; 12345 ;\n"
            "; Combinational ALUT usage for logic ; 23456 ;\n"
            "; Dedicated logic registers ; 12000 ;\n",
        )
        self.write(
            fit_summary,
            "Fitter Status : Successful\n"
            "Logic utilization (in ALMs) : 39,000 / 41,910 ( 93 % )\n"
            "Total registers : 38,000\n"
            "Total block memory bits : 5,100,000 / 5,662,720 ( 90 % )\n"
            "Total RAM Blocks : 540 / 553 ( 98 % )\n"
            "Total DSP Blocks : 40 / 112 ( 36 % )\n"
            "Total PLLs : 1 / 8 ( 13 % )\n",
        )
        self.write(
            fit_report,
            f"; Fitter Initial Placement Seed ; {fit_seed} ;\n"
            "Router estimated average interconnect usage is 31%\n"
            "Router estimated peak interconnect usage is 61%\n",
        )
        self.write(
            sta_summary,
            "Type : Slow 1100mV 85C Model Setup 'clk_sys'\n"
            f"Slack : {slack:.3f}\n"
            "TNS : 0.000\n"
            "Type : Slow 1100mV 85C Model Hold 'clk_sys'\n"
            "Slack : 0.050\n"
            "TNS : 0.000\n",
        )
        self.write(
            sta_report,
            "Info (332101): Design is fully constrained for setup requirements\n"
            "Info (332101): Design is fully constrained for hold requirements\n",
        )
        self.write(asm_report, "Assembler was successful\n")
        self.write(rbf, b"RBF\x00synthetic-nonempty-payload")

        self.stamp((map_summary, map_report), self.map_stamp)
        self.stamp((fit_summary, fit_report), self.fit_stamp)
        self.stamp((sta_summary, sta_report), self.sta_stamp)
        self.stamp((asm_report,), self.rbf_stamp - 1)
        self.stamp((rbf,), self.rbf_stamp)

    def report(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return run_powershell_file(
            TOOLS / "report-quartus.ps1",
            (
                "-ProjectRoot",
                str(self.root),
                "-Revision",
                self.revision,
                "-QuartusRoot",
                str(self.quartus_root),
                *extra,
            ),
        )

    def write_manifest(self) -> None:
        result = self.report("-WriteMapManifest")
        if result.returncode != 0:
            raise AssertionError(
                f"Could not create synthetic map manifest ({result.returncode}):\n"
                f"{result.stdout}"
            )
        manifest_stamp = (
            self.output / f"{self.revision}.map.inputs.json"
        ).stat().st_mtime
        self.stamp(
            (self.output / f"{self.revision}.fit.summary",
             self.output / f"{self.revision}.fit.rpt"),
            manifest_stamp + 1,
        )
        self.stamp(
            (self.output / f"{self.revision}.sta.summary",
             self.output / f"{self.revision}.sta.rpt"),
            manifest_stamp + 2,
        )
        self.stamp((self.output / f"{self.revision}.asm.rpt",), manifest_stamp + 3)
        self.stamp((self.output / f"{self.revision}.rbf",), manifest_stamp + 4)


@unittest.skipUnless(POWERSHELL, "PowerShell is required")
class ReportQualificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = SyntheticQuartusProject()
        self.fixture.create_reports()
        self.fixture.write_manifest()

    def tearDown(self) -> None:
        self.fixture.close()

    def test_fresh_matching_reports_and_manifest_are_deployable(self) -> None:
        result = self.fixture.report(
            "-ExpectedSeed",
            str(self.fixture.seed),
            "-AsJson",
            "-RequireReady",
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        data = decode_json_output(result.stdout)
        self.assertTrue(data["MapCurrent"])
        self.assertTrue(data["FitCurrent"])
        self.assertTrue(data["TimingCurrent"])
        self.assertTrue(data["TimingMet"])
        self.assertTrue(data["RbfCurrent"])
        self.assertTrue(data["ReadyToDeploy"])

    def test_negative_timing_has_distinct_retryable_exit_code(self) -> None:
        self.fixture.create_reports(slack=-0.125)
        self.fixture.write_manifest()
        result = self.fixture.report(
            "-ExpectedSeed",
            str(self.fixture.seed),
            "-RequireTiming",
        )
        self.assertEqual(
            result.returncode,
            1,
            "negative timing must be distinguished from a stale/invalid build\n"
            + result.stdout,
        )

    def test_input_content_change_invalidates_map_even_with_old_timestamp(self) -> None:
        source = self.fixture.root / "rtl" / "core.sv"
        source.write_text("module core; wire changed; endmodule\n", encoding="utf-8")
        os.utime(source, (self.fixture.input_stamp, self.fixture.input_stamp))
        result = self.fixture.report("-RequireMapCurrent")
        self.assertEqual(
            result.returncode,
            2,
            "a fingerprint mismatch is structural/stale, not a seed timing miss\n"
            + result.stdout,
        )

    def test_expected_seed_mismatch_is_structural_failure(self) -> None:
        result = self.fixture.report(
            "-ExpectedSeed",
            "3",
            "-RequireTiming",
        )
        self.assertEqual(result.returncode, 2, result.stdout)

    def test_unconstrained_warning_is_visible_and_optionally_enforced(self) -> None:
        sta_report = self.fixture.output / f"{self.fixture.revision}.sta.rpt"
        sta_report.write_text(
            "Warning: Design is not fully constrained for setup requirements\n",
            encoding="utf-8",
        )
        manifest_stamp = (
            self.fixture.output / f"{self.fixture.revision}.map.inputs.json"
        ).stat().st_mtime
        os.utime(sta_report, (manifest_stamp + 2, manifest_stamp + 2))
        visible = self.fixture.report("-AsJson", "-RequireTiming")
        self.assertEqual(visible.returncode, 0, visible.stdout)
        self.assertTrue(decode_json_output(visible.stdout)["NotFullyConstrained"])
        enforced = self.fixture.report("-RequireTiming", "-RequireTimingCoverage")
        self.assertEqual(enforced.returncode, 2, enforced.stdout)

    def test_seed_state_marks_only_a_new_best_for_diagnostics(self) -> None:
        state = self.fixture.root / "best-timing.json"
        arguments = (
            "-ProjectRoot", str(self.fixture.root),
            "-Revision", self.fixture.revision,
            "-ExpectedSeed", str(self.fixture.seed),
            "-StatePath", str(state),
        )
        first = run_powershell_file(TOOLS / "build-seed-state.ps1", arguments)
        self.assertEqual(first.returncode, 10, first.stdout)
        self.assertTrue(state.is_file())
        second = run_powershell_file(TOOLS / "build-seed-state.ps1", arguments)
        self.assertEqual(second.returncode, 0, second.stdout)


@unittest.skipUnless(POWERSHELL, "PowerShell is required")
class PreflightValidationTests(unittest.TestCase):
    def test_malformed_seed_is_rejected_before_compiler_validation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="s32-preflight-") as temporary:
            root = Path(temporary)
            quartus_root = root / "fake-quartus"
            quartus_root.mkdir()
            result = run_powershell_file(
                TOOLS / "build-preflight.ps1",
                ("-ProjectRoot", str(root), "-QuartusRoot", str(quartus_root),
                 "-Project", "segas32", "-Revision", "segas32",
                 "-ReleaseName", "segas32", "-FitSeeds", "2 crash",
                 "-MapRetries", "2", "-FitRetries", "2", "-ResumeFit", "0"),
            )
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("Invalid fitter seed 'crash'", result.stdout)

@unittest.skipUnless(POWERSHELL, "PowerShell is required")
class PowerShellSyntaxTests(unittest.TestCase):
    def test_pipeline_scripts_parse_without_errors(self) -> None:
        names = (
            "build-preflight.ps1",
            "build-clean.ps1",
            "build-seed-state.ps1",
            "build-stage-release.ps1",
            "build-docker.ps1",
            "invoke-build-locked.ps1",
            "report-quartus.ps1",
            "sha256.ps1",
            "deploy-mister.ps1",
            "deploy-s32.ps1",
        )
        for name in names:
            with self.subTest(script=name):
                path = TOOLS / name
                self.assertTrue(path.is_file(), f"missing pipeline helper: {path}")
                quoted = str(path).replace("'", "''")
                command = (
                    "$tokens=$null; $errors=$null; "
                    "[System.Management.Automation.Language.Parser]::ParseFile("
                    f"'{quoted}', [ref]$tokens, [ref]$errors) | Out-Null; "
                    "if ($errors.Count -ne 0) { "
                    "$errors | ForEach-Object { Write-Error $_.Message }; exit 1 }"
                )
                result = subprocess.run(
                    [
                        POWERSHELL,
                        "-NoLogo",
                        "-NoProfile",
                        "-NonInteractive",
                        "-Command",
                        command,
                    ],
                    cwd=REPO_ROOT,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    timeout=15,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stdout)


    def test_sha256_helper_matches_python(self) -> None:
        with tempfile.TemporaryDirectory(prefix="s32-sha256-") as temporary:
            path = Path(temporary) / "probe.bin"
            payload = b"Sega System 32\x00Golden Axe\xff"
            path.write_bytes(payload)
            helper = str(TOOLS / "sha256.ps1").replace("'", "''")
            probe = str(path).replace("'", "''")
            command = f". '{helper}'; Get-S32FileSha256 -LiteralPath '{probe}'"
            result = subprocess.run(
                [POWERSHELL, "-NoProfile", "-Command", command],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=30,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertEqual(result.stdout.strip(), hashlib.sha256(payload).hexdigest())


class BatchPipelineSafetyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.build = (TOOLS / "build.bat").read_text(encoding="utf-8")
        cls.standard = (TOOLS / "build-s32.bat").read_text(encoding="utf-8")

    def test_windows_batch_files_use_crlf_for_reliable_label_scanning(self) -> None:
        for path in (TOOLS / "build.bat", TOOLS / "build-s32.bat"):
            data = path.read_bytes()
            self.assertNotIn(b"\n", data.replace(b"\r\n", b""), path.name)


    def test_negative_native_exit_codes_cannot_fall_through(self) -> None:
        for name, content in (
            ("build.bat", self.build),
            ("build-s32.bat", self.standard),
        ):
            with self.subTest(script=name):
                self.assertNotRegex(content, r"(?im)^\s*if\s+errorlevel\s+1\b")

    def test_profile_wrappers_take_the_build_lock(self) -> None:
        for wrapper in (self.standard,):
            self.assertIn("invoke-build-locked.ps1", wrapper.lower())
            self.assertIn("s32_build_lock_token", wrapper.lower())

    def test_primary_seed_is_two_and_configuration_is_preflighted(self) -> None:
        self.assertRegex(
            self.build,
            r"(?im)^\s*if\s+not\s+defined\s+S32_FIT_SEEDS\s+"
            r"set\s+S32_FIT_SEEDS=2(?:\s|$)",
        )
        self.assertIn("build-preflight.ps1", self.build.lower())

    def test_pipeline_uses_checked_cleanup_and_release_staging(self) -> None:
        lowered = self.build.lower()
        self.assertIn("build-clean.ps1", lowered)
        self.assertIn("build-stage-release.ps1", lowered)
        self.assertIn("build-seed-state.ps1", lowered)

    def test_merged_qsf_preserves_memory_alm_slack(self) -> None:
        qsf = (REPO_ROOT / "Arcade-SegaSystem32Multi.qsf").read_text(encoding="utf-8")
        self.assertNotIn("S32_JT12_MLAB_SHIFTS=1", qsf)
        self.assertNotIn("S32_V25_MLAB_FIFO=1", qsf)
        self.assertNotIn("S32_V25_MLAB_EEPROM=1", qsf)
        self.assertIn("S32_UNIVERSAL=1", qsf)
        self.assertIn("S32_V25_HW=1", qsf)

    def test_timing_qualification_precedes_assembly(self) -> None:
        seed_body = self.build.lower().split(":try_seed", maxsplit=1)[1]
        timing = seed_body.find("quartus_sta.exe")
        assembly = seed_body.find("quartus_asm.exe")
        self.assertGreaterEqual(timing, 0)
        self.assertGreater(assembly, timing)


@unittest.skipUnless(os.name == "nt" and POWERSHELL, "Windows PowerShell required")
class LockWrapperTests(unittest.TestCase):
    def test_profile_wrapper_locks_and_preserves_build_exit(self) -> None:
        with tempfile.TemporaryDirectory(prefix="s32-ga-wrapper-") as temporary:
            root = Path(temporary)
            tools = root / "tools"
            tools.mkdir()
            for name in ("build-s32.bat", "invoke-build-locked.ps1"):
                shutil.copy2(TOOLS / name, tools / name)
            (tools / "build-incremental.bat").write_text(
                "@echo off\r\n"
                ">>\"%~dp0..\\order.txt\" echo build\r\n"
                "if /I not \"%S32_BUILD_LOCK_HELD%\"==\"1\" exit /b 88\r\n"
                "if \"%S32_BUILD_LOCK_TOKEN%\"==\"\" exit /b 89\r\n"
                "exit /b 73\r\n",
                encoding="ascii",
                newline="",
            )
            env = os.environ.copy()
            env.pop("S32_BUILD_LOCK_HELD", None)
            env.pop("S32_BUILD_LOCK_TOKEN", None)
            result = subprocess.run(
                # Name the script by its full path.  cmd.exe only resolves a
                # bare name from the current directory when the environment
                # permits it, and NoDefaultCurrentDirectoryInExePath=1 (set in
                # some sandboxes, including Claude Code sessions) forbids it --
                # the script is then "not recognized" and this test fails for a
                # reason that has nothing to do with the build wrapper.  cwd
                # stays on tools because the wrapper resolves its siblings
                # relative to %~dp0 and writes ..\order.txt.
                [env.get("ComSpec", "cmd.exe"), "/d", "/c",
                 str(tools / "build-s32.bat")],
                cwd=tools,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=30,
                check=False,
            )
            self.assertEqual(result.returncode, 73, result.stdout)
            order = (root / "order.txt").read_text(encoding="utf-8").splitlines()
            self.assertEqual(order, ["build"])

    def test_lock_wrapper_preserves_child_exit_and_persistent_log(self) -> None:
        with tempfile.TemporaryDirectory(prefix="s32-lock-probe-") as temporary:
            root = Path(temporary)
            script_dir = root / "tools"
            script_dir.mkdir()
            probe = script_dir / "probe.bat"
            probe.write_text(
                "@echo off\r\n"
                "echo S32_SAFE_LOCK_PROBE\r\n"
                "echo QSYS_INFORMATIONAL_STDERR 1>&2\r\n"
                "exit /b 73\r\n",
                encoding="ascii",
                newline="",
            )
            result = run_powershell_file(
                TOOLS / "invoke-build-locked.ps1",
                ("-BuildScript", str(probe)),
            )
            self.assertEqual(result.returncode, 73, result.stdout)
            self.assertIn("QSYS_INFORMATIONAL_STDERR", result.stdout)
            logs = list(root.glob("*.log"))
            self.assertTrue(logs, "the wrapper must retain a root-level build log")
            self.assertTrue(
                any(b"S32_SAFE_LOCK_PROBE" in path.read_bytes() or b"S\x003\x002\x00_\x00S\x00A\x00F\x00E\x00_\x00L\x00O\x00C\x00K\x00_\x00P\x00R\x00O\x00B\x00E\x00" in path.read_bytes() for path in logs),
                "the retained build log did not contain child output",
            )
            self.assertEqual(list(root.glob("*.pid")), [], "PID metadata was not cleaned")

class CIWorkflowSafetyTests(unittest.TestCase):
    def test_public_ci_is_source_only_and_uses_portable_checks(self) -> None:
        workflow = (
            REPO_ROOT / ".github" / "workflows" / "build.yml"
        ).read_text(encoding="utf-8")
        lowered = workflow.lower()
        self.assertIn("runs-on: windows-latest", lowered)
        self.assertIn("unittest discover", lowered)
        self.assertIn("check_ga2_release.py", lowered)
        self.assertIn("check_holo_release.py", lowered)
        self.assertIn("bash -n tools/build.sh", lowered)
        self.assertIn("build-segas32.bat", lowered)
        self.assertNotIn("build-segas32v25.bat", lowered)
        self.assertNotIn("docker run", lowered)
        self.assertNotIn("bash tools/build.sh", lowered)
        self.assertNotIn("upload-artifact", lowered)
        self.assertNotIn("action-gh-release", lowered)


class VerilatorPathContractTests(unittest.TestCase):
    def test_verilator_scripts_use_global_ram_workspace_allocator(self) -> None:
        helper = (REPO_ROOT / "verif" / "verilator" / "workspace.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("workspace", helper)
        self.assertIn("VERILATOR_WORKSPACE", helper)
        self.assertIn("Rr]:\\\\Verilator", helper)

        script_roots = (REPO_ROOT / "verif", REPO_ROOT / "tools")
        offenders: list[str] = []
        for root in script_roots:
            for path in (*root.rglob("*.sh"), *root.rglob("*.ps1")):
                if path.resolve() == Path(__file__).resolve():
                    continue
                text = path.read_text(encoding="utf-8", errors="replace")
                if "verilator-safe" not in text.lower() and "--Mdir" not in text:
                    continue
                normalized = text.replace("\\", "/").lower()
                forbidden = (
                    "c:/msys64",
                    "/mnt/c/users/meath/bin/verilator",
                    "/c/users/meath/bin/verilator",
                    "scratch/tmp",
                    "--mdir obj_dir",
                )
                hits = [token for token in forbidden if token in normalized]
                if hits:
                    offenders.append(f"{path.relative_to(REPO_ROOT)}: {', '.join(hits)}")
        self.assertEqual(offenders, [], "stale Verilator paths:\n" + "\n".join(offenders))

class DeprecatedEntrypointTests(unittest.TestCase):
    @staticmethod
    def assert_actionable_failure(result: subprocess.CompletedProcess[str]) -> None:
        assert result.returncode != 0, result.stdout
        output = result.stdout.lower()
        assert "build-s32.bat" in output, result.stdout
        assert r"d:\q17" in output, result.stdout

    @unittest.skipUnless(POWERSHELL, "PowerShell is required")
    def test_docker_entrypoint_fails_before_docker_or_quartus(self) -> None:
        result = run_powershell_file(
            TOOLS / "build-docker.ps1",
            ("-SkipPull",),
        )
        self.assert_actionable_failure(result)

    @unittest.skipUnless(shutil.which("bash"), "bash is required")
    def test_linux_entrypoint_fails_before_quartus(self) -> None:
        result = subprocess.run(
            [shutil.which("bash") or "bash", "tools/build.sh"],
            cwd=REPO_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=15,
            check=False,
        )
        if "access is denied" in result.stdout.replace("\x00", "").lower():
            self.skipTest("the installed bash/WSL launcher is not usable")
        self.assert_actionable_failure(result)

    def test_legacy_python_qualifier_cannot_approve_an_rbf(self) -> None:
        result = subprocess.run(
            [sys.executable, "-B", str(TOOLS / "qualify_build.py")],
            cwd=REPO_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=15,
            check=False,
        )
        self.assert_actionable_failure(result)

if __name__ == "__main__":
    unittest.main()
