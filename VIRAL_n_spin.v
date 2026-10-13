module VIRAL_n_spin #(
	parameter N_SPINS   = 3,
	parameter N_LAYERS  = 2,
	parameter INIT_FILE = "spin_init_3.hex",
	parameter LED_LSB   = 8
)(
	input clk,
	input reset,
	output reg [7:0] led
);

// Scalable version of VIRAL_three_spin.
//
// Same model: N_SPINS spins stored as vectors (x, y, z in Q1.15), all-to-all
// coupling, and for each layer, using gamma and beta from angle_lut:
//   1. rotate spin i about z by gamma * h_i * 180 degrees,
//      where h_i = sum of z_j over j != i
//   2. rotate every spin about x by beta
// All spins are updated from the z values at the start of the layer.
// The energy sum_{i<j} z_i*z_j (Q1.15) is shown on the LEDs at the end.
//
// What makes it scale:
//   - spin states live in a memory (block RAM for large N), not per-spin registers
//   - one shared pipelined rotation unit (VIRAL_rotation_pipe) takes one spin per
//     clock, instead of one iterative rotation module per spin
//   - local field h_i = S - z_i, with S = sum of all z: O(N) instead of O(N^2)
//   - energy = (S^2 - sum z_i^2) / 2, also O(N), summed as results are written back
//   - field and energy widths grow with log2(N_SPINS), so nothing overflows
//
// Timing: every path is at most one adder or one DSP-sized multiply between
// registers, whatever N_SPINS is:
//   - gamma * h_i = gamma * S - gamma * z_i. gamma * S is computed once per
//     layer, so the per-spin multiply is 32 x 16 bits for any N_SPINS, split
//     into two 16/17 x 16 products that each fit one DSP multiplier
//   - S^2 and gamma * S are computed once per layer by shift-and-add
//     (serial_mult), one add per clock
//   - the spin memories have registered inputs and outputs (spin_memory)
//
// gamma is Q1.31 (angle_lut gamma_out). For many spins it has to be about
// 1/N_SPINS for the rotation angles to stay reasonable, which needs the extra
// bits. The z rotation angle is gamma * h_i rounded to the nearest angle LSB.
//
// Logic is roughly constant in N_SPINS. Memory is 2 x 48 bits per spin.
// Loading the initial state and computing its energy takes
// N_SPINS + SUM_W + 14 clocks; each layer takes N_SPINS + SUM_W + 54.
//
// INIT_FILE: one line per spin, 12 hex digits {x, y, z}, each a 16-bit Q1.15
// value, e.g. 5A8200005A82 = (0.707, 0, 0.707). See gen_spin_init.py.
// The initial state is reloaded on every reset.
//
// led = energy >>> LED_LSB, saturated to 8 bits. LED_LSB = 8 matches
// VIRAL_three_spin (led = total_energy[15:8]) for energies between -1 and 1.
// Increase LED_LSB for many spins.
//
// angle_lut has 4 entries, so N_LAYERS <= 4 unless the LUT is extended.
//
// N_SPINS = 3, N_LAYERS = 2 and spin_init_3.hex run the same case as
// VIRAL_three_spin. Results can differ by a few LSB because VIRAL_three_spin
// halves z_j + z_k before multiplying by gamma (dropping the LSB of the
// field when the sum is odd), while h_i here is exact. N_SPINS = 2,
// N_LAYERS = 1 matches VIRAL_two_spin_2 bit for bit.

localparam IDX_W = (N_SPINS > 1) ? $clog2(N_SPINS) : 1;	// spin index
localparam CNT_W = $clog2(N_SPINS + 1);						// counts 0 .. N_SPINS
localparam SUM_W = 16 + $clog2(N_SPINS);						// holds any sum of N_SPINS Q1.15 values
localparam E_W   = 2 * SUM_W;									// S^2 and energy

localparam MEM_LAT = 4;		// spin_memory read latency
localparam FLD_LAT = 5;		// memory output to rotation input

// gamma * h is Q2.46; the 32-bit angle is bits [46:15], so only the
// products mod 2^47 are needed. ROUND rounds to the nearest angle LSB.
localparam GH_W = 47;
localparam [GH_W-1:0] ROUND = 1 << 14;


// ================================================================
// SPIN MEMORIES
//
// Each word is {x, y, z}: initial state (rom_q) and current state (ram_q).
// ================================================================

reg  [IDX_W-1:0] rd_addr;
wire [47:0]      rom_q;
wire [47:0]      ram_q;

reg              wr_en;
reg  [IDX_W-1:0] wr_addr;
reg  [47:0]      wr_data;

spin_memory #(.N_SPINS(N_SPINS), .IDX_W(IDX_W), .INIT_FILE(INIT_FILE)) spins(
	.clk			(clk),

	.rd_addr		(rd_addr),
	.rom_q		(rom_q),
	.ram_q		(ram_q),

	.wr_en		(wr_en),
	.wr_addr		(wr_addr),
	.wr_data		(wr_data)
);

wire signed [15:0] ram_z = ram_q[15:0];
wire signed [15:0] wr_z  = wr_data[15:0];


// ================================================================
// ANGLE LUT
// ================================================================

reg [1:0] angle_addr;

wire signed [31:0] gamma;
wire signed [31:0] beta;

reg signed [31:0] gamma_spin;
reg signed [31:0] beta_spin;

angle_lut angle_lut_1(
	.clk			(clk),
	.address		(angle_addr),

	.alpha_out	(),
	.gamma_out	(gamma),
	.beta_out	(beta)
);


// ================================================================
// SHARED ROTATION PIPELINE
// ================================================================

reg  [FLD_LAT-1:0]    fld_valid;
reg  [IDX_W+47:0]     fld_spin [0:FLD_LAT-1];	// {index, x, y, z}
reg  [GH_W-1:0]       fld_angle;					// gamma * h_i, mod 2^47

wire [IDX_W+47:0]     fld_out = fld_spin[FLD_LAT-1];

wire                  rot_valid;
wire [IDX_W-1:0]      rot_idx;
wire signed [15:0]    x_final;
wire signed [15:0]    y_final;
wire signed [15:0]    z_final;

VIRAL_rotation_pipe #(.TAG_WIDTH(IDX_W)) VIRAL_rotation(
	.clk					(clk),
	.reset				(reset),

	.in_valid			(fld_valid[FLD_LAT-1]),
	.in_tag				(fld_out[IDX_W+47:48]),

	.x_0					(fld_out[47:32]),
	.y_0					(fld_out[31:16]),
	.z_0					(fld_out[15:0]),

	.local_z_hz_gamma (fld_angle[46:15]),
	.global_x_beta		(beta_spin),

	.out_valid			(rot_valid),
	.out_tag				(rot_idx),

	.x_f					(x_final),
	.y_f					(y_final),
	.z_f					(z_final)
);


// ================================================================
// DATAPATH
//
// read spin -> gamma * z_i -> gamma * S - gamma * z_i -> rotation -> write back
// Initial states read from init_rom are written straight to spin_mem.
// ================================================================

reg rd_req;						// set by the state machine with rd_addr
reg rd_req_init;				// 1: copy from init_rom, 0: rotate from spin_mem

// read requests, delayed to line up with the memory outputs
reg [MEM_LAT-1:0] rd_req_p;
reg [MEM_LAT-1:0] rd_init_p;
reg [IDX_W-1:0]   rd_idx_p [0:MEM_LAT-1];

wire             rd_valid = rd_req_p[MEM_LAT-1];
wire             rd_init  = rd_init_p[MEM_LAT-1];
wire [IDX_W-1:0] rd_idx   = rd_idx_p[MEM_LAT-1];

wire [GH_W-1:0]  gamma_s;		// gamma * S + ROUND, for the layer

// gamma * z_i as two products that each fit a DSP multiplier:
// gamma = gamma_hi * 2^16 + gamma_lo
wire signed [15:0] gamma_hi = gamma_spin[31:16];
wire signed [16:0] gamma_lo = {1'b0, gamma_spin[15:0]};

reg signed [15:0]  mul_z;
reg signed [31:0]  p_hi_1, p_hi_2;
reg signed [32:0]  p_lo_1, p_lo_2;
reg signed [GH_W-1:0] gamma_z;

integer k;

always @(posedge clk) begin
	if (!reset) begin
		rd_req_p  <= 0;
		fld_valid <= 0;
		wr_en     <= 1'b0;
	end else begin
		rd_req_p  <= {rd_req_p[MEM_LAT-2:0], rd_req};
		fld_valid <= {fld_valid[FLD_LAT-2:0], rd_valid && !rd_init};
		wr_en     <= (rd_valid && rd_init) || rot_valid;
	end

	rd_init_p <= {rd_init_p[MEM_LAT-2:0], rd_req_init};
	rd_idx_p[0] <= rd_addr;
	for (k = 1; k < MEM_LAT; k = k + 1)
		rd_idx_p[k] <= rd_idx_p[k-1];

	// the spin rides along while its angle is computed
	fld_spin[0] <= {rd_idx, ram_q};
	for (k = 1; k < FLD_LAT; k = k + 1)
		fld_spin[k] <= fld_spin[k-1];

	// gamma * h_i = gamma * S - gamma * z_i, rounded, mod 2^47
	mul_z     <= ram_z;										// stage 1
	p_hi_1    <= gamma_hi * mul_z;							// stage 2
	p_lo_1    <= gamma_lo * mul_z;
	p_hi_2    <= p_hi_1;										// stage 3
	p_lo_2    <= p_lo_1;
	gamma_z   <= (p_hi_2 <<< 16) + p_lo_2;				// stage 4
	fld_angle <= gamma_s - gamma_z;							// stage 5

	// write back initial state or rotated spin (never both at once)
	if (rd_valid && rd_init) begin
		wr_addr <= rd_idx;
		wr_data <= rom_q;
	end else begin
		wr_addr <= rot_idx;
		wr_data <= {x_final, y_final, z_final};
	end
end


// ================================================================
// SUMS FOR THE NEXT FIELD AND THE ENERGY
//
// Every spin written to spin_mem is added to S = sum z and Q = sum z^2.
// ================================================================

reg                    acc_clear;
reg signed [SUM_W-1:0] s_acc;
reg signed [E_W-1:0]   q_acc;
reg signed [31:0]      z_sq_1, z_sq_2;
reg [1:0]              z_sq_valid;
reg [CNT_W-1:0]        wr_count;

always @(posedge clk) begin
	if (!reset || acc_clear) begin
		s_acc      <= 0;
		q_acc      <= 0;
		z_sq_valid <= 2'b00;
		wr_count   <= 0;
	end else begin
		if (wr_en) begin
			s_acc    <= s_acc + wr_z;
			wr_count <= wr_count + 1'b1;
		end
		z_sq_valid <= {z_sq_valid[0], wr_en};
		if (z_sq_valid[1])
			q_acc <= q_acc + z_sq_2;
	end
	z_sq_1 <= wr_z * wr_z;
	z_sq_2 <= z_sq_1;
end


// ================================================================
// ONCE-PER-LAYER PRODUCTS: S^2 for the energy, gamma * S for the field
// ================================================================

reg              mult_start;
wire [E_W-1:0]   s_sq;
wire             s_sq_busy;
wire             gamma_s_busy;

serial_mult #(.A_W(SUM_W), .B_W(SUM_W), .P_W(E_W)) s_square(
	.clk		(clk),
	.reset	(reset),
	.start	(mult_start),
	.a			(s_acc),
	.b			(s_acc),
	.c			({E_W{1'b0}}),
	.p			(s_sq),
	.busy		(s_sq_busy)
);

serial_mult #(.A_W(32), .B_W(SUM_W), .P_W(GH_W)) gamma_times_s(
	.clk		(clk),
	.reset	(reset),
	.start	(mult_start),
	.a			(gamma),
	.b			(s_acc),
	.c			(ROUND),
	.p			(gamma_s),
	.busy		(gamma_s_busy)
);


// ================================================================
// ENERGY
//
// sum_{i<j} z_i z_j = (S^2 - Q) / 2, in Q1.15: >>> 15 and >>> 1
// ================================================================

reg signed [E_W-1:0] energy_diff;		// S^2 - Q
reg signed [E_W-1:0] total_energy;

wire signed [E_W-1:0] energy_led = energy_diff >>> (16 + LED_LSB);

wire [7:0] led_now =
	(energy_led >  127) ? 8'h7F :
	(energy_led < -128) ? 8'h80 :
	energy_led[7:0];


// ================================================================
// CONTROL
//
// 1. copy the initial state into spin_mem, summing S and Q
// 2. wait for every spin to be written back
// 3. compute S^2 and gamma * S; latch gamma, beta for the next layer
// 4. energy of the current state
// 5. stream all spins through the rotation pipeline, then go to 2
// ================================================================

localparam LOAD_INIT   = 3'd0;
localparam WAIT_WRITES = 3'd1;
localparam MULTIPLY    = 3'd2;
localparam CALC_ENERGY = 3'd3;
localparam ISSUE_SPINS = 3'd4;
localparam FINISHED    = 3'd5;

reg [2:0] state;
reg [CNT_W-1:0] spin_count;
reg [7:0] roto_num;
reg energy_state;
reg finished;

reg [31:0] total_time;
reg [31:0] final_time;

always @(posedge clk) begin
	if (!reset) begin
		state        <= LOAD_INIT;
		spin_count   <= 0;
		roto_num     <= 8'd0;
		energy_state <= 1'b0;
		finished     <= 1'b0;

		rd_addr      <= 0;
		rd_req       <= 1'b0;
		rd_req_init  <= 1'b0;
		acc_clear    <= 1'b0;
		mult_start   <= 1'b0;

		angle_addr   <= 2'd0;
		gamma_spin   <= 32'sd0;
		beta_spin    <= 32'sd0;
		energy_diff  <= 0;
		total_energy <= 0;
		led          <= 8'd0;

		total_time   <= 32'd0;
		final_time   <= 32'd0;
	end else begin
		rd_req      <= 1'b0;
		rd_req_init <= 1'b0;
		acc_clear   <= 1'b0;
		mult_start  <= 1'b0;

		// angles for the next layer; angle_lut's output is registered and
		// is read many clocks after roto_num changes
		angle_addr  <= roto_num[1:0];

		if (!finished)
			total_time <= total_time + 32'd1;

		case (state)
			LOAD_INIT: begin
				rd_addr     <= spin_count[IDX_W-1:0];
				rd_req      <= 1'b1;
				rd_req_init <= 1'b1;
				if (spin_count == N_SPINS - 1) begin
					spin_count <= 0;
					state      <= WAIT_WRITES;
				end else begin
					spin_count <= spin_count + 1'b1;
				end
			end

			WAIT_WRITES: begin
				// all spins written and their z^2 added
				if (wr_count == N_SPINS && z_sq_valid == 2'b00) begin
					mult_start <= 1'b1;
					gamma_spin <= gamma;
					beta_spin  <= beta;
					state      <= MULTIPLY;
				end
			end

			MULTIPLY: begin
				if (!mult_start && !s_sq_busy && !gamma_s_busy) begin
					energy_state <= 1'b0;
					state        <= CALC_ENERGY;
				end
			end

			CALC_ENERGY: begin
				if (!energy_state) begin
					energy_diff  <= s_sq - q_acc;
					energy_state <= 1'b1;
				end else begin
					total_energy <= energy_diff >>> 16;
					led          <= led_now;
					if (roto_num == N_LAYERS) begin
						state <= FINISHED;
					end else begin
						acc_clear <= 1'b1;
						state     <= ISSUE_SPINS;
					end
				end
			end

			ISSUE_SPINS: begin
				rd_addr <= spin_count[IDX_W-1:0];
				rd_req  <= 1'b1;
				if (spin_count == N_SPINS - 1) begin
					spin_count <= 0;
					roto_num   <= roto_num + 8'd1;
					state      <= WAIT_WRITES;
				end else begin
					spin_count <= spin_count + 1'b1;
				end
			end

			FINISHED: begin
				finished   <= 1'b1;
				final_time <= total_time;
			end

			default: state <= LOAD_INIT;
		endcase
	end
end

endmodule
