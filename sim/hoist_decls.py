#!/usr/bin/env python3
"""Copy a Verilog file, moving module-level reg/parameter/localparam lines
to just after the port list.

The original designs use some regs before declaring them, which Quartus
accepts but Icarus Verilog rejects. Moving the declarations up (in their
original order) does not change behaviour.

Usage: python3 hoist_decls.py in.v out.v
"""

import re
import sys

DECL = re.compile(r"^\s*(reg|localparam|parameter)\b[^;]*;\s*(//.*)?$")


def main():
    src, dst = sys.argv[1], sys.argv[2]
    with open(src) as f:
        lines = f.read().splitlines()

    port_end = next(i for i, line in enumerate(lines) if line.strip() == ");")
    head = lines[:port_end + 1]
    body = lines[port_end + 1:]
    decls = [line for line in body if DECL.match(line)]
    rest = [line for line in body if not DECL.match(line)]

    with open(dst, "w") as f:
        f.write("\n".join(head + decls + rest) + "\n")


if __name__ == "__main__":
    main()
