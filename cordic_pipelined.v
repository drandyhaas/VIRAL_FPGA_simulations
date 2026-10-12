`timescale 1 ns/100 ps

// ================================================================
// Fully pipelined version of cordic_iterative.
//
// Same arithmetic as cordic_iterative (gain pre-scaling, quadrant
// folding, 17-bit internal X/Y, 32-bit angle, 15 iterations, output
// saturation), so the same inputs give bit-identical outputs. Each
// iteration has its own pipeline stage, so a new vector can be
// started every clock.
//
// Latency: 17 clocks from in_valid to out_valid.
// in_tag is carried along unchanged and comes out with its result.
// ================================================================

module cordic_pipelined #(
    parameter TAG_WIDTH = 8
)(
    input  wire                    clock,
    input  wire                    reset_in,

    input  wire                    in_valid,
    input  wire [TAG_WIDTH-1:0]    in_tag,

    input  wire signed [31:0]      angle,
    input  wire signed [15:0]      Xin,
    input  wire signed [15:0]      Yin,

    output reg                     out_valid,
    output reg  [TAG_WIDTH-1:0]    out_tag,

    output reg  signed [15:0]      Xout,
    output reg  signed [15:0]      Yout
);

    localparam N_ITER = 15;


    // ============================================================
    // ARCTAN TABLE (same as cordic_iterative)
    // ============================================================

    wire signed [31:0] atan_table [0:14];

    assign atan_table[0]  =
        32'b00100000000000000000000000000000;

    assign atan_table[1]  =
        32'b00010010111001000000010100011101;

    assign atan_table[2]  =
        32'b00001001111110110011100001011011;

    assign atan_table[3]  =
        32'b00000101000100010001000111010100;

    assign atan_table[4]  =
        32'b00000010100010110000110101000011;

    assign atan_table[5]  =
        32'b00000001010001011101011111100001;

    assign atan_table[6]  =
        32'b00000000101000101111011000011110;

    assign atan_table[7]  =
        32'b00000000010100010111110001010101;

    assign atan_table[8]  =
        32'b00000000001010001011111001010011;

    assign atan_table[9]  =
        32'b00000000000101000101111100101110;

    assign atan_table[10] =
        32'b00000000000010100010111110011000;

    assign atan_table[11] =
        32'b00000000000001010001011111001100;

    assign atan_table[12] =
        32'b00000000000000101000101111100110;

    assign atan_table[13] =
        32'b00000000000000010100010111110011;

    assign atan_table[14] =
        32'b00000000000000001010001011111001;


    // ============================================================
    // STAGE 0: INPUT REGISTERS
    // ============================================================

    reg                    in_valid_reg;
    reg [TAG_WIDTH-1:0]    in_tag_reg;
    reg signed [15:0]      Xin_reg;
    reg signed [15:0]      Yin_reg;
    reg signed [31:0]      angle_reg;


    // ============================================================
    // SIGN EXTEND AND CORDIC GAIN COMPENSATION
    //
    // 1/K ~= 0.607253 ~= 1/2 + 1/8 - 1/64 - 1/512
    // ============================================================

    wire signed [16:0] Xin_extended;
    wire signed [16:0] Yin_extended;

    assign Xin_extended = {Xin_reg[15], Xin_reg};
    assign Yin_extended = {Yin_reg[15], Yin_reg};

    wire signed [16:0] Xin_scaled;
    wire signed [16:0] Yin_scaled;

    assign Xin_scaled =
          (Xin_extended >>> 1)
        + (Xin_extended >>> 3)
        - (Xin_extended >>> 6)
        - (Xin_extended >>> 9);

    assign Yin_scaled =
          (Yin_extended >>> 1)
        + (Yin_extended >>> 3)
        - (Yin_extended >>> 6)
        - (Yin_extended >>> 9);


    // ============================================================
    // ITERATION PIPELINE
    //
    // Stage k holds the vector before iteration k.
    // ============================================================

    reg [N_ITER-1:0]       valid_p;
    reg [TAG_WIDTH-1:0]    tag_p [0:N_ITER-1];
    reg signed [16:0]      X_p   [0:N_ITER-1];
    reg signed [16:0]      Y_p   [0:N_ITER-1];
    reg signed [31:0]      Z_p   [0:N_ITER-1];

    wire signed [16:0]     X_next [0:N_ITER-1];
    wire signed [16:0]     Y_next [0:N_ITER-1];
    wire signed [31:0]     Z_next [0:N_ITER-1];

    genvar g;
    generate
        for (g = 0; g < N_ITER; g = g + 1) begin : iteration

            assign X_next[g] =
                Z_p[g][31] ?
                (X_p[g] + (Y_p[g] >>> g)) :
                (X_p[g] - (Y_p[g] >>> g));

            assign Y_next[g] =
                Z_p[g][31] ?
                (Y_p[g] - (X_p[g] >>> g)) :
                (Y_p[g] + (X_p[g] >>> g));

            assign Z_next[g] =
                Z_p[g][31] ?
                (Z_p[g] + atan_table[g]) :
                (Z_p[g] - atan_table[g]);

        end
    endgenerate


    // ============================================================
    // OUTPUT SATURATION
    //
    // 17-bit internal -> 16-bit external
    // ============================================================

    function signed [15:0] resize_output;

        input signed [16:0] value;

        begin

            // positive overflow
            if (value[16:15] == 2'b01)
                resize_output = 16'sh7FFF;

            // negative overflow
            else if (value[16:15] == 2'b10)
                resize_output = 16'sh8000;

            // fits
            else
                resize_output = value[15:0];

        end

    endfunction


    // ============================================================
    // VALID PIPELINE (only the valid bits need a reset)
    // ============================================================

    integer k;

    always @(posedge clock) begin

        if (!reset_in) begin

            in_valid_reg <= 1'b0;
            valid_p      <= {N_ITER{1'b0}};
            out_valid    <= 1'b0;

        end

        else begin

            in_valid_reg <= in_valid;
            valid_p      <= {valid_p[N_ITER-2:0], in_valid_reg};
            out_valid    <= valid_p[N_ITER-1];

        end

    end


    // ============================================================
    // DATA PIPELINE
    // ============================================================

    always @(posedge clock) begin

        // stage 0: register inputs
        in_tag_reg <= in_tag;
        Xin_reg    <= Xin;
        Yin_reg    <= Yin;
        angle_reg  <= angle;

        // stage 1: gain compensation and quadrant folding
        tag_p[0] <= in_tag_reg;

        if (
            angle_reg[31:30] == 2'b00 ||
            angle_reg[31:30] == 2'b11
        ) begin

            X_p[0] <= Xin_scaled;
            Y_p[0] <= Yin_scaled;
            Z_p[0] <= angle_reg;

        end

        else if (angle_reg[31:30] == 2'b01) begin

            X_p[0] <= -Yin_scaled;
            Y_p[0] <=  Xin_scaled;
            Z_p[0] <= {2'b00, angle_reg[29:0]};

        end

        else begin

            X_p[0] <=  Yin_scaled;
            Y_p[0] <= -Xin_scaled;
            Z_p[0] <= {2'b11, angle_reg[29:0]};

        end

        // stages 2 .. 15: one CORDIC iteration each
        for (k = 1; k < N_ITER; k = k + 1) begin

            tag_p[k] <= tag_p[k-1];
            X_p[k]   <= X_next[k-1];
            Y_p[k]   <= Y_next[k-1];
            Z_p[k]   <= Z_next[k-1];

        end

        // stage 16: last iteration and output saturation
        out_tag <= tag_p[N_ITER-1];
        Xout    <= resize_output(X_next[N_ITER-1]);
        Yout    <= resize_output(Y_next[N_ITER-1]);

    end

endmodule
