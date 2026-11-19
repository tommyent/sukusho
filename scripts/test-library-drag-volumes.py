#!/usr/bin/env python3
"""Run the compiled test-library-drag save checks on disposable USB-format images."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def check_volume(probe, filesystem):
    with tempfile.TemporaryDirectory(prefix="sukusho-volume-") as work:
        image = Path(work) / "volume.dmg"
        subprocess.run(["hdiutil", "create", "-quiet", "-size", "128m", "-fs", filesystem,
                        "-volname", "DropTest", str(image)], check=True)
        # Keep the mount outside the image's temporary directory, even if detach fails.
        mount = Path(tempfile.mkdtemp(prefix="sukusho-mount-"))
        try:
            subprocess.run(["hdiutil", "attach", "-nobrowse", "-mountpoint", str(mount), str(image)], check=True)
            try:
                if not os.path.ismount(mount):
                    raise RuntimeError(f"Image did not mount at {mount}")
                print(f"Checking {filesystem}", flush=True)
                subprocess.run([probe, "--save-volume", str(mount)], check=True)
            finally:
                subprocess.run(["hdiutil", "detach", str(mount)], check=True)
        finally:
            if mount.exists() and not os.path.ismount(mount):
                mount.rmdir()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: test-library-drag-volumes.py /path/to/compiled/test-library-drag")
    for filesystem in ("ExFAT", "MS-DOS FAT32"):
        check_volume(str(Path(sys.argv[1]).resolve(strict=True)), filesystem)
