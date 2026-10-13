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
//   1. rotate spin i about z by gamma * h_i, where h_i = sum of z_j over j != i
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
// Logic is roughly constant in N_SPINS. Memory is 2 x 48 bits per spin.
// Loading the initial state takes N_SPINS + 8 clocks, each layer N_SPINS + 45.
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

wire signed [15:0] ram_x = ram_q[47:32];
wire signed [15:0] ram_y = ram_q[31:16];
wire signed [15:0] ram_z = ram_q[15:0];
wire signed [15:0] wr_z  = wr_data[15:0];


// ================================================================
// ANGLE LUT
// ================================================================

reg [1:0] angle_addr;

wire signed [15:0] gamma;
wire signed [31:0] beta;

reg signed [15:0] gamma_spin;
reg signed [31:0] beta_spin;

angle_lut angle_lut_1(
	.clk			(clk),
	.address		(angle_addr),

	.alpha_out	(gamma),
	.beta_out	(beta)
);


// ================================================================
// SHARED ROTATION PIPELINE
// ================================================================

reg                   fld_valid;
reg [IDX_W-1:0]       fld_idx;
reg signed [15:0]     fld_x;
reg signed [15:0]     fld_y;
reg signed [15:0]     fld_z;
reg signed [SUM_W+15:0] gamma_h;

// gamma * h_i as a 32-bit angle, same scaling as gamma_hz in VIRAL_three_spin
wire signed [31:0] gamma_hz = {gamma_h[30:0], 1'b0};

wire                  rot_valid;
wire [IDX_W-1:0]      rot_idx;
wire signed [15:0]    x_final;
wire signed [15:0]    y_final;
wire signed [15:0]    z_final;

VIRAL_rotation_pipe #(.TAG_WIDTH(IDX_W)) VIRAL_rotation(
	.clk					(clk),
	.reset				(reset),

	.in_valid			(fld_valid),
	.in_tag				(fld_idx),

	.x_0					(fld_x),
	.y_0					(fld_y),
	.z_0					(fld_z),

	.local_z_hz_gamma (gamma_hz),
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
// read spin -> h_i = S - z_i -> gamma * h_i -> rotation -> write back
// Initial states read from init_rom are written straight to spin_mem.
// ================================================================

reg rd_req;						// set by the state machine with rd_addr
reg rd_req_init;				// 1: copy from init_rom, 0: rotate from spin_mem
reg rd_valid;
reg rd_init;
reg [IDX_W-1:0] rd_idx;

reg                   h_valid;
reg [IDX_W-1:0]       h_idx;
reg signed [15:0]     h_x;
reg signed [15:0]     h_y;
reg signed [15:0]     h_z;
reg signed [SUM_W-1:0] h_field;

reg signed [SUM_W-1:0] s_layer;	// sum of z at the start of the layer

always @(posedge clk) begin
	if (!reset) begin
		rd_valid  <= 1'b0;
		h_valid   <= 1'b0;
		fld_valid <= 1'b0;
		wr_en     <= 1'b0;
	end else begin
		// memory output is valid one clock after the read
		rd_valid <= rd_req;
		rd_init  <= rd_req_init;
		rd_idx   <= rd_addr;

		// local field
		h_valid <= rd_valid && !rd_init;
		h_idx   <= rd_idx;
		h_x     <= ram_x;
		h_y     <= ram_y;
		h_z     <= ram_z;
		h_field <= s_layer - ram_z;

		// gamma * h_i
		fld_valid <= h_valid;
		fld_idx   <= h_idx;
		fld_x     <= h_x;
		fld_y     <= h_y;
		fld_z     <= h_z;
		gamma_h   <= gamma_spin * h_field;

		// write back initial state or rotated spin (never both at once)
		wr_en <= (rd_valid && rd_init) || rot_valid;
		if (rd_valid && rd_init) begin
			wr_addr <= rd_idx;
			wr_data <= rom_q;
		end else begin
			wr_addr <= rot_idx;
			wr_data <= {x_final, y_final, z_final};
		end
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
reg signed [31:0]      z_sq;
reg                    z_sq_valid;
reg [CNT_W-1:0]        wr_count;

always @(posedge clk) begin
	if (!reset || acc_clear) begin
		s_acc      <= 0;
		q_acc      <= 0;
		z_sq_valid <= 1'b0;
		wr_count   <= 0;
	end else begin
		if (wr_en) begin
			s_acc    <= s_acc + wr_z;
			z_sq     <= wr_z * wr_z;
			wr_count <= wr_count + 1'b1;
		end
		z_sq_valid <= wr_en;
		if (z_sq_valid)
			q_acc <= q_acc + z_sq;
	end
end


// ================================================================
// ENERGY
//
// sum_{i<j} z_i z_j = (S^2 - Q) / 2, in Q1.15: >>> 15 and >>> 1
// ================================================================

reg signed [E_W-1:0] s_sq;
reg signed [E_W-1:0] total_energy;

wire signed [E_W-1:0] energy_now = (s_sq - q_acc) >>> 16;
wire signed [E_W-1:0] energy_led = energy_now >>> LED_LSB;

wire [7:0] led_now =
	(energy_led >  127) ? 8'h7F :
	(energy_led < -128) ? 8'h80 :
	energy_led[7:0];


// ================================================================
// CONTROL
//
// 1. copy the initial state into spin_mem, summing S and Q
// 2. energy of the current state
// 3. get gamma, beta for the layer, latch S
// 4. stream all spins through the rotation pipeline
// 5. wait for every spin to be written back, then go to 2
// ================================================================

localparam LOAD_INIT   = 3'd0;
localparam WAIT_WRITES = 3'd1;
localparam CALC_ENERGY = 3'd2;
localparam GET_ANGLES  = 3'd3;
localparam ISSUE_SPINS = 3'd4;
localparam FINISHED    = 3'd5;

reg [2:0] state;
reg [CNT_W-1:0] spin_count;
reg [7:0] roto_num;
reg angle_state;
reg energy_state;
reg finished;

reg [31:0] total_time;
reg [31:0] final_time;

always @(posedge clk) begin
	if (!reset) begin
		state        <= LOAD_INIT;
		spin_count   <= 0;
		roto_num     <= 8'd0;
		angle_state  <= 1'b0;
		energy_state <= 1'b0;
		finished     <= 1'b0;

		rd_addr      <= 0;
		rd_req       <= 1'b0;
		rd_req_init  <= 1'b0;
		acc_clear    <= 1'b0;

		angle_addr   <= 2'd0;
		gamma_spin   <= 16'sd0;
		beta_spin    <= 32'sd0;
		s_layer      <= 0;
		s_sq         <= 0;
		total_energy <= 0;
		led          <= 8'd0;

		total_time   <= 32'd0;
		final_time   <= 32'd0;
	end else begin
		rd_req      <= 1'b0;
		rd_req_init <= 1'b0;
		acc_clear   <= 1'b0;

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
				if (wr_count == N_SPINS && !z_sq_valid) begin
					state        <= CALC_ENERGY;
					energy_state <= 1'b0;
				end
			end

			CALC_ENERGY: begin
				if (!energy_state) begin
					s_sq         <= s_acc * s_acc;
					energy_state <= 1'b1;
				end else begin
					total_energy <= energy_now;
					led          <= led_now;
					if (roto_num == N_LAYERS) begin
						state <= FINISHED;
					end else begin
						angle_addr  <= roto_num[1:0];
						angle_state <= 1'b0;
						state       <= GET_ANGLES;
					end
				end
			end

			GET_ANGLES: begin
				// angle_lut output is registered: valid one clock after
				// the new address reaches it
				if (!angle_state) begin
					angle_state <= 1'b1;
				end else begin
					gamma_spin <= gamma;
					beta_spin  <= beta;
					s_layer    <= s_acc;
					acc_clear  <= 1'b1;
					state      <= ISSUE_SPINS;
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
