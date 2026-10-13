// Yosys techmap: replace every multiplier with a MULT_BLACKBOX cell, so the
// logic count leaves out multipliers (Quartus puts them in embedded
// multiplier blocks; run_synth.sh counts those from the operand widths).

(* techmap_celltype = "$mul" *)
module _90_mul_to_blackbox (A, B, Y);
	parameter A_SIGNED = 0;
	parameter B_SIGNED = 0;
	parameter A_WIDTH = 1;
	parameter B_WIDTH = 1;
	parameter Y_WIDTH = 1;

	input  [A_WIDTH-1:0] A;
	input  [B_WIDTH-1:0] B;
	output [Y_WIDTH-1:0] Y;

	MULT_BLACKBOX #(.A_WIDTH(A_WIDTH), .B_WIDTH(B_WIDTH), .Y_WIDTH(Y_WIDTH))
		_TECHMAP_REPLACE_ (.A(A), .B(B), .Y(Y));
endmodule
