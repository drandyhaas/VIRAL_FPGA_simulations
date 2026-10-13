#!/bin/sh
# Simulates VIRAL_n_spin with Icarus Verilog:
#   - against the original two- and three-spin designs (bit for bit)
#   - for several spin counts against a reference built from the original
#     rotation modules, a pairwise energy sum, and a floating-point model
#
# Usage: sh sim/run_sims.sh   (from anywhere; build files go in sim/build)

set -e
cd "$(dirname "$0")"
mkdir -p build

# The original designs use some regs before declaring them, which Icarus
# rejects, so simulate copies with the declarations moved up.
for f in VIRAL_rotation_2 VIRAL_two_spin_2 VIRAL_three_spin; do
	python3 hoist_decls.py "../$f.v" "build/$f.v"
done

SRC="../angle_lut.v ../cordic_iterative.v ../cordic_pipelined.v \
     build/VIRAL_rotation_2.v ../VIRAL_rotation_pipe.v ../spin_memory.v \
     ../serial_mult.v ../VIRAL_n_spin.v"

echo "=== new design vs original two- and three-spin designs ==="
python3 ../gen_spin_init.py 2 -o build/spin_init_2.hex
iverilog -g2005 -o build/tb_compare_original \
	$SRC build/VIRAL_two_spin_2.v build/VIRAL_three_spin.v tb_compare_original.v
vvp -n build/tb_compare_original

run_n_spin() {
	n=$1; layers=$2; pattern=$3; tol=${4:-0.01}; gamma_lo=${5:-0}
	init="build/spin_init_${n}_${pattern}.hex"
	echo "--- $n spins, $layers layers, $pattern initial state, gamma low bits $gamma_lo"
	python3 ../gen_spin_init.py "$n" --pattern "$pattern" -o "$init"
	iverilog -g2005 -o "build/tb_n_spin_${n}" \
		-Ptb_VIRAL_n_spin.N_SPINS="$n" \
		-Ptb_VIRAL_n_spin.N_LAYERS="$layers" \
		-Ptb_VIRAL_n_spin.INIT_FILE="\"$init\"" \
		-Ptb_VIRAL_n_spin.FLOAT_TOL="$tol" \
		-Ptb_VIRAL_n_spin.GAMMA_LO="$gamma_lo" \
		$SRC tb_VIRAL_n_spin.v
	vvp -n "build/tb_n_spin_${n}"
}

echo
echo "=== scale tests ==="
run_n_spin 1   2 random
run_n_spin 4   2 random
run_n_spin 10  2 random
run_n_spin 10  4 alternating
run_n_spin 100 2 random
run_n_spin 100 2 alternating
# the float model drifts more for many spins: the z rotation angle is
# proportional to the field, which grows with N
run_n_spin 1000 2 random 0.05
# full 32-bit gamma: low bits set (on all 4 layers with 4 layers; the last
# two angle_lut entries are gamma = 0, so there gamma is just the low bits)
run_n_spin 10   4 alternating 0.01 4660
run_n_spin 100  4 random      0.01 43981
run_n_spin 1000 2 random      0.05 4660

echo
echo "=== original architecture scaled to N spins (synth/VIRAL_n_spin_direct.v) vs new ==="
for n in 3 4 10 100; do
	init="build/spin_init_${n}_random.hex"
	python3 ../gen_spin_init.py "$n" --pattern random -o "$init"
	iverilog -g2005 -o "build/tb_direct_${n}" \
		-Ptb_direct_vs_new.N_SPINS="$n" \
		-Ptb_direct_vs_new.INIT_FILE="\"$init\"" \
		$SRC ../synth/VIRAL_n_spin_direct.v tb_direct_vs_new.v
	vvp -n "build/tb_direct_${n}"
done
