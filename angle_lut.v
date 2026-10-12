module angle_lut #(
    parameter ADDR_WIDTH = 2
)(
    input  wire                  clk,
    input  wire [ADDR_WIDTH-1:0] address,

    output reg signed [15:0]     alpha_out,
    output reg signed [31:0]     beta_out
);

always @(posedge clk) begin
    case (address)

        2'd0: begin
            alpha_out <= 16'shA57E;
            beta_out  <= 32'sh20000000;
        end

        2'd1: begin
            alpha_out <= 16'sh2000;
            beta_out  <= 32'sh40000000;
        end

        2'd2: begin
            alpha_out <= 16'sh0000;
            beta_out  <= 32'sh00000000;
        end

        2'd3: begin
            alpha_out <= 16'sh0000;
            beta_out  <= 32'sh00000000;
        end

        default: begin
            alpha_out <= 16'sh0000;
            beta_out  <= 32'sh00000000;
        end

    endcase
end

endmodule