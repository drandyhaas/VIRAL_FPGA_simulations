#!/usr/bin/env python3
"""Write a spin weight file (WEIGHT_FILE) for VIRAL_n_spin.

One line per spin: 4 hex digits, unsigned with 15 fractional bits, so
8000 = 1.0 and FFFF is just under 2.

With weights a_i the cost is sum_{i<j} a_i a_j z_i z_j, which up to a
constant is the number-partitioning cost (sum_i a_i z_i)^2 / 2.

Patterns:
  ones    every weight 1.0 (the same as no WEIGHT_FILE)
  random  uniform in (0, 1] (repeatable with --seed)

Example:
  python3 gen_weights.py 100 --pattern random -o weights_100.hex
"""

import argparse
import random


def main():
    parser = argparse.ArgumentParser(
        description="Write a spin weight file for VIRAL_n_spin.")
    parser.add_argument("n_spins", type=int)
    parser.add_argument("--pattern", choices=["ones", "random"],
                        default="random")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("-o", "--output",
                        help="output file (default: weights_<n_spins>.hex)")
    args = parser.parse_args()

    rng = random.Random(args.seed)
    output = args.output or f"weights_{args.n_spins}.hex"
    with open(output, "w") as f:
        for _ in range(args.n_spins):
            w = 0x8000 if args.pattern == "ones" else rng.randint(1, 0x8000)
            f.write(f"{w:04X}\n")


if __name__ == "__main__":
    main()
