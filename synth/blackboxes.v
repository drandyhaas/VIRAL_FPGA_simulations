// Empty stand-ins used by run_synth.sh for the Cyclone IV logic count.

(* blackbox *)
module MULT_BLACKBOX #(
	parameter A_WIDTH = 1,
	parameter B_WIDTH = 1,
	parameter Y_WIDTH = 1
)(
	input  [A_WIDTH-1:0] A,
	input  [B_WIDTH-1:0] B,
	output [Y_WIDTH-1:0] Y
);
endmodule

// spin_memory goes into M9K blocks; run_synth.sh counts those from N_SPINS
(* blackbox *)
module spin_memory #(
	parameter N_SPINS   = 3,
	parameter IDX_W     = 2,
	parameter INIT_FILE = "",
	parameter WEIGHT_FILE = ""
)(
	input clk,
	input  [IDX_W-1:0] rd_addr,
	output [47:0]      rom_q,
	output [47:0]      ram_q,
	output [15:0]      wt_q,
	input              wr_en,
	input  [IDX_W-1:0] wr_addr,
	input  [47:0]      wr_data
);
endmodule
