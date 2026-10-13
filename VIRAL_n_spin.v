module VIRAL_n_spin #(
	parameter N_SPINS   = 3,
	parameter N_LAYERS  = 2,
	parameter INIT_FILE = "spin_init_3.hex",
	parameter WEIGHT_FILE = "",
	parameter LED_LSB   = 8
)(
	input clk,
	input reset,
	output reg [7:0] led
);

// Scalable version of VIRAL_three_spin.
//
// Same model: N_SPINS spins stored as vectors (x, y, z in Q1.15), each with
// a weight a_i, coupled all-to-all with J_ij = a_i * a_j. For each layer,
// using gamma and beta from angle_lut:
//   1. rotate spin i about z by gamma * h_i * 180 degrees,
//      where h_i = a_i * (sum of w_j over j != i) and w_j = a_j * z_j
//   2. rotate every spin about x by beta
// All spins are updated from the z values at the start of the layer.
// The energy sum_{i<j} w_i*w_j (Q1.15) is shown on the LEDs at the end.
//
// With weights this is mean-field QAOA for number partitioning: up to a
// constant, the cost is (sum_i a_i z_i)^2 / 2. Without WEIGHT_FILE every
// a_i is 1, which is the uniform model of VIRAL_three_spin.
//
// What makes it scale:
//   - spin states live in a memory (block RAM for large N), not per-spin registers
//   - one shared pipelined rotation unit (VIRAL_rotation_pipe) takes one spin per
//     clock, instead of one iterative rotation module per spin
//   - local field h_i = a_i * (S - w_i), with S = sum of all w: O(N) instead
//     of O(N^2)
//   - energy = (S^2 - sum w_i^2) / 2, also O(N), summed as results are written back
//   - field and energy widths grow with log2(N_SPINS), so nothing overflows
//
// Timing: every path is at most one adder or one DSP-sized multiply between
// registers, whatever N_SPINS is:
//   - gamma * h_i = a_i * (gamma * S - gamma * w_i). gamma * S is computed
//     once per layer, so the per-spin multiplies don't grow with N_SPINS:
//     a_i * z_i, gamma * w_i as two products, and a_i * (...) as four, each
//     small enough for one DSP multiplier
//   - S^2 and gamma * S are computed once per layer by shift-and-add
//     (serial_mult), one add per clock
//   - the spin memories have registered inputs and outputs (spin_memory)
//
// gamma is Q1.31 (angle_lut gamma_out). For many spins it has to be about
// 1/N_SPINS for the rotation angles to stay reasonable, which needs the extra
// bits. The z rotation angle is gamma * h_i rounded to the nearest angle LSB.
//
// WEIGHT_FILE: one line per spin, 4 hex digits, unsigned with 15 fractional
// bits (8000 = 1.0, FFFF just under 2). See gen_weights.py. w_i = a_i * z_i
// is rounded to Q1.15 (it can reach 2, so it is 17 bits). With unit weights
// w_i = z_i exactly, and results are the same as without weights.
//
// Logic is roughly constant in N_SPINS. Memory is 2 x 48 bits per spin, plus
// 16 with WEIGHT_FILE. Loading the initial state and computing its energy
// takes N_SPINS + SUM_W + 17 clocks; each layer takes N_SPINS + SUM_W + 63.
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
localparam SUM_W = 17 + $clog2(N_SPINS);						// holds any sum of N_SPINS w values (|w| < 2)
localparam E_W   = 2 * SUM_W;									// S^2 and energy

localparam MEM_LAT = 4;		// spin_memory read latency
localparam FLD_LAT = 11;	// memory output to rotation input
localparam ACC_LAT = 5;		// write-back to the last sum update

// gamma * (S - w_i) is Q.46 (Q1.31 times Q1.15), and a_i times it Q.61;
// the 32-bit angle is bits [61:30] of that, so the products are only needed
// mod 2^62. ROUND rounds the angle to the nearest LSB.
localparam GW_W = 62;
localparam [GW_W-1:0] ROUND = 62'd1 << 29;


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

wire [15:0]      wt_q;
reg  [15:0]      wr_wt;			// weight of the spin being written

spin_memory #(.N_SPINS(N_SPINS), .IDX_W(IDX_W), .INIT_FILE(INIT_FILE),
              .WEIGHT_FILE(WEIGHT_FILE)) spins(
	.clk			(clk),

	.rd_addr		(rd_addr),
	.rom_q		(rom_q),
	.ram_q		(ram_q),
	.wt_q			(wt_q),

	.wr_en		(wr_en),
	.wr_addr		(wr_addr),
	.wr_data		(wr_data)
);

wire signed [15:0] ram_z  = ram_q[15:0];
wire signed [15:0] wr_z   = wr_data[15:0];
wire signed [16:0] ram_wt = {1'b0, wt_q};		// weights as signed, for the multipliers
wire signed [16:0] wr_wt_s = {1'b0, wr_wt};


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
reg  [IDX_W+63:0]     fld_spin [0:FLD_LAT-1];	// {index, weight, x, y, z}
reg  [GW_W-1:0]       fld_angle;					// gamma * h_i, mod 2^62

wire [IDX_W+63:0]     fld_out = fld_spin[FLD_LAT-1];

wire                  rot_valid;
wire [IDX_W+15:0]     rot_tag;						// {index, weight}
wire [IDX_W-1:0]      rot_idx = rot_tag[IDX_W+15:16];
wire [15:0]           rot_wt  = rot_tag[15:0];
wire signed [15:0]    x_final;
wire signed [15:0]    y_final;
wire signed [15:0]    z_final;

VIRAL_rotation_pipe #(.TAG_WIDTH(IDX_W + 16)) VIRAL_rotation(
	.clk					(clk),
	.reset				(reset),

	.in_valid			(fld_valid[FLD_LAT-1]),
	.in_tag				(fld_out[IDX_W+63:48]),

	.x_0					(fld_out[47:32]),
	.y_0					(fld_out[31:16]),
	.z_0					(fld_out[15:0]),

	.local_z_hz_gamma (fld_angle[61:30]),
	.global_x_beta		(beta_spin),

	.out_valid			(rot_valid),
	.out_tag				(rot_tag),

	.x_f					(x_final),
	.y_f					(y_final),
	.z_f					(z_final)
);


// ================================================================
// DATAPATH
//
// read spin -> w_i = a_i * z_i -> gamma * w_i -> gamma * S - gamma * w_i
//   -> a_i * (gamma * S - gamma * w_i) -> rotation -> write back
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

wire [GW_W-1:0]  gamma_s;		// gamma * S for the layer, mod 2^62

// gamma * w_i as two products that each fit a DSP multiplier:
// gamma = gamma_hi * 2^16 + gamma_lo
wire signed [15:0] gamma_hi = gamma_spin[31:16];
wire signed [16:0] gamma_lo = {1'b0, gamma_spin[15:0]};

reg signed [32:0]  fld_wz_1, fld_wz_2;	// a_i * z_i, Q.30
reg signed [16:0]  fld_w;					// w_i, rounded to Q1.15
reg signed [32:0]  p_hi_1, p_hi_2;
reg signed [33:0]  p_lo_1, p_lo_2;
reg signed [GW_W-1:0] gamma_w;
reg [GW_W-1:0]     phi;						// gamma * (S - w_i), mod 2^62

// a_i * phi as four products, phi split into 18-bit pieces
wire [15:0]        phi_wt = fld_spin[6][63:48];	// a_i of the spin in phi
reg  [33:0]        pa_0_1, pa_1_1, pa_2_1, pa_0_2, pa_1_2, pa_2_2;
reg  [23:0]        pa_3_1, pa_3_2;
reg  [GW_W-1:0]    pa_01, pa_23;

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
	fld_spin[0] <= {rd_idx, wt_q, ram_q};
	for (k = 1; k < FLD_LAT; k = k + 1)
		fld_spin[k] <= fld_spin[k-1];

	// gamma * h_i = a_i * (gamma * S - gamma * w_i), rounded, mod 2^62
	fld_wz_1  <= ram_wt * ram_z;										// stage 1
	fld_wz_2  <= fld_wz_1;												// stage 2
	fld_w     <= (fld_wz_2 + 33'sd16384) >>> 15;					// stage 3
	p_hi_1    <= gamma_hi * fld_w;									// stage 4
	p_lo_1    <= gamma_lo * fld_w;
	p_hi_2    <= p_hi_1;												// stage 5
	p_lo_2    <= p_lo_1;
	gamma_w   <= (p_hi_2 <<< 16) + p_lo_2;						// stage 6
	phi       <= gamma_s - gamma_w;									// stage 7
	pa_0_1    <= phi_wt * phi[17:0];								// stage 8
	pa_1_1    <= phi_wt * phi[35:18];
	pa_2_1    <= phi_wt * phi[53:36];
	pa_3_1    <= phi_wt * phi[61:54];
	pa_0_2    <= pa_0_1;												// stage 9
	pa_1_2    <= pa_1_1;
	pa_2_2    <= pa_2_1;
	pa_3_2    <= pa_3_1;
	pa_01     <= pa_0_2 + (pa_1_2 << 18);							// stage 10
	pa_23     <= ((pa_2_2 << 36) + (pa_3_2 << 54)) | ROUND;		// (low 36 bits are 0)
	fld_angle <= pa_01 + pa_23;										// stage 11

	// write back initial state or rotated spin (never both at once)
	if (rd_valid && rd_init) begin
		wr_addr <= rd_idx;
		wr_data <= rom_q;
		wr_wt   <= wt_q;
	end else begin
		wr_addr <= rot_idx;
		wr_data <= {x_final, y_final, z_final};
		wr_wt   <= rot_wt;
	end
end


// ================================================================
// SUMS FOR THE NEXT FIELD AND THE ENERGY
//
// Every spin written to spin_mem is added to S = sum w and Q = sum w^2,
// with w = a * z rounded as in the field.
// ================================================================

reg                    acc_clear;
reg signed [SUM_W-1:0] s_acc;
reg signed [E_W-1:0]   q_acc;
reg signed [32:0]      acc_wz_1, acc_wz_2;
reg signed [16:0]      acc_w;
reg signed [33:0]      w_sq_1, w_sq_2;
reg [ACC_LAT-1:0]      acc_valid;
reg [CNT_W-1:0]        wr_count;

always @(posedge clk) begin
	if (!reset || acc_clear) begin
		s_acc     <= 0;
		q_acc     <= 0;
		acc_valid <= 0;
		wr_count  <= 0;
	end else begin
		if (wr_en)
			wr_count <= wr_count + 1'b1;
		acc_valid <= {acc_valid[ACC_LAT-2:0], wr_en};
		if (acc_valid[2])
			s_acc <= s_acc + acc_w;
		if (acc_valid[4])
			q_acc <= q_acc + w_sq_2;
	end
	acc_wz_1 <= wr_wt_s * wr_z;
	acc_wz_2 <= acc_wz_1;
	acc_w    <= (acc_wz_2 + 33'sd16384) >>> 15;
	w_sq_1   <= acc_w * acc_w;
	w_sq_2   <= w_sq_1;
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

serial_mult #(.A_W(32), .B_W(SUM_W), .P_W(GW_W)) gamma_times_s(
	.clk		(clk),
	.reset	(reset),
	.start	(mult_start),
	.a			(gamma),
	.b			(s_acc),
	.c			({GW_W{1'b0}}),
	.p			(gamma_s),
	.busy		(gamma_s_busy)
);


// ================================================================
// ENERGY
//
// sum_{i<j} w_i w_j = (S^2 - Q) / 2, in Q1.15: >>> 15 and >>> 1
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
				// all spins written and added to S and Q
				if (wr_count == N_SPINS && acc_valid == 0) begin
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
