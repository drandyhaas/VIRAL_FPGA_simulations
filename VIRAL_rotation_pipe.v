module VIRAL_rotation_pipe #(
	parameter TAG_WIDTH = 8
)(
	input clk,
	input reset,

	input wire                   in_valid,
	input wire [TAG_WIDTH-1:0]   in_tag,

	input wire signed [15:0]     x_0,
	input wire signed [15:0]     y_0,
	input wire signed [15:0]     z_0,

	input wire signed [31:0]     local_z_hz_gamma,
	input wire signed [31:0]     global_x_beta,

	output wire                  out_valid,
	output wire [TAG_WIDTH-1:0]  out_tag,

	output wire signed [15:0]    x_f,
	output wire signed [15:0]    y_f,
	output wire signed [15:0]    z_f
);

// Streaming version of VIRAL_rotation_2: the same two rotations
// (about z by local_z_hz_gamma, then about x by global_x_beta), built from
// two chained pipelined CORDICs, so it accepts a new spin every clock.
//
// Latency: 34 clocks. in_tag (e.g. the spin index) comes out with the result.
// global_x_beta is used 17 clocks after a spin enters, so it must be held
// constant while spins are in flight (it is constant within a layer).

wire                    z_done;
wire [TAG_WIDTH+15:0]   z_tag;		// {in_tag, z_0}

wire signed [15:0] x_z_out;
wire signed [15:0] y_z_out;

wire [TAG_WIDTH+15:0]   x_tag;		// {in_tag, x after z rotation}


// rotation about z: (x, y) by local_z_hz_gamma, z rides along in the tag
cordic_pipelined #(.TAG_WIDTH(TAG_WIDTH + 16)) z_rotation (
	.clock		(clk),
	.reset_in	(reset),

	.in_valid	(in_valid),
	.in_tag		({in_tag, z_0}),

	.angle		(local_z_hz_gamma),
	.Xin			(x_0),
	.Yin			(y_0),

	.out_valid	(z_done),
	.out_tag		(z_tag),

	.Xout			(x_z_out),
	.Yout			(y_z_out)
);


// rotation about x: (y, z) by global_x_beta, final x rides along in the tag
cordic_pipelined #(.TAG_WIDTH(TAG_WIDTH + 16)) x_rotation (
	.clock		(clk),
	.reset_in	(reset),

	.in_valid	(z_done),
	.in_tag		({z_tag[TAG_WIDTH+15:16], x_z_out}),

	.angle		(global_x_beta),
	.Xin			(y_z_out),
	.Yin			(z_tag[15:0]),

	.out_valid	(out_valid),
	.out_tag		(x_tag),

	.Xout			(y_f),
	.Yout			(z_f)
);

assign out_tag = x_tag[TAG_WIDTH+15:16];
assign x_f     = x_tag[15:0];

endmodule
