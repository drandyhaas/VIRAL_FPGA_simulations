module VIRAL_three_spin(
	input clk,
	input reset,
	output reg [7:0] led
);

// initialize two spins, get gamma, beta from lut, calculate gamma hz, send inputs to rotation module and get output 



// registers for input and output spin coordinates
reg signed [15:0] x_0_1 = 16'sh5A82;
reg signed [15:0] y_0_1 = 16'sh0000;
reg signed [15:0] z_0_1 = 16'sh5A82;

reg signed [15:0] x_0_2 = 16'sh5A82;
reg signed [15:0] y_0_2 = 16'sh0000;
reg signed [15:0] z_0_2 = 16'shA57E;

reg signed [15:0] x_0_3 = 16'sh0000;
reg signed [15:0] y_0_3 = 16'sh0000;
reg signed [15:0] z_0_3 = 16'sh0000;


reg signed [15:0] x_f_1;
reg signed [15:0] y_f_1;
reg signed [15:0] z_f_1;

reg signed [15:0] x_f_2;
reg signed [15:0] y_f_2;
reg signed [15:0] z_f_2;

reg signed [15:0] x_f_3;
reg signed [15:0] y_f_3;
reg signed [15:0] z_f_3;


wire signed [15:0] x_1_final;
wire signed [15:0] y_1_final;
wire signed [15:0] z_1_final;

wire signed [15:0] x_2_final;
wire signed [15:0] y_2_final;
wire signed [15:0] z_2_final;

wire signed [15:0] x_3_final;
wire signed [15:0] y_3_final;
wire signed [15:0] z_3_final;


wire spin_1_finished;
wire spin_2_finished;
wire spin_3_finished;

wire signed [15:0] gamma;
wire signed [31:0] beta;

reg signed [31:0] gamma_hz_1;
reg signed [31:0] gamma_hz_2;
reg signed [31:0] gamma_hz_3;

reg signed [15:0] gamma_spin;
reg signed [31:0] beta_spin;

reg signed [15:0] s_z_1_sum;
reg signed [15:0] s_z_2_sum;
reg signed [15:0] s_z_3_sum;

reg [1:0] angle_addr;

reg signed [31:0] e_12;
reg signed [31:0] e_13;
reg signed [31:0] e_23;
reg signed [31:0] total_energy;

reg [7:0] total_time = 7'd0;
reg [7:0] final_time = 7'd0;
//instantiate modules, one angle lut to get gamma, beta. Two spin modules to execute each rotation 
angle_lut angle_lut_1(

	.clk			(clk),
	.address		(angle_addr),
	
	.alpha_out	(gamma),
	.beta_out	(beta)
);



VIRAL_rotation_2 VIRAL_rotation_spin_1(
	.clk					(clk),
	.reset				(reset),
	
	.x_0					(x_0_1),
	.y_0					(y_0_1),
	.z_0					(z_0_1),
	
	.local_z_hz_gamma (gamma_hz_1),
	.global_x_beta		(beta_spin),
	
	.start_rotation	(start_rotation_1),
	
	.x_f					(x_1_final),
	.y_f					(y_1_final),
	.z_f					(z_1_final),
	
	.finished 			(spin_1_finished)
	
	);
	
VIRAL_rotation_2 VIRAL_rotation_spin_2(
	.clk					(clk),
	.reset				(reset),
	
	.x_0					(x_0_2),
	.y_0					(y_0_2),
	.z_0					(z_0_2),
	
	.local_z_hz_gamma (gamma_hz_2),
	.global_x_beta		(beta_spin),
	
	.start_rotation	(start_rotation_2),
	
	.x_f					(x_2_final),
	.y_f					(y_2_final),
	.z_f					(z_2_final),
	
	.finished			(spin_2_finished)
	
	);

VIRAL_rotation_2 VIRAL_rotation_spin_3(
	.clk					(clk),
	.reset				(reset),
	
	.x_0					(x_0_3),
	.y_0					(y_0_3),
	.z_0					(z_0_3),
	
	.local_z_hz_gamma (gamma_hz_3),
	.global_x_beta		(beta_spin),
	
	.start_rotation	(start_rotation_3),
	
	.x_f					(x_3_final),
	.y_f					(y_3_final),
	.z_f					(z_3_final),
	
	.finished			(spin_3_finished)
	
	);

	
//rotation steps, 1: get new gamma, beta. 2. calculate h_z_i for spin one and two. 3. start rotations with start pulse
//4. wait for rotations to complete with sending of finshed pulse 5. read out final values 6. give selected output to led 
reg start_rotation_1 = 1'b0;
reg start_rotation_2 = 1'b0;
reg start_rotation_3 = 1'b0;

reg [3:0] state = 4'd0;
reg [1:0] angle_state = 2'd0;
reg [1:0] roto_num = 2'd0;
reg [1:0] total_roto = 2'd2;
reg spin_1_state = 1'b0;
reg spin_2_state = 1'b0;
reg spin_3_state = 1'b0;
reg sums_taken = 1'b0;
reg energy_sum = 1'b0;

localparam GET_ANGLES = 4'd0;
localparam CALC_HZ = 4'd1;
localparam START_ROTO = 4'd2;
localparam WAIT_ROTO = 4'd3;
localparam CALC_ENERGY = 4'd4; 

always @(posedge clk) begin
	if (!reset) begin
		state <= GET_ANGLES;
		angle_addr   <= 2'd0;
		angle_state  <= 1'b0;
		roto_num     <= 2'd0;

		spin_1_state <= 1'b0;
		spin_2_state <= 1'b0;

		gamma_spin   <= 16'sd0;
		beta_spin    <= 32'sd0;

		gamma_hz_1   <= 32'sd0;
		gamma_hz_2   <= 32'sd0;
		
		start_rotation_1 <= 1'b0;
		start_rotation_2 <= 1'b0;
		total_energy <= 32'sd0;
		total_time <= 7'd0;
		final_time <= 7'd0;
		sums_taken <= 1'b0;
		energy_sum <= 1'b0;
		spin_3_state <= 1'b0;
		start_rotation_3 <= 1'b0;

		gamma_hz_3 <= 32'sd0;

		e_12 <= 32'sd0;
		e_13 <= 32'sd0;
		e_23 <= 32'sd0;
		
	end else begin
		start_rotation_1 <= 1'b0;
		start_rotation_2 <= 1'b0;
		start_rotation_3 <= 1'b0;
		case (state)
			GET_ANGLES: begin
				total_time <= total_time + 7'd1;
				if (angle_state < 2)begin
					angle_addr <= roto_num;
					angle_state <= angle_state + 2'd1;
				end else if (angle_state == 2) begin
					gamma_spin <= gamma;
					beta_spin <= beta;
					state <= CALC_HZ;
					angle_state <= 1'b0;
					roto_num <= roto_num +2'd1;
				end
			end
			
			CALC_HZ: begin
				total_time <= total_time +7'd1;
				if(!sums_taken)begin
					s_z_1_sum <= ($signed({z_0_2[15], z_0_2}) + $signed({z_0_3[15], z_0_3})) >>> 1;
					s_z_2_sum <= ($signed({z_0_1[15], z_0_1}) + $signed({z_0_3[15], z_0_3})) >>> 1;
					s_z_3_sum <= ($signed({z_0_2[15], z_0_2}) + $signed({z_0_1[15], z_0_1})) >>> 1;
					sums_taken <= 1'b1;
				end else if (sums_taken) begin
				
					gamma_hz_1 <= ($signed(gamma_spin) * $signed(s_z_1_sum)) <<< 2;
				   gamma_hz_2 <= ($signed(gamma_spin) * $signed(s_z_2_sum)) <<< 2;
					gamma_hz_3 <= ($signed(gamma_spin) * $signed(s_z_3_sum)) <<< 2;
					sums_taken <= 1'b0;
					state <= START_ROTO;
				end
			end
			
			START_ROTO: begin
				total_time <= total_time + 7'd1;
				start_rotation_1<= 1'b1;
				start_rotation_2<= 1'b1;
				start_rotation_3 <= 1'b1;
				spin_1_state <= 1'b0;
				spin_2_state <= 1'b0;
				spin_3_state <= 1'b0;
				state <= WAIT_ROTO;
			end
			
			WAIT_ROTO: begin
				total_time <= total_time + 7'd1;
				if (spin_1_finished)begin
					spin_1_state <= 1'b1;
				end
				if (spin_2_finished)begin
					spin_2_state <= 1'b1;
				end
				if (spin_3_finished)begin
					spin_3_state <= 1'b1;
				end
				if (spin_1_state && spin_2_state && spin_3_state)begin
					x_f_1 <= x_1_final;
					y_f_1 <= y_1_final;
					z_f_1 <= z_1_final;
					
					x_f_2 <= x_2_final;
					y_f_2 <= y_2_final;
					z_f_2 <= z_2_final;
					
					x_f_3 <= x_3_final;
					y_f_3 <= y_3_final;
					z_f_3 <= z_3_final;
					
					spin_1_state <= 1'b0;
					spin_2_state <= 1'b0;
					spin_3_state <= 1'b0;
					
					if (roto_num == total_roto) begin
						state<= CALC_ENERGY;
					end else if (roto_num < total_roto) begin
						state <= GET_ANGLES;
						x_0_1 <= x_1_final;
						y_0_1 <= y_1_final;
						z_0_1 <= z_1_final;
						
						x_0_2 <= x_2_final;
						y_0_2 <= y_2_final;
						z_0_2 <= z_2_final;
						
						x_0_3 <= x_3_final;
						y_0_3 <= y_3_final;
						z_0_3 <= z_3_final;
					end
				end
			end
			
			CALC_ENERGY: begin
				if (!energy_sum)begin
					total_time <= total_time + 7'd1;
					e_12 <= ($signed(z_f_1) * $signed(z_f_2)) >>> 15;
					e_13 <= ($signed(z_f_1) * $signed(z_f_3)) >>> 15;
					e_23 <= ($signed(z_f_3) * $signed(z_f_2)) >>> 15;
					energy_sum <= 1'b1;
				end else if (energy_sum)begin
					final_time <= total_time;
					total_energy <= e_12 + e_13 + e_23;
					led <= total_energy[15:8];
				end
			end
		
		endcase 
	end



end




endmodule