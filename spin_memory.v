module spin_memory #(
	parameter N_SPINS   = 3,
	parameter IDX_W     = 2,
	parameter INIT_FILE = "spin_init_3.hex",
	parameter WEIGHT_FILE = ""
)(
	input clk,

	input  wire [IDX_W-1:0] rd_addr,
	output reg  [47:0]      rom_q,		// initial state of spin rd_addr
	output reg  [47:0]      ram_q,		// current state of spin rd_addr
	output reg  [15:0]      wt_q,		// weight of spin rd_addr

	input  wire             wr_en,
	input  wire [IDX_W-1:0] wr_addr,
	input  wire [47:0]      wr_data
);

// Spin state storage for VIRAL_n_spin. Each word is {x, y, z}.
// init_rom holds the initial state (from INIT_FILE), spin_mem the current
// state. Both map to block RAM (M9K on Cyclone IV, M20K on Cyclone 10 GX).
// weight_rom holds the spin weights from WEIGHT_FILE (one line per spin, 4 hex
// digits, unsigned with 15 fractional bits: 8000 = 1.0). With no
// WEIGHT_FILE every weight is 1.0 and no memory is used.
//
// Read latency: 4 clocks from rd_addr to rom_q / ram_q / wt_q. A write is
// stored 2 clocks after wr_en. The extra registers are for large N_SPINS,
// where each memory is many blocks spread over the chip:
//   - rd_addr and the write inputs are registered first (maxfan lets
//     Quartus duplicate those registers to drive all the blocks)
//   - the read address register and the output register sit inside each
//     block, and the final register follows the mux that picks the block
//
// VIRAL_n_spin never reads and writes the same word in the same clock, so
// spin_mem doesn't need read-during-write logic (no_rw_check).

(* maxfan = 32 *) reg [IDX_W-1:0] rd_addr_q;
(* maxfan = 32 *) reg             wr_en_q;
(* maxfan = 32 *) reg [IDX_W-1:0] wr_addr_q;
(* maxfan = 32 *) reg [47:0]      wr_data_q;

reg [47:0] init_rom [0:N_SPINS-1];
(* ramstyle = "no_rw_check" *)
reg [47:0] spin_mem [0:N_SPINS-1];

reg [47:0] rom_rd;
reg [47:0] rom_out;
reg [47:0] ram_rd;
reg [47:0] ram_out;

initial $readmemh(INIT_FILE, init_rom);

always @(posedge clk) begin
	rd_addr_q <= rd_addr;
	wr_en_q   <= wr_en;
	wr_addr_q <= wr_addr;
	wr_data_q <= wr_data;
end

always @(posedge clk) begin
	rom_rd  <= init_rom[rd_addr_q];
	rom_out <= rom_rd;
	rom_q   <= rom_out;
end

always @(posedge clk) begin
	if (wr_en_q)
		spin_mem[wr_addr_q] <= wr_data_q;
	ram_rd  <= spin_mem[rd_addr_q];
	ram_out <= ram_rd;
	ram_q   <= ram_out;
end

generate
	if (WEIGHT_FILE == "") begin : unit_weights
		always @(posedge clk)
			wt_q <= 16'h8000;
	end else begin : weights
		reg [15:0] weight_rom [0:N_SPINS-1];
		reg [15:0] wt_rd;
		reg [15:0] wt_out;

		initial $readmemh(WEIGHT_FILE, weight_rom);

		always @(posedge clk) begin
			wt_rd  <= weight_rom[rd_addr_q];
			wt_out <= wt_rd;
			wt_q   <= wt_out;
		end
	end
endgenerate

endmodule
