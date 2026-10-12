`timescale 1 ns/100 ps

module cordic_iterative (
    input  wire                    clock,
    input  wire                    reset_in,
    input  wire                    start,

    input  wire signed [31:0]      angle,
    input  wire signed [15:0]      Xin,
    input  wire signed [15:0]      Yin,

    output reg  signed [15:0]      Xout,
    output reg  signed [15:0]      Yout,

    output reg                     busy,
    output reg                     done
);

    // ============================================================
    // 16-bit external I/Q
    // 17-bit internal I/Q gives one guard bit
    // ============================================================
	 reg signed [15:0] Xin_reg;
	 reg signed [15:0] Yin_reg;	
	 reg signed [31:0] angle_reg;
	 reg load_pending;

    reg signed [16:0] X;
    reg signed [16:0] Y;

    reg signed [31:0] Z;

    reg [4:0] iteration;


    // ============================================================
    // ARCTAN TABLE
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
    // SIGN EXTEND INPUT
    // ============================================================

    wire signed [16:0] Xin_extended;
    wire signed [16:0] Yin_extended;

    assign Xin_extended = {Xin_reg[15], Xin_reg};
    assign Yin_extended = {Yin_reg[15], Yin_reg};


    // ============================================================
    // CORDIC GAIN COMPENSATION
    //
    // 1/K ~= 0.607253
    //
    // Approximation:
    //
    // 0.607421875
    // = 1/2 + 1/8 - 1/64 - 1/512
    //
    // No hardware multiplier required.
    // ============================================================

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
    // CURRENT ITERATION
    // ============================================================

    wire signed [16:0] X_shift;
    wire signed [16:0] Y_shift;

    assign X_shift = X >>> iteration;
    assign Y_shift = Y >>> iteration;


    // ============================================================
    // NEXT CORDIC VALUE
    // ============================================================

    wire signed [16:0] X_next;
    wire signed [16:0] Y_next;
    wire signed [31:0] Z_next;

    assign X_next =
        Z[31] ?
        (X + Y_shift) :
        (X - Y_shift);

    assign Y_next =
        Z[31] ?
        (Y - X_shift) :
        (Y + X_shift);

    assign Z_next =
        Z[31] ?
        (Z + atan_table[iteration]) :
        (Z - atan_table[iteration]);


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
    // ITERATIVE CORDIC CONTROL
    // ============================================================

    always @(posedge clock) begin

        if (!reset_in) begin

            X         <= 17'sd0;
            Y         <= 17'sd0;
            Z         <= 32'sd0;

            Xout      <= 16'sd0;
            Yout      <= 16'sd0;

            iteration <= 5'd0;

            busy      <= 1'b0;
            done      <= 1'b0;
				Xin_reg      <= 16'sd0;
				Yin_reg      <= 16'sd0;
				angle_reg    <= 32'sd0;
				load_pending <= 1'b0;

        end

        else begin

            // done is a one-clock pulse
            done <= 1'b0;


            // ====================================================
            // START NEW ROTATION
            // ====================================================

				if (start && !busy && !load_pending) begin

					 Xin_reg   <= Xin;
					 Yin_reg   <= Yin;
					 angle_reg <= angle;

					 load_pending <= 1'b1;

				end

				else if (load_pending) begin

					 iteration    <= 5'd0;
					 busy         <= 1'b1;
					 load_pending <= 1'b0;

					 if (
						  angle_reg[31:30] == 2'b00 ||
						  angle_reg[31:30] == 2'b11
					 ) begin

						  X <= Xin_scaled;
						  Y <= Yin_scaled;
						  Z <= angle_reg;

					 end

					 else if (angle_reg[31:30] == 2'b01) begin

						  X <= -Yin_scaled;
						  Y <=  Xin_scaled;

						  Z <= {2'b00, angle_reg[29:0]};

					 end

					 else begin

						  X <=  Yin_scaled;
						  Y <= -Xin_scaled;

						  Z <= {2'b11, angle_reg[29:0]};

					 end
				end


            // ====================================================
            // PERFORM ONE CORDIC ITERATION PER CLOCK
            // ====================================================

            else if (busy) begin

                X <= X_next;
                Y <= Y_next;
                Z <= Z_next;


                // Original pipelined module used iterations
                // i = 0 through i = 14.
                if (iteration == 5'd14) begin

                    Xout <= resize_output(X_next);
                    Yout <= resize_output(Y_next);

                    busy <= 1'b0;
                    done <= 1'b1;

                end

                else begin

                    iteration <= iteration + 5'd1;

                end

            end

        end

    end

endmodule