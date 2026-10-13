module spin_memory #(
	parameter N_SPINS   = 3,
	parameter IDX_W     = 2,
	parameter INIT_FILE = "spin_init_3.hex"
)(
	input clk,

	input  wire [IDX_W-1:0] rd_addr,
	output reg  [47:0]      rom_q,		// initial state of spin rd_addr
	output reg  [47:0]      ram_q,		// current state of spin rd_addr

	input  wire             wr_en,
	input  wire [IDX_W-1:0] wr_addr,
	input  wire [47:0]      wr_data
);

// Spin state storage for VIRAL_n_spin. Each word is {x, y, z}.
// init_rom holds the initial state (from INIT_FILE), spin_mem the current
// state. Both have registered reads (one clock), so they map to block RAM
// (M9K on Cyclone IV) for large N_SPINS.

reg [47:0] init_rom [0:N_SPINS-1];
reg [47:0] spin_mem [0:N_SPINS-1];

initial $readmemh(INIT_FILE, init_rom);

always @(posedge clk) begin
	rom_q <= init_rom[rd_addr];
end

always @(posedge clk) begin
	if (wr_en)
		spin_mem[wr_addr] <= wr_data;
	ram_q <= spin_mem[rd_addr];
end

endmodule
