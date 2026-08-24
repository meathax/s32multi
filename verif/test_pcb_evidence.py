"""Regression gate for the source-backed PCB evidence contract."""

import unittest

from tools.validate_pcb_evidence import validate


class PcbEvidenceTests(unittest.TestCase):
    def test_ledger_and_production_rtl_contract(self) -> None:
        self.assertEqual(validate(check_rtl=True), [])


if __name__ == "__main__":
    unittest.main()
