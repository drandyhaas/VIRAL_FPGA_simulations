`timescale 1 ns/100 ps

// Checks that synth/VIRAL_n_spin_direct (the original architecture scaled
// to N spins, used for the resource comparison) gives the same final spins
// as VIRAL_n_spin, and reports how many clocks each one takes.

module tb_direct_vs_new;

parameter N_SPINS   = 10;
parameter N_LAYERS  = 2;
parameter INIT_FILE = "build/spin_init_10.hex";

reg clk = 1'b0;
reg reset = 1'b0;

always #10 clk = ~clk;

wire [7:0] led_direct;
wire [7:0] led_new;

VIRAL_n_spin_direct #(.N_SPINS(N_SPINS), .N_LAYERS(N_LAYERS), .INIT_FILE(INIT_FILE))
	direct (.clk(clk), .reset(reset), .led(led_direct));

VIRAL_n_spin #(.N_SPINS(N_SPINS), .N_LAYERS(N_LAYERS), .INIT_FILE(INIT_FILE))
	new_design (.clk(clk), .reset(reset), .led(led_new));

integer i;
integer errors = 0;

initial begin
	repeat (5) @(posedge clk);
	reset = 1'b1;

	wait (new_design.finished && direct.state == 4 && direct.energy_sum);
	repeat (5) @(posedge clk);

	for (i = 0; i < N_SPINS; i = i + 1) begin
		if (direct.spin_state[i] !== new_design.spins.spin_mem[i]) begin
			if (errors < 10)
				$display("  spin %0d: direct %h, new %h",
					i, direct.spin_state[i], new_design.spins.spin_mem[i]);
			errors = errors + 1;
		end
	end

	$display("N_SPINS=%0d N_LAYERS=%0d: clocks direct %0d, new %0d; energy direct %0d, new %0d",
		N_SPINS, N_LAYERS, direct.final_time, new_design.final_time,
		direct.total_energy, new_design.total_energy);

	if (errors == 0)
		$display("PASS: same final spins");
	else
		$display("FAIL: %0d spins differ", errors);
	$finish;
end

initial begin
	#100000000;
	$display("FAIL: timeout");
	$finish;
end

endmodule
