`timescale 1 ns/100 ps

// Scale test for VIRAL_n_spin.
//
// Runs the design with N_SPINS spins and checks:
//   1. final spins against a bit-exact reference built from N_SPINS copies of
//      the original VIRAL_rotation_2 (iterative CORDIC), stepped layer by layer
//   2. energy against sum_{i<j} z_i*z_j >>> 15, recomputed pair by pair,
//      and the LEDs against that energy >>> LED_LSB, saturated to 8 bits
//   3. final spins against a floating-point model of the same dynamics
//   4. that a reset reloads the initial state (a second run gives the same result)

module tb_VIRAL_n_spin;

parameter N_SPINS   = 10;
parameter N_LAYERS  = 2;
parameter INIT_FILE = "build/spin_init_10.hex";
parameter LED_LSB   = 8;
parameter FLOAT_TOL = 0.01;

localparam PI = 3.141592653589793;

reg clk = 1'b0;
reg reset = 1'b0;

always #10 clk = ~clk;

wire [7:0] led;

VIRAL_n_spin #(.N_SPINS(N_SPINS), .N_LAYERS(N_LAYERS), .INIT_FILE(INIT_FILE), .LED_LSB(LED_LSB))
	dut (.clk(clk), .reset(reset), .led(led));


// ---------------------------------------------------------------
// gamma, beta per layer, read from a separate angle_lut
// ---------------------------------------------------------------

reg [1:0] lut_addr = 2'd0;
wire signed [15:0] lut_gamma;
wire signed [31:0] lut_beta;

angle_lut lut (.clk(clk), .address(lut_addr), .alpha_out(lut_gamma), .beta_out(lut_beta));

reg signed [15:0] gamma_tab [0:3];
reg signed [31:0] beta_tab  [0:3];


// ---------------------------------------------------------------
// bit-exact reference: one original VIRAL_rotation_2 per spin
// ---------------------------------------------------------------

reg [47:0] init_state [0:N_SPINS-1];

reg signed [15:0] ref_x [0:N_SPINS-1];
reg signed [15:0] ref_y [0:N_SPINS-1];
reg signed [15:0] ref_z [0:N_SPINS-1];

reg [16*N_SPINS-1:0] ref_x_in;
reg [16*N_SPINS-1:0] ref_y_in;
reg [16*N_SPINS-1:0] ref_z_in;
reg [32*N_SPINS-1:0] ref_angle_in;
reg signed [31:0]    ref_beta;
reg                  ref_start = 1'b0;

wire [16*N_SPINS-1:0] ref_x_out;
wire [16*N_SPINS-1:0] ref_y_out;
wire [16*N_SPINS-1:0] ref_z_out;
wire [N_SPINS-1:0]    ref_done;

genvar g;
generate
	for (g = 0; g < N_SPINS; g = g + 1) begin : ref_spin
		VIRAL_rotation_2 rotation (
			.clk					(clk),
			.reset				(reset),
			.x_0					(ref_x_in[16*g +: 16]),
			.y_0					(ref_y_in[16*g +: 16]),
			.z_0					(ref_z_in[16*g +: 16]),
			.local_z_hz_gamma (ref_angle_in[32*g +: 32]),
			.global_x_beta		(ref_beta),
			.start_rotation	(ref_start),
			.x_f					(ref_x_out[16*g +: 16]),
			.y_f					(ref_y_out[16*g +: 16]),
			.z_f					(ref_z_out[16*g +: 16]),
			.finished			(ref_done[g])
		);
	end
endgenerate


// ---------------------------------------------------------------
// floating-point model
// ---------------------------------------------------------------

real fx [0:N_SPINS-1];
real fy [0:N_SPINS-1];
real fz [0:N_SPINS-1];


integer i, j, layer;
integer errors = 0;

reg signed [63:0] s_sum;
reg signed [63:0] h;
reg signed [63:0] prod;
reg signed [63:0] pair_sum;
reg signed [63:0] led_value;
reg [7:0]         led_want;

real fs, fg, fb, theta, x1, y1, err, max_err;


task ref_layer;
	input integer k;
	begin
		s_sum = 0;
		for (i = 0; i < N_SPINS; i = i + 1)
			s_sum = s_sum + ref_z[i];

		for (i = 0; i < N_SPINS; i = i + 1) begin
			h    = s_sum - ref_z[i];
			prod = gamma_tab[k] * h;
			ref_angle_in[32*i +: 32] = {prod[30:0], 1'b0};
			ref_x_in[16*i +: 16]     = ref_x[i];
			ref_y_in[16*i +: 16]     = ref_y[i];
			ref_z_in[16*i +: 16]     = ref_z[i];
		end
		ref_beta = beta_tab[k];

		@(posedge clk) ref_start <= 1'b1;
		@(posedge clk) ref_start <= 1'b0;
		@(posedge clk);
		while (!ref_done[0]) @(posedge clk);

		if (ref_done !== {N_SPINS{1'b1}}) begin
			$display("  reference spins did not finish together");
			errors = errors + 1;
		end

		for (i = 0; i < N_SPINS; i = i + 1) begin
			ref_x[i] = ref_x_out[16*i +: 16];
			ref_y[i] = ref_y_out[16*i +: 16];
			ref_z[i] = ref_z_out[16*i +: 16];
		end
	end
endtask


task float_layer;
	input integer k;
	begin
		fg = gamma_tab[k] / 32768.0;
		fb = beta_tab[k] * 2.0 * PI / 4294967296.0;

		fs = 0.0;
		for (i = 0; i < N_SPINS; i = i + 1)
			fs = fs + fz[i];

		for (i = 0; i < N_SPINS; i = i + 1) begin
			theta = PI * fg * (fs - fz[i]);
			x1    = fx[i] * $cos(theta) - fy[i] * $sin(theta);
			y1    = fx[i] * $sin(theta) + fy[i] * $cos(theta);
			fx[i] = x1;
			fy[i] = y1 * $cos(fb) - fz[i] * $sin(fb);
			fz[i] = y1 * $sin(fb) + fz[i] * $cos(fb);
		end
	end
endtask


initial begin
	$readmemh(INIT_FILE, init_state);
	for (i = 0; i < N_SPINS; i = i + 1) begin
		ref_x[i] = init_state[i][47:32];
		ref_y[i] = init_state[i][31:16];
		ref_z[i] = init_state[i][15:0];
		fx[i] = ref_x[i] / 32768.0;
		fy[i] = ref_y[i] / 32768.0;
		fz[i] = ref_z[i] / 32768.0;
	end

	// read the angle table
	for (i = 0; i < 4; i = i + 1) begin
		@(posedge clk) lut_addr <= i;
		@(posedge clk);
		@(posedge clk);
		gamma_tab[i] = lut_gamma;
		beta_tab[i]  = lut_beta;
	end

	repeat (2) @(posedge clk);
	reset = 1'b1;

	// run the reference and the design side by side
	fork
		for (layer = 0; layer < N_LAYERS; layer = layer + 1)
			ref_layer(layer);
		wait (dut.finished);
	join
	repeat (2) @(posedge clk);

	for (layer = 0; layer < N_LAYERS; layer = layer + 1)
		float_layer(layer);

	// 1. bit-exact against the original rotation modules
	for (i = 0; i < N_SPINS; i = i + 1) begin
		if (dut.spins.spin_mem[i] !== {ref_x[i], ref_y[i], ref_z[i]}) begin
			if (errors < 10)
				$display("  spin %0d: got %h, reference %h",
					i, dut.spins.spin_mem[i], {ref_x[i], ref_y[i], ref_z[i]});
			errors = errors + 1;
		end
	end

	// 2. energy, pair by pair
	pair_sum = 0;
	for (i = 0; i < N_SPINS; i = i + 1)
		for (j = i + 1; j < N_SPINS; j = j + 1)
			pair_sum = pair_sum + ref_z[i] * ref_z[j];
	if ($signed(dut.total_energy) !== (pair_sum >>> 15)) begin
		$display("  energy: got %0d, pairwise %0d", $signed(dut.total_energy), pair_sum >>> 15);
		errors = errors + 1;
	end

	led_value = (pair_sum >>> 15) >>> LED_LSB;
	if (led_value > 127)
		led_want = 8'h7F;
	else if (led_value < -128)
		led_want = 8'h80;
	else
		led_want = led_value[7:0];
	if (led !== led_want) begin
		$display("  led: got %b, expected %b", led, led_want);
		errors = errors + 1;
	end

	// 3. floating-point model
	max_err = 0.0;
	for (i = 0; i < N_SPINS; i = i + 1) begin
		err = ref_x[i] / 32768.0 - fx[i]; if (err < 0) err = -err; if (err > max_err) max_err = err;
		err = ref_y[i] / 32768.0 - fy[i]; if (err < 0) err = -err; if (err > max_err) max_err = err;
		err = ref_z[i] / 32768.0 - fz[i]; if (err < 0) err = -err; if (err > max_err) max_err = err;
	end
	if (max_err > FLOAT_TOL) begin
		$display("  float model: max error %f > %f", max_err, FLOAT_TOL);
		errors = errors + 1;
	end

	// 4. a reset reloads the initial state, so a second run gives the same result
	reset = 1'b0;
	repeat (3) @(posedge clk);
	reset = 1'b1;
	@(posedge clk);
	wait (dut.finished);
	repeat (2) @(posedge clk);
	for (i = 0; i < N_SPINS; i = i + 1) begin
		if (dut.spins.spin_mem[i] !== {ref_x[i], ref_y[i], ref_z[i]}) begin
			if (errors < 10)
				$display("  after reset, spin %0d: got %h, reference %h",
					i, dut.spins.spin_mem[i], {ref_x[i], ref_y[i], ref_z[i]});
			errors = errors + 1;
		end
	end

	$display("N_SPINS=%0d N_LAYERS=%0d: %0d clocks, energy %0d (%f), led %b, float model max error %f",
		N_SPINS, N_LAYERS, dut.final_time, $signed(dut.total_energy),
		$signed(dut.total_energy) / 32768.0, led, max_err);

	if (errors == 0)
		$display("PASS");
	else
		$display("FAIL: %0d errors", errors);
	$finish;
end

initial begin
	#100000000;
	$display("FAIL: timeout");
	$finish;
end

endmodule
