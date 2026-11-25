#!/usr/bin/env python3
"""Set app bundle metadata in the build checkout, without committing it."""
import argparse
import plistlib
import re
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("build_number")
    args = parser.parse_args()
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", args.version):
        parser.error("version must contain three numeric components")
    if not re.fullmatch(r"[1-9][0-9]*", args.build_number):
        parser.error("build number must be a positive integer")
    path = Path("Resources/Info.plist")
    info = plistlib.loads(path.read_bytes())
    info["CFBundleShortVersionString"] = args.version
    info["CFBundleVersion"] = args.build_number
    path.write_bytes(plistlib.dumps(info, sort_keys=False))


if __name__ == "__main__":
    main()
