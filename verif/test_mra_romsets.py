import unittest
from pathlib import Path
from xml.etree import ElementTree


class CloneMraRomsetTests(unittest.TestCase):
    def test_clone_mras_accept_merged_nonmerged_and_split_archives(self) -> None:
        mra_dir = Path(__file__).parents[1] / "releases"
        clone_count = 0
        for path in sorted(mra_dir.glob("*.mra")):
            root = ElementTree.parse(path).getroot()
            parent = root.findtext("parent")
            if not parent:
                continue
            clone_count += 1
            setname = root.findtext("setname")
            region_roms = [r for r in root.findall("rom")
                           if int(r.attrib["index"]) >= 4]
            self.assertGreater(len(region_roms), 0, path.name)
            for rom in region_roms:
                self.assertEqual(rom.attrib["zip"],
                                 f"{parent}.zip|{setname}.zip")
        self.assertGreater(clone_count, 0)

    def test_every_external_part_has_an_archive_source(self) -> None:
        """Named files must resolve from this rom or from the part itself."""
        mra_dir = Path(__file__).parents[1] / "releases"
        checked = 0
        for path in sorted(mra_dir.glob("*.mra")):
            root = ElementTree.parse(path).getroot()
            for rom in root.findall("rom"):
                rom_zip = rom.attrib.get("zip")
                for part in rom.iter("part"):
                    if "name" not in part.attrib:
                        continue
                    checked += 1
                    self.assertTrue(
                        rom_zip or part.attrib.get("zip"),
                        f"{path.name}: index {rom.attrib['index']} part "
                        f"{part.attrib['name']} has no zip source",
                    )
        self.assertGreater(checked, 0)


if __name__ == "__main__":
    unittest.main()
