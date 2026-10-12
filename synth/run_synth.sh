#!/bin/sh
# Synthesizes the original and new designs for Cyclone IV GX with Yosys and
# prints a resource table (Markdown) to stdout and synth/build/results.md
# (or $RESULTS).
#
# Usage: sh synth/run_synth.sh [design:N ...]
#   design is two_spin, three_spin, direct (synth/VIRAL_n_spin_direct.v,
#   the original architecture scaled to N spins) or new (VIRAL_n_spin).
#   Default: the table in README.md.
#
# Multipliers are replaced by black boxes and counted as 18x18 embedded
# multiplier blocks, and spin_memory as M9K blocks, since that is where
# Quartus puts them (Yosys's Cyclone IV flow would build them from LUTs).
# Yosys does not use the Cyclone IV carry chains, so adders cost more LUTs
# and more logic levels than they would in Quartus. Use the numbers to
# compare designs, and Quartus for exact counts and clock speed.

set -e
cd "$(dirname "$0")"
mkdir -p build
RESULTS=${RESULTS:-build/results.md}

R=..
ORIG="$R/angle_lut.v $R/cordic_iterative.v $R/VIRAL_rotation_2.v"
NEW="$R/angle_lut.v $R/cordic_pipelined.v $R/VIRAL_rotation_pipe.v $R/VIRAL_n_spin.v"

CONFIGS=${*:-"two_spin:2 three_spin:3 direct:4 direct:10 direct:20 direct:50 new:3 new:10 new:100 new:1000"}

synth() {
	design=$1; n=$2
	name="${design}_${n}"
	init="build/spin_init_${n}.hex"
	mem=""
	case $design in
		two_spin)   files="$ORIG $R/VIRAL_two_spin_2.v";  top=VIRAL_two_spin_2;    params="" ;;
		three_spin) files="$ORIG $R/VIRAL_three_spin.v";  top=VIRAL_three_spin;    params="" ;;
		direct)     files="$ORIG VIRAL_n_spin_direct.v";  top=VIRAL_n_spin_direct
		            params="chparam -set N_SPINS $n -set INIT_FILE \"$init\" $top;" ;;
		new)        files="$NEW";                         top=VIRAL_n_spin;        mem=$n
		            params="chparam -set N_SPINS $n -set INIT_FILE \"$init\" $top;" ;;
	esac
	python3 $R/gen_spin_init.py "$n" --pattern random -o "$init"

	yosys -q -l "build/$name.log" -p "
		read_verilog -defer $files
		read_verilog -lib blackboxes.v
		$params
		hierarchy -top $top
		proc; flatten; opt; wreduce; opt_clean
		tee -q -o build/$name.muls dump t:\$mul
		techmap -map mult_blackbox.v t:\$mul
		synth_intel -family cycloneiv -top $top
		tee -q -o build/$name.stat stat
		delete t:dffeas t:MULT_BLACKBOX t:spin_memory
		tee -q -o build/$name.ltp ltp
	" > /dev/null

	python3 summarize.py "$design" "$n" "build/$name.stat" "build/$name.muls" \
		"build/$name.ltp" $mem | tee -a "$RESULTS"
}

echo "| design | spins | LUTs | registers | multipliers | 18x18 blocks | M9K | LUT levels |" | tee "$RESULTS"
echo "|---|---|---|---|---|---|---|---|" | tee -a "$RESULTS"
for c in $CONFIGS; do
	synth "${c%%:*}" "${c##*:}"
done
