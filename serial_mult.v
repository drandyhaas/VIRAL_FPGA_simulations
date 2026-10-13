module serial_mult #(
	parameter A_W = 16,
	parameter B_W = 16,
	parameter P_W = 32
)(
	input clk,
	input reset,

	input  wire                  start,
	input  wire signed [A_W-1:0] a,
	input  wire signed [B_W-1:0] b,
	input  wire [P_W-1:0]        c,

	output reg  [P_W-1:0]        p,
	output reg                   busy
);

// Shift-and-add multiplier: p = a * b + c mod 2^P_W (signed a and b).
// a, b and c are read when start is high; p is ready B_W clocks later,
// when busy goes low, and holds until the next start.
//
// One P_W-bit add or subtract per clock, so it has no wide single-clock
// multiplier for timing to trip on. VIRAL_n_spin uses it for products it
// needs once per layer (S^2 and gamma * S).

localparam CNT_W = $clog2(B_W + 1);

reg [P_W-1:0]   mcand;		// a << k
reg [B_W-1:0]   mplier;		// b >> k
reg [CNT_W-1:0] count;		// bits of b left

always @(posedge clk) begin
	if (!reset) begin
		busy <= 1'b0;
	end else if (start) begin
		p      <= c;
		mcand  <= a;			// sign-extended to P_W
		mplier <= b;
		count  <= B_W;
		busy   <= 1'b1;
	end else if (busy) begin
		// bit B_W-1 of b has weight -2^(B_W-1)
		if (mplier[0])
			p <= (count == 1) ? p - mcand : p + mcand;
		mcand  <= mcand << 1;
		mplier <= mplier >> 1;
		count  <= count - 1'b1;
		busy   <= (count != 1);
	end
end

endmodule
