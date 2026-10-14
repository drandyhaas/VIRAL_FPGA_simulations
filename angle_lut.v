module angle_lut #(
    parameter ADDR_WIDTH = 2
)(
    input  wire                  clk,
    input  wire [ADDR_WIDTH-1:0] address,

    output reg signed [15:0]     alpha_out,		// gamma, Q1.15 (original designs)
    output reg signed [31:0]     gamma_out,		// gamma, Q1.31 (VIRAL_n_spin)
    output reg signed [31:0]     beta_out
);

// gamma_out is the full-precision gamma; alpha_out is its upper 16 bits.
// For many spins, gamma has to be about 1/N_SPINS, which needs the low bits.

always @(posedge clk) begin
    case (address)

        2'd0: begin
            alpha_out <= 16'shA57E;
            gamma_out <= 32'shA57E0000;
            beta_out  <= 32'sh20000000;
        end

        2'd1: begin
            alpha_out <= 16'sh2000;
            gamma_out <= 32'sh20000000;
            beta_out  <= 32'sh40000000;
        end

        2'd2: begin
            alpha_out <= 16'sh0000;
            gamma_out <= 32'sh00000000;
            beta_out  <= 32'sh00000000;
        end

        2'd3: begin
            alpha_out <= 16'sh0000;
            gamma_out <= 32'sh00000000;
            beta_out  <= 32'sh00000000;
        end

        default: begin
            alpha_out <= 16'sh0000;
            gamma_out <= 32'sh00000000;
            beta_out  <= 32'sh00000000;
        end

    endcase
end

endmodule