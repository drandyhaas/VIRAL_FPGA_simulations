`timescale 1 ns/100 ps

// Checks VIRAL_n_spin against the original fixed-size designs:
//   N_SPINS = 2, N_LAYERS = 1  vs  VIRAL_two_spin_2   (must match bit for bit)
//   N_SPINS = 3, N_LAYERS = 2  vs  VIRAL_three_spin   (within TOL_3 LSB)
//
// VIRAL_three_spin halves z_j + z_k before multiplying by gamma, which drops
// the LSB of the field when the sum is odd. VIRAL_n_spin keeps it, so the two
// can differ by a few LSB. (With that rounding added, they match exactly.)

module tb_compare_original;

parameter INIT_FILE_2 = "build/spin_init_2.hex";
parameter INIT_FILE_3 = "../spin_init_3.hex";
parameter TOL_3       = 4;

reg clk = 1'b0;
reg reset = 1'b0;

always #10 clk = ~clk;

wire [7:0] led_two_orig;
wire [7:0] led_two_new;
wire [7:0] led_three_orig;
wire [7:0] led_three_new;

VIRAL_two_spin_2 two_orig (.clk(clk), .reset(reset), .led(led_two_orig));

VIRAL_n_spin #(.N_SPINS(2), .N_LAYERS(1), .INIT_FILE(INIT_FILE_2))
	two_new (.clk(clk), .reset(reset), .led(led_two_new));

VIRAL_three_spin three_orig (.clk(clk), .reset(reset), .led(led_three_orig));

VIRAL_n_spin #(.N_SPINS(3), .N_LAYERS(2), .INIT_FILE(INIT_FILE_3))
	three_new (.clk(clk), .reset(reset), .led(led_three_new));


integer errors = 0;

integer differences = 0;

task check;
	input [8*32-1:0] name;
	input signed [63:0] got;
	input signed [63:0] want;
	input integer tol;
	begin
		if (got !== want) begin
			if (got - want > tol || want - got > tol) begin
				$display("  MISMATCH %0s: new %0d, original %0d", name, got, want);
				errors = errors + 1;
			end else begin
				$display("  within tolerance %0s: new %0d, original %0d", name, got, want);
				differences = differences + 1;
			end
		end
	end
endtask

task check_spin;
	input [8*32-1:0] name;
	input [47:0] got;
	input signed [15:0] want_x;
	input signed [15:0] want_y;
	input signed [15:0] want_z;
	input integer tol;
	begin
		$display("  %0s: (%0d, %0d, %0d)", name,
			$signed(got[47:32]), $signed(got[31:16]), $signed(got[15:0]));
		check({name, " x"}, $signed(got[47:32]), want_x, tol);
		check({name, " y"}, $signed(got[31:16]), want_y, tol);
		check({name, " z"}, $signed(got[15:0]),  want_z, tol);
	end
endtask


initial begin
	repeat (5) @(posedge clk);
	reset = 1'b1;

	// the originals have no done flag; they sit in CALC_ENERGY (state 4)
	wait (two_orig.state == 4 && three_orig.state == 4 &&
	      two_new.finished && three_new.finished);
	repeat (5) @(posedge clk);

	$display("two spins:");
	check_spin("spin 1", two_new.spins.spin_mem[0], two_orig.x_f_1, two_orig.y_f_1, two_orig.z_f_1, 0);
	check_spin("spin 2", two_new.spins.spin_mem[1], two_orig.x_f_2, two_orig.y_f_2, two_orig.z_f_2, 0);
	check("energy", two_new.total_energy, two_orig.total_energy, 0);
	check("led", led_two_new, led_two_orig, 0);
	$display("  energy %0d, led %b", two_new.total_energy, led_two_new);

	// the LEDs are not compared: a 1 LSB energy difference around 0 flips them
	// between 00000000 and 11111111 (the led mapping is checked in tb_VIRAL_n_spin)
	$display("three spins:");
	check_spin("spin 1", three_new.spins.spin_mem[0], three_orig.x_f_1, three_orig.y_f_1, three_orig.z_f_1, TOL_3);
	check_spin("spin 2", three_new.spins.spin_mem[1], three_orig.x_f_2, three_orig.y_f_2, three_orig.z_f_2, TOL_3);
	check_spin("spin 3", three_new.spins.spin_mem[2], three_orig.x_f_3, three_orig.y_f_3, three_orig.z_f_3, TOL_3);
	check("energy", three_new.total_energy, three_orig.total_energy, TOL_3);
	$display("  energy %0d (original %0d), led %b (original %b)",
		three_new.total_energy, three_orig.total_energy, led_three_new, led_three_orig);

	$display("clocks: two spins %0d (original %0d), three spins %0d (original %0d)",
		two_new.final_time, two_orig.final_time,
		three_new.final_time, three_orig.final_time);

	if (errors == 0)
		$display("PASS: matches the original designs (%0d values within tolerance)", differences);
	else
		$display("FAIL: %0d mismatches", errors);
	$finish;
end

initial begin
	#1000000;
	$display("FAIL: timeout");
	$finish;
end

endmodule
