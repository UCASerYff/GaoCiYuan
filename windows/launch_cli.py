import sys

from launch import main


if __name__ == '__main__':
    # Windows pipes otherwise use the local ANSI code page, which may not represent Chinese.
    for stream in (sys.stdout, sys.stderr):
        if stream is not None:
            stream.reconfigure(encoding='utf-8', errors='backslashreplace')
    raise SystemExit(main(console=True))
