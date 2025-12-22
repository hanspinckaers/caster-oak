// Copyright Wenting Zhang 2024
//
// This source describes Open Hardware and is licensed under the CERN-OHL-P v2
//
// You may redistribute and modify this documentation and make products using
// it under the terms of the CERN-OHL-P v2 (https:/cern.ch/cern-ohl). This
// documentation is distributed WITHOUT ANY EXPRESS OR IMPLIED WARRANTY,
// INCLUDING OF MERCHANTABILITY, SATISFACTORY QUALITY AND FITNESS FOR A
// PARTICULAR PURPOSE. Please see the CERN-OHL-P v2 for applicable conditions
//
// r2_dithering.v
// CFA-aware R2 Low Discrepancy Grid dithering for RGBW panels:
// 1. CFA-block aligned R2 - computed at (x/2, y/2) for coherent 2x2 blocks
// 2. Per-subpixel phase offsets for W/G/R/B
// 3. Reduced noise amplitude (like Bayer's ±7 range)
// 4. Brightness bias favoring W subpixel
//
// RGBW CFA Layout (from vin_colormixer):
//   Row 0 (even y): B W B W ... (B at even x, W at odd x)
//   Row 1 (odd y):  G R G R ... (G at even x, R at odd x)
//
// Based on: https://blog.demofox.org/2022/02/01/two-low-discrepancy-grids/
//
// 1 cycle latency
`timescale 1ns / 1ps
`default_nettype none

module r2_dithering #(
    parameter OUTPUT_BITS = 1,      // 1 or 4
    parameter COLORMODE = "RGBW"
) (
    input wire                      clk,
    input wire [31:0]               vin,        // 4 pixels x 8 bits
    output reg [OUTPUT_BITS*4-1:0]  vout,
    input wire [10:0]               x_pos,      // Pixel x position
    input wire [10:0]               y_pos       // Pixel y position
);

    // =========================================================================
    // R2 constants (16-bit fixed point)
    // phi2   = 0.7548776662 * 65536 = 49471
    // phi2^2 = 0.5698402909 * 65536 = 37347
    // =========================================================================
    localparam [15:0] R2_PHI2    = 16'd49471;
    localparam [15:0] R2_PHI2_SQ = 16'd37347;

    // =========================================================================
    // RGBW Configuration
    // CFA Layout:
    //   BW  (y%2==0: x%2==0 is B, x%2==1 is W)
    //   GR  (y%2==1: x%2==0 is G, x%2==1 is R)
    //
    // Phase offsets for each subpixel (creates different R2 patterns)
    // These spread the dither pattern across the CFA block
    // =========================================================================
    localparam [15:0] PHASE_B = 16'd0;      // Blue: base phase
    localparam [15:0] PHASE_W = 16'd16384;  // White: +0.25 phase (quarter cycle)
    localparam [15:0] PHASE_G = 16'd32768;  // Green: +0.5 phase (half cycle)
    localparam [15:0] PHASE_R = 16'd49152;  // Red: +0.75 phase (three-quarter)

    // Dither amplitude (like Bayer's ±7 range, but in 8-bit scale)
    // Range of ±14 in 8-bit = ±7 in 4-bit Bayer equivalent
    localparam signed [4:0] DITHER_AMPLITUDE = 5'sd14;
    
    // Global brightness bias (similar to Bayer's BIAS = 10)
    localparam [8:0] GLOBAL_BIAS = 9'd10;
    
    // Per-subpixel brightness bias (negative = brighter, shifts threshold down)
    // W gets the most boost since it contributes most to perceived brightness
    localparam signed [4:0] BIAS_W = -5'sd6;   // White: strong bright bias
    localparam signed [4:0] BIAS_G = -5'sd3;   // Green: medium bias (visible)
    localparam signed [4:0] BIAS_R = -5'sd2;   // Red: small bias
    localparam signed [4:0] BIAS_B = 5'sd0;    // Blue: no bias (least visible)

    // =========================================================================
    // Input pixels with global brightness bias
    // =========================================================================
    wire [7:0] pix0_raw = vin[31:24];
    wire [7:0] pix1_raw = vin[23:16];
    wire [7:0] pix2_raw = vin[15:8];
    wire [7:0] pix3_raw = vin[7:0];

    wire [8:0] pix0_biased = {1'b0, pix0_raw} + GLOBAL_BIAS;
    wire [8:0] pix1_biased = {1'b0, pix1_raw} + GLOBAL_BIAS;
    wire [8:0] pix2_biased = {1'b0, pix2_raw} + GLOBAL_BIAS;
    wire [8:0] pix3_biased = {1'b0, pix3_raw} + GLOBAL_BIAS;
    
    wire [7:0] pix0 = pix0_biased[8] ? 8'd255 : pix0_biased[7:0];
    wire [7:0] pix1 = pix1_biased[8] ? 8'd255 : pix1_biased[7:0];
    wire [7:0] pix2 = pix2_biased[8] ? 8'd255 : pix2_biased[7:0];
    wire [7:0] pix3 = pix3_biased[8] ? 8'd255 : pix3_biased[7:0];

    // =========================================================================
    // CFA-block aligned R2 calculation
    // Compute R2 at CFA block level (x/2, y/2) for coherent 2x2 blocks
    // Then add per-subpixel phase offset
    // =========================================================================
    
    // X positions for 4 consecutive pixels
    wire [10:0] x0 = x_pos;
    wire [10:0] x1 = x_pos + 11'd1;
    wire [10:0] x2 = x_pos + 11'd2;
    wire [10:0] x3 = x_pos + 11'd3;
    
    // CFA block coordinates (divide by 2)
    wire [9:0] block_x0 = x0[10:1];
    wire [9:0] block_x1 = x1[10:1];
    wire [9:0] block_x2 = x2[10:1];
    wire [9:0] block_x3 = x3[10:1];
    wire [9:0] block_y = y_pos[10:1];

    // Determine subpixel type for each pixel
    // y_pos[0]: 0=even row (BW), 1=odd row (GR)
    // x[0]: 0=even column, 1=odd column
    wire [1:0] subpix_type_0 = {y_pos[0], x0[0]};  // 00=B, 01=W, 10=G, 11=R
    wire [1:0] subpix_type_1 = {y_pos[0], x1[0]};
    wire [1:0] subpix_type_2 = {y_pos[0], x2[0]};
    wire [1:0] subpix_type_3 = {y_pos[0], x3[0]};

    // Phase offset lookup based on subpixel type
    wire [15:0] phase_0 = (subpix_type_0 == 2'b00) ? PHASE_B :
                          (subpix_type_0 == 2'b01) ? PHASE_W :
                          (subpix_type_0 == 2'b10) ? PHASE_G : PHASE_R;
    wire [15:0] phase_1 = (subpix_type_1 == 2'b00) ? PHASE_B :
                          (subpix_type_1 == 2'b01) ? PHASE_W :
                          (subpix_type_1 == 2'b10) ? PHASE_G : PHASE_R;
    wire [15:0] phase_2 = (subpix_type_2 == 2'b00) ? PHASE_B :
                          (subpix_type_2 == 2'b01) ? PHASE_W :
                          (subpix_type_2 == 2'b10) ? PHASE_G : PHASE_R;
    wire [15:0] phase_3 = (subpix_type_3 == 2'b00) ? PHASE_B :
                          (subpix_type_3 == 2'b01) ? PHASE_W :
                          (subpix_type_3 == 2'b10) ? PHASE_G : PHASE_R;

    // Brightness bias lookup based on subpixel type
    wire signed [4:0] bright_bias_0 = (subpix_type_0 == 2'b00) ? BIAS_B :
                                      (subpix_type_0 == 2'b01) ? BIAS_W :
                                      (subpix_type_0 == 2'b10) ? BIAS_G : BIAS_R;
    wire signed [4:0] bright_bias_1 = (subpix_type_1 == 2'b00) ? BIAS_B :
                                      (subpix_type_1 == 2'b01) ? BIAS_W :
                                      (subpix_type_1 == 2'b10) ? BIAS_G : BIAS_R;
    wire signed [4:0] bright_bias_2 = (subpix_type_2 == 2'b00) ? BIAS_B :
                                      (subpix_type_2 == 2'b01) ? BIAS_W :
                                      (subpix_type_2 == 2'b10) ? BIAS_G : BIAS_R;
    wire signed [4:0] bright_bias_3 = (subpix_type_3 == 2'b00) ? BIAS_B :
                                      (subpix_type_3 == 2'b01) ? BIAS_W :
                                      (subpix_type_3 == 2'b10) ? BIAS_G : BIAS_R;

    // Compute R2 at block level + phase offset
    // r2 = fract(block_x * phi2 + block_y * phi2^2 + phase)
    wire [25:0] r2_block_0 = block_x0 * R2_PHI2 + block_y * R2_PHI2_SQ;
    wire [25:0] r2_block_1 = block_x1 * R2_PHI2 + block_y * R2_PHI2_SQ;
    wire [25:0] r2_block_2 = block_x2 * R2_PHI2 + block_y * R2_PHI2_SQ;
    wire [25:0] r2_block_3 = block_x3 * R2_PHI2 + block_y * R2_PHI2_SQ;

    // Add phase offset (wraps naturally due to fixed-point)
    wire [15:0] r2_phased_0 = r2_block_0[15:0] + phase_0;
    wire [15:0] r2_phased_1 = r2_block_1[15:0] + phase_1;
    wire [15:0] r2_phased_2 = r2_block_2[15:0] + phase_2;
    wire [15:0] r2_phased_3 = r2_block_3[15:0] + phase_3;

    // Extract 4-bit threshold (like Bayer) from upper bits
    wire [3:0] thresh_4b_0 = r2_phased_0[15:12];
    wire [3:0] thresh_4b_1 = r2_phased_1[15:12];
    wire [3:0] thresh_4b_2 = r2_phased_2[15:12];
    wire [3:0] thresh_4b_3 = r2_phased_3[15:12];

    // =========================================================================
    // Dithering calculation (similar to Bayer structure)
    // Work in 5-bit space like Bayer does
    // =========================================================================
    
    // Convert pixel to 5-bit (upper 5 bits)
    wire [4:0] pix5_0 = pix0[7:3];
    wire [4:0] pix5_1 = pix1[7:3];
    wire [4:0] pix5_2 = pix2[7:3];
    wire [4:0] pix5_3 = pix3[7:3];

    // Convert 4-bit threshold (0-15) to signed offset (-7 to +7)
    // thresh 0 -> -7, thresh 7 -> 0, thresh 15 -> +7 (approximately)
    wire signed [4:0] dither_0 = {1'b0, thresh_4b_0} - 5'sd8;
    wire signed [4:0] dither_1 = {1'b0, thresh_4b_1} - 5'sd8;
    wire signed [4:0] dither_2 = {1'b0, thresh_4b_2} - 5'sd8;
    wire signed [4:0] dither_3 = {1'b0, thresh_4b_3} - 5'sd8;

    // Add dither offset + brightness bias to pixel (with saturation)
    wire signed [5:0] sum_0 = {1'b0, pix5_0} + {{1{dither_0[4]}}, dither_0} + {{1{bright_bias_0[4]}}, bright_bias_0};
    wire signed [5:0] sum_1 = {1'b0, pix5_1} + {{1{dither_1[4]}}, dither_1} + {{1{bright_bias_1[4]}}, bright_bias_1};
    wire signed [5:0] sum_2 = {1'b0, pix5_2} + {{1{dither_2[4]}}, dither_2} + {{1{bright_bias_2[4]}}, bright_bias_2};
    wire signed [5:0] sum_3 = {1'b0, pix5_3} + {{1{dither_3[4]}}, dither_3} + {{1{bright_bias_3[4]}}, bright_bias_3};

    // Saturate to 0-31 range (5-bit)
    wire [4:0] sat_0 = sum_0[5] ? 5'd0 : (sum_0[4:0] > 5'd31) ? 5'd31 : sum_0[4:0];
    wire [4:0] sat_1 = sum_1[5] ? 5'd0 : (sum_1[4:0] > 5'd31) ? 5'd31 : sum_1[4:0];
    wire [4:0] sat_2 = sum_2[5] ? 5'd0 : (sum_2[4:0] > 5'd31) ? 5'd31 : sum_2[4:0];
    wire [4:0] sat_3 = sum_3[5] ? 5'd0 : (sum_3[4:0] > 5'd31) ? 5'd31 : sum_3[4:0];

    // Output: take top OUTPUT_BITS from each 5-bit result
    generate
        if (OUTPUT_BITS == 1) begin: gen_1bit_out
            wire [3:0] dithered = {sat_0[4], sat_1[4], sat_2[4], sat_3[4]};
            always @(posedge clk) begin
                vout <= dithered;
            end
        end
        else begin: gen_4bit_out
            wire [15:0] dithered = {
                sat_0[4:1],
                sat_1[4:1],
                sat_2[4:1],
                sat_3[4:1]
            };
            always @(posedge clk) begin
                vout <= dithered;
            end
        end
    endgenerate

endmodule

`default_nettype wire
