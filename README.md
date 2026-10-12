# VIRAL FPGA simulations

Verilog for simulating interacting spins on an FPGA. Each spin is a classical
3D vector (x, y, z). In every layer, each spin is rotated about z by an angle
set by a parameter γ and the z components of the other spins, then rotated
about x by an angle β. After the last layer the design computes the energy
Σ<sub>i&lt;j</sub> z<sub>i</sub> z<sub>j</sub> and shows it on 8 LEDs. This is the structure of a
mean-field version of QAOA: the z rotation plays the role of the cost step
and the x rotation the mixer.

The repository has the original two- and three-spin designs, and
`VIRAL_n_spin`, a version that scales to hundreds or thousands of spins.

## Files

| File | What it is |
|---|---|
| `cordic_iterative.v` | Rotates a 2D vector by an angle (CORDIC), one iteration per clock |
| `VIRAL_rotation_2.v` | Rotates one spin about z, then about x, using one `cordic_iterative` twice |
| `angle_lut.v` | γ and β for each layer (4 entries) |
| `VIRAL_two_spin_2.v` | Original top level: 2 spins, 1 layer |
| `VIRAL_three_spin.v` | Original top level: 3 spins, 2 layers |
| `VIRAL_n_spin.v` | **Scalable top level**: N spins, same ports as `VIRAL_three_spin` |
| `VIRAL_rotation_pipe.v` | Streaming version of `VIRAL_rotation_2`: one spin per clock |
| `cordic_pipelined.v` | Pipelined version of `cordic_iterative` with bit-identical results |
| `spin_memory.v` | Initial and current spin states (block RAM) |
| `spin_init_3.hex` | Initial state of `VIRAL_three_spin`, for `VIRAL_n_spin` |
| `gen_spin_init.py` | Writes initial-state files for any number of spins |
| `sim/` | Icarus Verilog testbenches: `sh sim/run_sims.sh` |
| `synth/` | Yosys resource comparison: `sh synth/run_synth.sh` |

## Number formats

- **Spin components** are 16-bit signed Q1.15, so `0x7FFF` ≈ +1.
  `0x5A82` is 1/√2 and `0xA57E` is −1/√2.
- **Angles** are 32 bits, where 2³² is a full turn: `0x20000000` = 45°,
  `0x40000000` = 90°. Overflow wraps around, which is still the correct angle.
- **γ** is Q1.15. Spin i is rotated about z by γ·h<sub>i</sub>·180°, where
  h<sub>i</sub> is the sum of the other spins' z.

## How the original design works

`VIRAL_three_spin` runs each layer like this:

1. Read γ and β from `angle_lut`.
2. For each spin, add up the z of the other spins (h<sub>i</sub>) and multiply by γ
   to get its z-rotation angle.
3. Start all three `VIRAL_rotation_2` modules at once. Each uses its CORDIC
   twice: about z, then about x (about 40 clocks).
4. When all three finish, use the results as the next layer's input.

After the last layer it multiplies the z of every pair of spins, adds the
products, and puts bits [15:8] of the energy on the LEDs.

## Why the original design doesn't scale

Everything in it is copied once per spin or once per pair of spins:

- **Per spin:** a `VIRAL_rotation_2` with its own iterative CORDIC (about
  1,300 LUTs and 300 registers on Cyclone IV), about 150 registers of spin
  state and angles, and a multiplier for γ·h<sub>i</sub>.
- **Field:** each spin adds up the z of every other spin, so N(N−1) additions.
- **Energy:** one multiplier and one 32-bit register per pair, so N(N−1)/2.
  That's 4,950 multipliers at 100 spins.
- **One clock for every sum:** the field terms and the pair terms are each
  added in a single clock, so the logic between registers gets deeper as N
  grows.

The time per layer stays constant, because all spins rotate in parallel, but
the hardware grows as N². On Cyclone IV GX it runs out of multipliers at
around 25 spins and out of logic at around 50 (see the comparison below).

## The scalable design: `VIRAL_n_spin`

`VIRAL_n_spin` uses the same model, the same ports (`clk`, `reset`, `led`)
and the same `angle_lut`. It makes four changes:

1. **Energy in O(N).** Σ<sub>i&lt;j</sub> z<sub>i</sub> z<sub>j</sub> = (S² − Σ z<sub>i</sub>²) / 2, where
   S = Σ z<sub>i</sub>. S and Σ z<sub>i</sub>² are added up as each spin is written back, so
   the energy needs 2 multipliers for any N. It is also exact: the original
   rounds each pair term down, and those errors add up at large N.
2. **Field in O(N).** h<sub>i</sub> = S − z<sub>i</sub>, using S from the start of the layer.
   That's one subtraction per spin instead of N − 1 additions.
3. **One shared, pipelined rotation unit.**
   - `cordic_pipelined` does the same arithmetic as `cordic_iterative`, but
     each iteration has its own pipeline stage, so it accepts a new vector
     every clock.
   - `VIRAL_rotation_pipe` chains two of them: rotate about z, then about x.
   - All spins stream through it, one per clock. The spin states live in
     block RAM (`spin_memory`) instead of registers.
4. **Generalized.**
   - The number of spins is a parameter (`N_SPINS`).
   - Field and energy widths grow with log₂N, so nothing overflows.
   - The initial state comes from a file and is reloaded on every reset.
   - The LED value saturates instead of wrapping, and `LED_LSB` sets its scale.

The datapath handles one spin per clock:

```
 spin_memory --> h = S - z --> angle = gamma*h --> rotate about z --> rotate about x --+
  (block RAM)                                       (pipelined CORDIC) (pipelined CORDIC)|
      ^                                                                                 |
      +-------------------------------- write back <------------------------------------+
                                            |
                                            +--> S += z, Q += z^2
                                                 (S for the next layer, energy = (S^2 - Q) / 2)
```

As in the original, all spins in a layer are updated from the z values at
the start of that layer.

### Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `N_SPINS` | 3 | Number of spins |
| `N_LAYERS` | 2 | Number of layers. At most 4 unless `angle_lut` is extended |
| `INIT_FILE` | `"spin_init_3.hex"` | Initial spin states |
| `LED_LSB` | 8 | `led` = energy >>> `LED_LSB`, saturated to 8 bits. 8 matches the original for energies between −1 and 1 |

### Initial state file

The file has one line per spin: 12 hex digits for x, y and z, each 16-bit
Q1.15. For example, `5A8200005A82` is (0.707, 0, 0.707).

```
python3 gen_spin_init.py 100 -o spin_init_100.hex                          # alternating ±45° tilts
python3 gen_spin_init.py 100 --pattern random --seed 1 -o spin_init_100.hex  # random directions
```

In Quartus, the path is relative to the project directory.

### How its results compare with the originals

- `N_SPINS = 2`, `N_LAYERS = 1` reproduces `VIRAL_two_spin_2` bit for bit.
- `N_SPINS = 3`, `N_LAYERS = 2` with `spin_init_3.hex` runs the same case as
  `VIRAL_three_spin`, but one output value differs by 2 LSB. `VIRAL_three_spin`
  halves z<sub>j</sub> + z<sub>k</sub> before multiplying by γ, which drops the last bit when
  the sum is odd; `VIRAL_n_spin` keeps it. With the same rounding added, the
  results match exactly.

## Comparison: resources

These numbers are for Cyclone IV GX, from Yosys (`sh synth/run_synth.sh`).
"Original architecture" is `synth/VIRAL_n_spin_direct.v`: `VIRAL_three_spin`
generalized to N spins, with one `VIRAL_rotation_2` per spin, per-spin field
sums, and one multiplier per pair. Simulations confirm it gives the same
final spins as `VIRAL_n_spin`.

| Design | Spins | LUTs | Registers | Multipliers (18×18 blocks) | M9K | LUT levels |
|---|---|---|---|---|---|---|
| `VIRAL_two_spin_2` | 2 | 2,178 | 563 | 3 (3) | 0 | 17 |
| `VIRAL_three_spin` | 3 | 4,114 | 1,285 | 6 (6) | 0 | 17 |
| original architecture | 4 | 5,509 | 1,696 | 10 (10) | 0 | 17 |
| original architecture | 10 | 15,851 | 4,680 | 55 (65) | 0 | 21 |
| original architecture | 20 | 37,108 | 10,940 | 210 (230) | 0 | 32 |
| original architecture | 50 | 147,503 | 39,340 | 1,275 (1,325) | 0 | 63 |
| `VIRAL_n_spin` | 3 | 7,202 | 2,965 | 3 (3) | 4 | 12 |
| `VIRAL_n_spin` | 10 | 7,081 | 3,061 | 3 (7) | 4 | 13 |
| `VIRAL_n_spin` | 100 | 7,120 | 3,205 | 3 (7) | 4 | 14 |
| `VIRAL_n_spin` | 1,000 | 7,221 | 3,349 | 3 (7) | 12 | 14 |

How to read the table:

- **LUTs and registers:** a Cyclone IV logic element (LE) holds one 4-input
  LUT and one register, so the LE count lies between the larger of the two
  and their sum.
- **Multipliers and memory:** these go into the embedded 18×18 multipliers
  and M9K memory blocks. The script counts them from the bit widths, because
  that mapping is done by Quartus, not Yosys. Multipliers wider than 18 bits
  need more than one block.
- **LUT levels:** the longest chain of LUTs between two registers, not
  counting the multipliers and memories. It is a rough guide to how fast the
  design can be clocked (see below).
- **These are estimates.** Yosys's Cyclone IV flow is experimental and does
  not use the carry chains, so adders cost more LUTs and more levels than
  they will in Quartus. Use the numbers to compare designs, and Quartus for
  exact counts.

What the table shows:

- **Original architecture:** grows roughly as N².
  - LUTs: 37k at 20 spins, 148k at 50, and by extrapolation about 480k at
    100.
  - Multipliers: about N²/2, so 1,275 at 50 spins.
  - For scale, the largest Cyclone IV GX (EP4CGX150) has about 150k LEs and
    360 18×18 multipliers.
  - It runs out of multipliers at around 25 spins and out of logic at
    around 50.
- **`VIRAL_n_spin`:** stays at about 7k LUTs, 3k registers and 3 multipliers
  from 3 to 1,000 spins. Only the memory grows: 2 × 48 bits per spin, 4 M9K
  blocks up to 256 spins and 12 at 1,000.
- **Crossover:** below about 5 or 6 spins the original architecture is
  smaller, because the two pipelined CORDICs (30 stages) cost more than a
  few iterative ones.

## Comparison: timing

### Clock cycles

These are clock counts from simulation, for 2 layers including loading the
initial state and computing the energy:

| Spins | Original architecture | `VIRAL_n_spin` |
|---|---|---|
| 3 | 99 | 107 |
| 4 | 99 | 110 |
| 10 | 99 | 128 |
| 100 | 99 | 398 |
| 1,000 | 99 (not simulated) | 3,098 |

- **Original:** about 50 clocks per layer for any N, because every spin has
  its own rotation module and they all run at once.
- **`VIRAL_n_spin`:** N + 8 clocks to load the initial state, then N + 45
  per layer. Spins go through the shared pipeline one per clock, and 45 is
  the pipeline latency plus control. At 50 MHz, 100 spins and 2 layers take
  8 µs; 1,000 spins take 62 µs.

### Clock speed

Getting the maximum clock speed needs Quartus timing analysis (TimeQuest),
which this repository doesn't include. What sets it is the deepest logic
that has to finish in one clock:

| | Original architecture | `VIRAL_n_spin` |
|---|---|---|
| Rotation | Iterative CORDIC step: a variable shift by 0–14 bits, a 17-bit add or subtract, and a 32-bit angle add or subtract with a 15-entry table lookup | Pipelined CORDIC stage: fixed shift, a 17-bit add or subtract, a 32-bit add or subtract |
| Field | Sum of N − 1 values (adder tree log₂N deep) | One subtraction, h = S − z, (16 + log₂N) bits |
| Energy | Sum of N(N−1)/2 pair terms (adder tree 2·log₂N deep) | One subtraction, S² − Q, (32 + 2·log₂N) bits |
| Multipliers | 16 × (16 + log₂N) for the field, 16 × 16 per pair | 16 × (16 + log₂N), 16 × 16, (16 + log₂N)² |

Both designs also do the CORDIC gain correction (a sum of four shifted
copies of the input) in one clock.

So the original's clock gets slower as N grows: at 100 spins the energy is
a 13-level adder tree with 4,950 inputs, finished in one clock. Its
iterative CORDIC step is also deeper than a pipelined stage at any N. In
`VIRAL_n_spin` nothing scales with N except the widths, which grow with log₂N.

The "LUT levels" column in the resource table is Yosys's longest LUT chain
between registers. It fits this picture only roughly:

- **`VIRAL_n_spin`:** 12–14 levels from 3 to 1,000 spins, always on the
  h = S − z subtraction.
- **Original architecture:** 17 levels at 3–4 spins, 21 at 10, 32 at 20
  and 63 at 50. The longest path is on the CORDIC angle adder, a field sum,
  or the energy sum, depending on N. At 50 spins it is a field sum: 49
  values added in one clock.

Because Yosys builds adders from LUTs rather than carry chains, these
numbers mostly measure adder length, and they vary with how its optimizer
happens to map the adders.

### Overall

- **Small N:** the original takes fewer clocks (99 vs 107 at 3 spins), but
  `VIRAL_n_spin`'s shallower logic per clock should let it run at a faster
  clock.
- **Large N:** `VIRAL_n_spin` takes N + 45 clocks per layer at a clock speed
  that doesn't depend on N. The original keeps about 50 clocks per layer,
  but its clock slows down as N grows and it stops fitting on the chip
  beyond a few tens of spins.

## Simulation

`sh sim/run_sims.sh` (needs Icarus Verilog and Python 3) runs these checks:

- **`tb_compare_original.v`:** `VIRAL_n_spin` against `VIRAL_two_spin_2`
  (bit for bit) and `VIRAL_three_spin` (within 4 LSB, for the field rounding
  difference above).
- **`tb_VIRAL_n_spin.v`:** 1, 4, 10, 100 and 1,000 spins, with random and
  alternating initial states, and up to 4 layers. It checks:
  - final spins against N copies of the original `VIRAL_rotation_2`, bit
    for bit;
  - the energy against a pair-by-pair sum, exactly;
  - the LEDs;
  - spins against a floating-point model (max error 0.003 up to 100 spins,
    0.013 at 1,000, because the rotation angle is proportional to the field,
    which grows with N);
  - that a reset reloads the initial state.
- **`tb_direct_vs_new.v`:** `synth/VIRAL_n_spin_direct.v` against
  `VIRAL_n_spin` at 3, 4, 10 and 100 spins: same final spins, plus clock
  counts.

## Synthesis comparison

`sh synth/run_synth.sh` (needs Yosys and Python 3) produces the resource
table above. Results go in `synth/build/results.md`. You can choose
configurations, e.g. `sh synth/run_synth.sh new:100 direct:10`. The original
architecture is slow to synthesize at large N: about 9 minutes at 50 spins,
and much longer at 100.

## Notes

- **Coupling:** `VIRAL_n_spin` keeps the original's uniform all-to-all
  coupling. For a general coupling matrix J<sub>ij</sub> (for example MaxCut on a
  graph), you could store J in block RAM and compute h<sub>i</sub> = Σ J<sub>ij</sub> z<sub>j</sub>
  with a few multiply-accumulate units.
- **Icarus Verilog and the original files:** Icarus rejects the original
  files as they are, because some regs are used before they are declared.
  Quartus and Yosys accept this. `sim/run_sims.sh` simulates copies with the
  declarations moved up (`sim/hoist_decls.py`).
- **Limitations of the original designs that `VIRAL_n_spin` doesn't have:**
  - `VIRAL_two_spin_2` doesn't feed results back between layers, and reads
    `angle_lut` one clock too early, so it only works for one layer.
  - In `VIRAL_three_spin`, spin 3 starts as the zero vector, so it never
    contributes.
  - Reset doesn't restore the initial spins.
  - The LEDs only show energies between −1 and 1 before wrapping.
