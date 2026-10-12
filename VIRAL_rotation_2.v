module VIRAL_rotation_2(
	input clk,
	input reset,
	
	input wire signed [15:0] x_0,
	input wire signed [15:0] y_0,
	input wire signed [15:0] z_0,
	
	input wire signed [31:0] local_z_hz_gamma,
	input wire signed [31:0] global_x_beta,
	
	input start_rotation,
	
	output reg signed [15:0] x_f,
	output reg signed [15:0] y_f,
	output reg signed [15:0] z_f,
	
	output reg finished
);

//use cartesian vector rotations, no I Q, start by doing one rotation 



parameter norm = 16'sh7FFF;




wire done;
wire busy;



reg start_pulse =1'b0;


//
//wire signed [15:0] x_z_out;
//wire signed [15:0] y_z_out;
//
//wire signed [15:0] y_x_out;
//wire signed [15:0] z_x_out;

wire signed [15:0] x_out;
wire signed [15:0] y_out;

reg signed [15:0] y_interm;

reg [7:0] time_count = 0;




cordic_iterative rotation (
	.clock		(clk),
	.reset_in	(reset),
	.start		(start_pulse),
	
	.angle 		(angle_in),
	.Xin			(x_start),
	.Yin			(y_start),
	
	.Xout			(x_out),
	.Yout			(y_out),
	
	.busy			(busy),
	.done			(done)
);


//cordic_iterative x_rotation (
//	.clock		(clk),
//	.reset_in	(reset),
//	.start		(x_start_pulse),
//	
//	.angle 		(global_x_beta_start),
//	.Xin			(y_interm),
//	.Yin			(z_start),
//	
//	.Xout			(y_x_out),
//	.Yout			(z_x_out),
//	
//	.busy			(x_busy),
//	.done			(x_done)
//);


localparam IDLE = 3'd0;
localparam START_Z = 3'd1;
localparam WAIT_Z = 3'd2;
localparam START_X = 3'd3;
localparam WAIT_X = 3'd4;
localparam FINISHED = 3'd5;

reg [2:0] state = IDLE;

reg signed [15:0] x_start;
reg signed [15:0] y_start;


//reg signed [31:0] local_z_hz_gamma_start;
//reg signed [31:0] global_x_beta_start;
reg signed [31:0] angle_in;
reg load_x = 1'b0;
 
always @(posedge clk) begin
	if (!reset) begin
		time_count <= 0;
		finished <= 1'b0;
		
		start_pulse <= 1'b0;
		
		x_start <= 16'sd0;
		y_start <= 16'sd0;
		//z_start <= 16'sd0;
		load_x <= 1'b0;
		x_f <= 16'sd0;
      y_f <= 16'sd0;
      z_f <= 16'sd0;
      y_interm <= 16'sd0;

		//local_z_hz_gamma_start <= 32'sd0;
		//global_x_beta_start <= 32'sd0;
		angle_in <= 32'sd0;
		state <= IDLE;
	end else begin
		start_pulse <= 1'b0;
		finished <= 1'b0;
		case (state)
			IDLE: begin
				if (start_rotation)begin
					state <= START_Z;
					time_count <= 0;
					x_start <= x_0;
					y_start <= y_0;

					angle_in <= local_z_hz_gamma;
					//global_x_beta_start <= global_x_beta;
				end
			end
			START_Z: begin
				start_pulse <= 1'b1;
				time_count <= time_count +7'd1;
				state <= WAIT_Z;
			end
			
			WAIT_Z: begin
				time_count <= time_count +7'd1;
				if (done) begin
					state <= START_X;
					x_f <= x_out;
					y_interm <= y_out;
				end
			end
			
			START_X: begin
				if (!load_x)begin
				//start_pulse <= 1'b1;
					x_start <= y_interm;
					angle_in <= global_x_beta;
					time_count <= time_count +7'd1;
					y_start <= z_0;
					load_x <= 1'b1;
				end else if (load_x)begin
					state <= WAIT_X;
					time_count <= time_count + 7'd1;
					start_pulse <= 1'b1;
					load_x <= 1'b0;
				end
			end
			
			WAIT_X: begin
				time_count <= time_count +7'd1;
				if (done) begin
					y_f <= x_out;
					z_f <= y_out;
					state <= FINISHED;
				end
			end
			
			FINISHED: begin
				finished <= 1'b1;
				state <= IDLE;
			end
		endcase
	end
end

endmodule