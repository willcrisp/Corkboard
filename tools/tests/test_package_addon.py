import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import package_addon  # noqa: E402


def test_zip_has_both_addons_and_nothing_else(tmp_path):
    path = package_addon.build("1.2.3", tmp_path)
    assert path.name == "Corkboard-1.2.3.zip"
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        assert {n.split("/")[0] for n in names} == {"Corkboard", "Corkboard_Cloud"}
        assert "Corkboard/Corkboard.toc" in names and "Corkboard/Libs/LibStub/LibStub.lua" in names
        assert not [n for n in names if "/spec/" in n or n.endswith(".py")]
        assert b"## Version: 1.2.3" in z.read("Corkboard/Corkboard.toc")
        assert b"## Version: 1.2.3" in z.read("Corkboard_Cloud/Corkboard_Cloud.toc")
        assert z.read("Corkboard_Cloud/Data.lua").endswith(b"CorkboardCloudData = nil\n")
        # Every file the TOC lists is in the zip.
        toc = z.read("Corkboard/Corkboard.toc").decode()
        for line in toc.splitlines():
            if line and not line.startswith("#"):
                assert "Corkboard/" + line.replace("\\", "/") in names, line


def test_install_replaces_both_addons_but_keeps_the_companions_data(tmp_path):
    addons = tmp_path / "AddOns"
    (addons / "Corkboard").mkdir(parents=True)
    (addons / "Corkboard" / "Stale.lua").write_text("-- from an older build")
    path = package_addon.build("1.2.3", tmp_path / "dist")

    package_addon.install(path, addons)
    assert not (addons / "Corkboard" / "Stale.lua").exists()
    assert (addons / "Corkboard" / "Corkboard.toc").is_file()
    assert (addons / "Corkboard_Cloud" / "Data.lua").read_bytes() == package_addon.EMPTY_DATA

    synced = b"CorkboardCloudData = { v = 1 }\n"
    (addons / "Corkboard_Cloud" / "Data.lua").write_bytes(synced)
    package_addon.install(path, addons)
    assert (addons / "Corkboard_Cloud" / "Data.lua").read_bytes() == synced
