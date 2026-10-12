module VIRAL_n_spin_direct #(
	parameter N_SPINS   = 3,
	parameter N_LAYERS  = 2,
	parameter INIT_FILE = "spin_init_3.hex"
)(
	input clk,
	input reset,
	output reg [7:0] led
);

// Direct generalization of VIRAL_three_spin to N spins (N_SPINS >= 2), used
// only to measure how the original architecture scales (see README.md).
// Same structure as VIRAL_three_spin:
//   - one VIRAL_rotation_2 (iterative CORDIC) per spin, all running in parallel
//   - every spin sums the z of all the other spins: N*(N-1) additions
//   - one multiplier and one 32-bit register per pair for the energy,
//     N*(N-1)/2 of each, then all pair terms are added in a single clock
// The field is exact (no halving), so the final spins match VIRAL_n_spin
// bit for bit. As in VIRAL_three_spin, the initial state is only loaded at
// power-up.

localparam N_PAIRS = N_SPINS * (N_SPINS - 1) / 2;
localparam SUM_W   = 16 + $clog2(N_SPINS);
localparam E_W     = 32 + $clog2(N_PAIRS + 1);

// spin states {x, y, z}
reg [47:0] spin_state [0:N_SPINS-1];

initial $readmemh(INIT_FILE, spin_state);

wire signed [15:0] gamma;
wire signed [31:0] beta;

reg [1:0] angle_addr;

angle_lut angle_lut_1(
	.clk			(clk),
	.address		(angle_addr),

	.alpha_out	(gamma),
	.beta_out	(beta)
);

reg signed [15:0] gamma_spin;
reg signed [31:0] beta_spin;

reg signed [SUM_W-1:0] s_z_sum  [0:N_SPINS-1];
reg signed [31:0]      gamma_hz [0:N_SPINS-1];
reg signed [31:0]      e_pair   [0:N_PAIRS-1];

reg start_rotation;

wire [16*N_SPINS-1:0] x_final;
wire [16*N_SPINS-1:0] y_final;
wire [16*N_SPINS-1:0] z_final;
wire [N_SPINS-1:0]    spin_finished;

genvar g;
generate
	for (g = 0; g < N_SPINS; g = g + 1) begin : spin

		wire [47:0] state_now = spin_state[g];

		VIRAL_rotation_2 VIRAL_rotation(
			.clk					(clk),
			.reset				(reset),

			.x_0					(state_now[47:32]),
			.y_0					(state_now[31:16]),
			.z_0					(state_now[15:0]),

			.local_z_hz_gamma (gamma_hz[g]),
			.global_x_beta		(beta_spin),

			.start_rotation	(start_rotation),

			.x_f					(x_final[16*g +: 16]),
			.y_f					(y_final[16*g +: 16]),
			.z_f					(z_final[16*g +: 16]),

			.finished			(spin_finished[g])
		);

	end
endgenerate


localparam GET_ANGLES  = 3'd0;
localparam CALC_HZ     = 3'd1;
localparam START_ROTO  = 3'd2;
localparam WAIT_ROTO   = 3'd3;
localparam CALC_ENERGY = 3'd4;

reg [2:0] state;
reg [1:0] angle_state;
reg [7:0] roto_num;
reg [N_SPINS-1:0] spin_done;
reg sums_taken;
reg energy_sum;

reg signed [E_W-1:0] total_energy;
reg [31:0] total_time;
reg [31:0] final_time;

integer i, j;
reg signed [SUM_W-1:0]    sum_tmp;
reg signed [SUM_W+15:0]   prod_tmp;
reg signed [E_W-1:0]      energy_tmp;

always @(posedge clk) begin
	if (!reset) begin
		state          <= GET_ANGLES;
		angle_addr     <= 2'd0;
		angle_state    <= 2'd0;
		roto_num       <= 8'd0;
		spin_done      <= 0;
		sums_taken     <= 1'b0;
		energy_sum     <= 1'b0;
		start_rotation <= 1'b0;
		gamma_spin     <= 16'sd0;
		beta_spin      <= 32'sd0;
		total_energy   <= 0;
		total_time     <= 32'd0;
		final_time     <= 32'd0;
	end else begin
		start_rotation <= 1'b0;
		case (state)
			GET_ANGLES: begin
				total_time <= total_time + 32'd1;
				if (angle_state < 2) begin
					angle_addr  <= roto_num[1:0];
					angle_state <= angle_state + 2'd1;
				end else begin
					gamma_spin  <= gamma;
					beta_spin   <= beta;
					state       <= CALC_HZ;
					angle_state <= 2'd0;
					roto_num    <= roto_num + 8'd1;
				end
			end

			CALC_HZ: begin
				total_time <= total_time + 32'd1;
				if (!sums_taken) begin
					// every spin sums the z of all the others
					for (i = 0; i < N_SPINS; i = i + 1) begin
						sum_tmp = 0;
						for (j = 0; j < N_SPINS; j = j + 1)
							if (j != i)
								sum_tmp = sum_tmp + $signed(spin_state[j][15:0]);
						s_z_sum[i] <= sum_tmp;
					end
					sums_taken <= 1'b1;
				end else begin
					for (i = 0; i < N_SPINS; i = i + 1) begin
						prod_tmp    = gamma_spin * s_z_sum[i];
						gamma_hz[i] <= {prod_tmp[30:0], 1'b0};
					end
					sums_taken <= 1'b0;
					state      <= START_ROTO;
				end
			end

			START_ROTO: begin
				total_time     <= total_time + 32'd1;
				start_rotation <= 1'b1;
				spin_done      <= 0;
				state          <= WAIT_ROTO;
			end

			WAIT_ROTO: begin
				total_time <= total_time + 32'd1;
				spin_done  <= spin_done | spin_finished;
				if (&spin_done) begin
					for (i = 0; i < N_SPINS; i = i + 1)
						spin_state[i] <= {x_final[16*i +: 16], y_final[16*i +: 16], z_final[16*i +: 16]};
					spin_done <= 0;
					if (roto_num == N_LAYERS)
						state <= CALC_ENERGY;
					else
						state <= GET_ANGLES;
				end
			end

			CALC_ENERGY: begin
				if (!energy_sum) begin
					total_time <= total_time + 32'd1;
					// one multiplier per pair
					for (i = 0; i < N_SPINS; i = i + 1)
						for (j = i + 1; j < N_SPINS; j = j + 1)
							e_pair[i*N_SPINS - i*(i+1)/2 + j - i - 1] <=
								($signed(spin_state[i][15:0]) * $signed(spin_state[j][15:0])) >>> 15;
					energy_sum <= 1'b1;
				end else begin
					// all pair terms added in one clock
					energy_tmp = 0;
					for (i = 0; i < N_PAIRS; i = i + 1)
						energy_tmp = energy_tmp + e_pair[i];
					final_time   <= total_time;
					total_energy <= energy_tmp;
					led          <= total_energy[15:8];
				end
			end

			default: state <= GET_ANGLES;
		endcase
	end
end

endmodule
