#!/usr/bin/env python3
"""Write an initial spin state file (INIT_FILE) for VIRAL_n_spin.

One line per spin: 12 hex digits {x, y, z}, each a signed 16-bit Q1.15 value.

Patterns:
  alternating  (1/sqrt2, 0, +1/sqrt2), (1/sqrt2, 0, -1/sqrt2), ...
               the first two spins of VIRAL_two_spin_2 / VIRAL_three_spin
  random       random unit vectors (repeatable with --seed)

Example:
  python3 gen_spin_init.py 10 -o spin_init_10.hex
"""

import argparse
import math
import random


def q15(value):
    """Real number -> 16-bit two's complement Q1.15, saturating at +/-1."""
    n = max(-32768, min(32767, round(value * 32768)))
    return n & 0xFFFF


def spin_vectors(n_spins, pattern, seed):
    if pattern == "alternating":
        s = 1 / math.sqrt(2)
        return [(s, 0.0, s if i % 2 == 0 else -s) for i in range(n_spins)]

    rng = random.Random(seed)
    vectors = []
    for _ in range(n_spins):
        z = rng.uniform(-1, 1)
        phi = rng.uniform(0, 2 * math.pi)
        r = math.sqrt(1 - z * z)
        vectors.append((r * math.cos(phi), r * math.sin(phi), z))
    return vectors


def main():
    parser = argparse.ArgumentParser(
        description="Write an initial spin state file for VIRAL_n_spin.")
    parser.add_argument("n_spins", type=int)
    parser.add_argument("--pattern", choices=["alternating", "random"],
                        default="alternating")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("-o", "--output",
                        help="output file (default: spin_init_<n_spins>.hex)")
    args = parser.parse_args()

    output = args.output or f"spin_init_{args.n_spins}.hex"
    with open(output, "w") as f:
        for x, y, z in spin_vectors(args.n_spins, args.pattern, args.seed):
            f.write(f"{q15(x):04X}{q15(y):04X}{q15(z):04X}\n")


if __name__ == "__main__":
    main()
