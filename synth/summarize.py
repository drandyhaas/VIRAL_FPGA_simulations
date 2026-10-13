#!/usr/bin/env python3
"""Turn the Yosys outputs from run_synth.sh into one table row.

Usage: summarize.py name n_spins stat.txt muls.txt ltp.txt [memory_spins]

  LUTs, registers   cycloneiv_lcell_comb and dffeas cells
  multipliers       count, and 18x18 embedded multiplier blocks needed
                    (ceil(a/18) * ceil(b/18), half a block if both <= 9 bits)
  M9K               block RAMs for spin_memory: two memories of
                    memory_spins x 48 bits
  levels            longest chain of LUTs between registers, not counting
                    the multipliers and memories
"""

import math
import re
import sys


def count(stat, cell):
    m = re.search(r"^\s+(\d+)\s+" + re.escape(cell) + r"\s*$", stat, re.M)
    return int(m.group(1)) if m else 0


def mult_blocks(a, b):
    if a <= 9 and b <= 9:
        return 0.5
    return math.ceil(a / 18) * math.ceil(b / 18)


def m9k_blocks(depth, width=48):
    # widest M9K configuration for each depth (simple dual port)
    for max_depth, max_width in ((256, 36), (512, 18), (1024, 9), (2048, 4),
                                 (4096, 2), (8192, 1)):
        if depth <= max_depth:
            return math.ceil(width / max_width)
    return math.ceil(depth / 8192) * width


def main():
    name, n_spins, stat_file, mul_file, ltp_file = sys.argv[1:6]
    memory_spins = int(sys.argv[6]) if len(sys.argv) > 6 else 0

    stat = open(stat_file).read()
    luts = count(stat, "cycloneiv_lcell_comb")
    regs = count(stat, "dffeas")

    widths = re.findall(r"parameter \\A_WIDTH (\d+)\s+parameter \\B_WIDTH (\d+)",
                        open(mul_file).read())
    mults = len(widths)
    blocks = sum(mult_blocks(int(a), int(b)) for a, b in widths)

    m9k = 2 * m9k_blocks(memory_spins) if memory_spins else 0

    m = re.search(r"length=(\d+)", open(ltp_file).read())
    levels = int(m.group(1)) if m else -1

    print(f"| {name} | {n_spins} | {luts:,} | {regs:,} | {mults:,} | "
          f"{blocks:g} | {m9k} | {levels} |")


if __name__ == "__main__":
    main()
