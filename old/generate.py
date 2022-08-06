import tempfile
import subprocess
import os
import json
import shutil
import pathlib
from tqdm import tqdm

import gi

gi.require_version("Flatpak", "1.0")
from gi.repository import Flatpak, GLib

GENERATED_PATH = "generated.json"


def setup_env():
    os.environ["FLATPAK_SYSTEM_DIR"] = "/dev/null"
    os.environ["FLATPAK_USER_DIR"] = tempfile.TemporaryDirectory().name


def add_flathub():
    subprocess.run(
        [
            "flatpak",
            "remote-add",
            "--user",
            "flathub",
            "https://flathub.org/repo/flathub.flatpakrepo",
        ]
    )


def get_ref_metadata(ref):
    key_file = GLib.KeyFile()
    key_file.load_from_bytes(ref.get_metadata(), GLib.KeyFileFlags.NONE)
    return key_file


def get_sha256(ref, info):
    subprocess.run(
        [
            "flatpak",
            "install",
            "--user",
            "--noninteractive",
            "flathub",
            ref,
        ]
    )
    subprocess.run(
        [
            "flatpak",
            "upgrade",
            "--user",
            "--noninteractive",
            "--commit",
            info["commit"],
            ref,
        ]
    )
    dir = pathlib.Path(os.environ["FLATPAK_USER_DIR"])
    shutil.rmtree(dir / "repo")
    if Flatpak.Ref.parse(ref).get_kind() == Flatpak.RefKind.APP:
        shutil.rmtree(dir / "runtime")
    sha256 = subprocess.run(
        ["nix-hash", "--type", "sha256", dir], stdout=subprocess.PIPE
    ).stdout.decode("utf-8")
    shutil.rmtree(dir)
    add_flathub()
    return sha256


def get_ref_info(ref):
    metadata = get_ref_metadata(ref)
    return {
        "runtime": metadata.get_string("Application", "runtime")
        if metadata.has_group("Application")
        else None,
        "commit": ref.get_commit(),
    }


def get_refs_info(refs):
    return {ref.format_ref_cached(): get_ref_info(ref) for ref in refs}


def main():
    setup_env()
    add_flathub()
    refs = Flatpak.Installation.new_user().list_remote_refs_sync("flathub")
    refs_info = get_refs_info(refs)
    if os.path.exists(GENERATED_PATH):
        with open(GENERATED_PATH, "r") as f:
            old_refs_info = json.load(f)
        updated_refs = {
            ref: info
            for (ref, info) in refs_info.items()
            if info["commit"] != old_refs_info[ref]["commit"]
        }
        for ref, info in tqdm(updated_refs.items()):
            info["sha256"] = get_sha256(ref, info)
    else:
        for ref, info in tqdm(refs_info.items()):
            info["sha256"] = get_sha256(ref, info)
    with open(GENERATED_PATH, "w") as f:
        json.dump(refs_info, f, indent=4)


if __name__ == "__main__":
    main()
