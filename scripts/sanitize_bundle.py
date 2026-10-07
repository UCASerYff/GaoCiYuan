#!/usr/bin/env python3
"""Remove local build metadata from a staging bundle before release signing."""
import pathlib
import re
import subprocess
import sys


def main():
    app = pathlib.Path(sys.argv[1]).resolve()
    if app.suffix != ".app" or not (app / "Contents/Info.plist").is_file():
        raise SystemExit("Expected an application staging bundle")
    forbidden = re.compile(
        r"(^|/)(?:library\.json|accounts\.json|preferences\.plist|"
        r"[^/]*\.(?:sqlite|db|pdf|docx?|p12|pfx|pem|key)|"
        r"[^/]*\.(?:sqlite|db)-(?:wal|shm)|\.env(?:\.[^/]*)?)(?:$|/)",
        re.IGNORECASE,
    )
    macho = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
    for path in app.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        relative = path.relative_to(app).as_posix()
        if forbidden.search(relative):
            raise SystemExit("Release contains a disallowed data file: " + relative)
        if path.name == ".DS_Store" or path.suffix == ".swiftsourceinfo":
            path.unlink()
            continue
        with path.open("rb") as handle:
            magic = handle.read(4)
        if magic in macho:
            subprocess.run(["xcrun", "strip", "-S", str(path)], check=True)
    subprocess.run(["xattr", "-cr", str(app)], check=True)
    private_home = str(pathlib.Path.home()).encode()
    for path in app.rglob("*"):
        if path.is_file() and not path.is_symlink():
            if private_home in path.read_bytes():
                raise SystemExit("Release still contains a local source path: " + path.relative_to(app).as_posix())
    print("Release staging bundle contains no private data files or local source paths")


if __name__ == "__main__":
    main()
