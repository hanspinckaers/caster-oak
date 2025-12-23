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
// bayer_dithering.v
// Improved Bayer dithering with:
// 1. Original 3x3 Bayer matrix (no phase scrambling)
// 2. Gradient-weighted edge detection with soft blending
//    - Instead of binary threshold, uses gradient magnitude for smooth blending
//    - Eliminates stripe artifacts in images while preserving sharp text edges
//    - Text (high gradient >160) gets full edge-aware treatment
//    - Images (lower gradients) retain smooth dithering
// 3. Same-color subpixel comparison to avoid false edges from CFA pattern
//    - RGBW 2x2 pattern: Row0=BW, Row1=GR (alternating)
//    - Horizontal: compare to same-color 2 pixels back
//    - Vertical: compare to same-color 2 lines back
//    - Diagonal: compare to same-color 2 pixels + 2 lines offset
//
// 1 cycle latency (same as original)
`timescale 1ns / 1ps
`default_nettype none

module bayer_dithering #(
    parameter COLORMODE = "RGBW",
    parameter OUTPUT_BITS = 1,        // 1 = binary (2 levels), 2 = 4 gray levels
    parameter LINE_WIDTH_MAX = 2200,  // Max pixels per line (compile-time buffer sizing)
    parameter EDGE_THRESH_LOW = 80,   // Below this: full dithering (smooth gradients)
    parameter EDGE_THRESH_HIGH = 160, // Above this: full simple threshold (sharp text)
    // CFA threshold bias - for equal perceived thickness
    // W=high (stays black more, counters brightness)
    // B/G/R=low (turns white more, counters dimness)
    parameter CFA_BIAS_B = 20,        // Blue - easy to turn ON
    parameter CFA_BIAS_W = 50,        // White - hard to turn ON
    parameter CFA_BIAS_G = 20,        // Green - easy to turn ON
    parameter CFA_BIAS_R = 20,        // Red - easy to turn ON
    parameter FATTEN = 0              // Lower threshold globally (fatter text, 0-20)
) (
    input wire                       clk,
    input wire                       rst,
    input wire [31:0]                vin,
    output reg [OUTPUT_BITS*4-1:0]   vout,
    input wire [10:0]                x_cnt,      // Full x counter for line buffer addressing
    input wire [10:0]                y_cnt,      // Full y counter for line change detection
    input wire [2:0]                 x_pos,      // X position for Bayer matrix (mod 8)
    input wire [2:0]                 y_pos       // Y position for Bayer matrix (mod 8)
    // Note: Actual line width is determined by x_cnt timing from caster (hact from CSR)
    // LINE_WIDTH_MAX just sizes the buffer for the maximum expected width
);

    // ISE-compatible clog2 function
    function integer clog2;
        input integer value;
        integer i;
        begin
            clog2 = 0;
            for (i = value - 1; i > 0; i = i >> 1)
                clog2 = clog2 + 1;
        end
    endfunction

    // =========================================================================
    // Bayer Matrix Lookup (original 3x3 matrix, no phase scrambling)
    // =========================================================================
    
    wire [3:0] b0, b1, b2, b3;

    generate
    if (COLORMODE == "MONO") begin: gen_mono_dither
        // MONO mode uses y_pos[1:0] only, no x dependency
        assign b0 =
            (y_pos[1:0] == 2'b00) ? (-4'd8) :
            (y_pos[1:0] == 2'b01) ? (4'd4) :
            (y_pos[1:0] == 2'b10) ? (-4'd5) :
                                    (4'd7);
        assign b1 =
            (y_pos[1:0] == 2'b00) ? (4'd0) :
            (y_pos[1:0] == 2'b01) ? (-4'd4) :
            (y_pos[1:0] == 2'b10) ? (4'd3) :
                                    (-4'd1);
        assign b2 =
            (y_pos[1:0] == 2'b00) ? (-4'd6) :
            (y_pos[1:0] == 2'b01) ? (4'd6) :
            (y_pos[1:0] == 2'b10) ? (-4'd7) :
                                    (4'd5);
        assign b3 =
            (y_pos[1:0] == 2'b00) ? (4'd2) :
            (y_pos[1:0] == 2'b01) ? (-4'd2) :
            (y_pos[1:0] == 2'b10) ? (4'd1) :
                                    (-4'd3);
    end
    else if (COLORMODE == "DES") begin: gen_des_dither
        assign b0 =
            (y_pos[2:0] == 3'd0) ? ((x_pos[1:0] == 2'd0) ? (-4'd7) : (x_pos[1:0] == 2'd1) ? ( 4'd7) : ( 4'd0)) :
            (y_pos[2:0] == 3'd1) ? ((x_pos[1:0] == 2'd0) ? (-4'd7) : (x_pos[1:0] == 2'd1) ? ( 4'd0) : ( 4'd0)) :
                                   ((x_pos[1:0] == 2'd0) ? (-4'd7) : (x_pos[1:0] == 2'd1) ? ( 4'd7) : ( 4'd7));
        assign b1 =
            (y_pos[2:0] == 3'd0) ? ((x_pos[1:0] == 2'd0) ? ( 4'd7) : (x_pos[1:0] == 2'd1) ? ( 4'd0) : (-4'd7)) :
            (y_pos[2:0] == 3'd1) ? ((x_pos[1:0] == 2'd0) ? ( 4'd0) : (x_pos[1:0] == 2'd1) ? ( 4'd0) : (-4'd7)) :
                                   ((x_pos[1:0] == 2'd0) ? ( 4'd7) : (x_pos[1:0] == 2'd1) ? ( 4'd7) : (-4'd7));
        assign b2 =
            (y_pos[2:0] == 3'd0) ? ((x_pos[1:0] == 2'd0) ? ( 4'd0) : (x_pos[1:0] == 2'd1) ? (-4'd7) : ( 4'd7)) :
            (y_pos[2:0] == 3'd1) ? ((x_pos[1:0] == 2'd0) ? ( 4'd0) : (x_pos[1:0] == 2'd1) ? (-4'd7) : ( 4'd0)) :
                                   ((x_pos[1:0] == 2'd0) ? ( 4'd7) : (x_pos[1:0] == 2'd1) ? (-4'd7) : ( 4'd7));
        assign b3 =
            (y_pos[2:0] == 3'd0) ? ((x_pos[1:0] == 2'd0) ? (-4'd7) : (x_pos[1:0] == 2'd1) ? ( 4'd7) : ( 4'd0)) :
            (y_pos[2:0] == 3'd1) ? ((x_pos[1:0] == 2'd0) ? (-4'd7) : (x_pos[1:0] == 2'd1) ? ( 4'd0) : ( 4'd0)) :
                                   ((x_pos[1:0] == 2'd0) ? (-4'd7) : (x_pos[1:0] == 2'd1) ? ( 4'd7) : ( 4'd7));
    end
    else if (COLORMODE == "RGBW") begin: gen_rgbw_dither
        // OAK 3x3 Matrix - original values without phase scrambling
        assign b0 =
            (y_pos[2:0] == 3'd0) ? ((x_pos[1:0] == 2'd0) ? (-4'd7) : (x_pos[1:0] == 2'd1) ? ( 4'd0) : ( 4'd3)) :
            (y_pos[2:0] == 3'd1) ? ((x_pos[1:0] == 2'd0) ? ( 4'd5) : (x_pos[1:0] == 2'd1) ? (-4'd6) : ( 4'd6)) :
                                   ((x_pos[1:0] == 2'd0) ? ( 4'd7) : (x_pos[1:0] == 2'd1) ? (-4'd5) : (-4'd3));
        assign b1 =
            (y_pos[2:0] == 3'd0) ? ((x_pos[1:0] == 2'd0) ? ( 4'd0) : (x_pos[1:0] == 2'd1) ? ( 4'd3) : (-4'd7)) :
            (y_pos[2:0] == 3'd1) ? ((x_pos[1:0] == 2'd0) ? (-4'd6) : (x_pos[1:0] == 2'd1) ? ( 4'd6) : ( 4'd5)) :
                                   ((x_pos[1:0] == 2'd0) ? (-4'd5) : (x_pos[1:0] == 2'd1) ? (-4'd3) : ( 4'd7));
        assign b2 =
            (y_pos[2:0] == 3'd0) ? ((x_pos[1:0] == 2'd0) ? ( 4'd3) : (x_pos[1:0] == 2'd1) ? (-4'd7) : ( 4'd0)) :
            (y_pos[2:0] == 3'd1) ? ((x_pos[1:0] == 2'd0) ? ( 4'd6) : (x_pos[1:0] == 2'd1) ? ( 4'd5) : (-4'd6)) :
                                   ((x_pos[1:0] == 2'd0) ? (-4'd3) : (x_pos[1:0] == 2'd1) ? ( 4'd7) : (-4'd5));
        assign b3 =
            (y_pos[2:0] == 3'd0) ? ((x_pos[1:0] == 2'd0) ? (-4'd7) : (x_pos[1:0] == 2'd1) ? ( 4'd0) : ( 4'd3)) :
            (y_pos[2:0] == 3'd1) ? ((x_pos[1:0] == 2'd0) ? ( 4'd5) : (x_pos[1:0] == 2'd1) ? (-4'd6) : ( 4'd6)) :
                                   ((x_pos[1:0] == 2'd0) ? ( 4'd7) : (x_pos[1:0] == 2'd1) ? (-4'd5) : (-4'd3));
    end
    endgenerate

    // =========================================================================
    // CFA-Balanced 4x4 Bayer Matrix for 2-bit path (FAST_GREY)
    // Each CFA color (B,W,G,R) gets equal average offset for neutral grays
    // Matrix (4-bit signed, -8 to +7):
    //   -8 -6 +1 +3    (row 0: B=-8, W=-6, B=+1, W=+3)
    //   -7 -5  0 +2    (row 1: G=-7, R=-5, G= 0, R=+2)
    //   -2 -4 +7 +5    (row 2: B=-2, W=-4, B=+7, W=+5)
    //   -1 -3 +6 +4    (row 3: G=-1, R=-3, G=+6, R=+4)
    // Per-color averages: B=(-8+1-2+7)/4=-0.5, W=(-6+3-4+5)/4=-0.5
    //                     G=(-7+0-1+6)/4=-0.5, R=(-5+2-3+4)/4=-0.5 ✓
    // =========================================================================

    wire [1:0] bayer4_row = y_pos[1:0];
    wire [1:0] bayer4_col0 = x_pos[1:0];
    wire [1:0] bayer4_col1 = x_pos[1:0] + 2'd1;
    wire [1:0] bayer4_col2 = x_pos[1:0] + 2'd2;
    wire [1:0] bayer4_col3 = x_pos[1:0] + 2'd3;

    // 4x4 CFA-balanced Bayer lookup
    function [3:0] bayer4x4_lookup;
        input [1:0] row;
        input [1:0] col;
        begin
            case ({row, col})
                4'b0000: bayer4x4_lookup = -4'sd8;  // row 0, col 0
                4'b0001: bayer4x4_lookup = -4'sd6;  // row 0, col 1
                4'b0010: bayer4x4_lookup =  4'sd1;  // row 0, col 2
                4'b0011: bayer4x4_lookup =  4'sd3;  // row 0, col 3
                4'b0100: bayer4x4_lookup = -4'sd7;  // row 1, col 0
                4'b0101: bayer4x4_lookup = -4'sd5;  // row 1, col 1
                4'b0110: bayer4x4_lookup =  4'sd0;  // row 1, col 2
                4'b0111: bayer4x4_lookup =  4'sd2;  // row 1, col 3
                4'b1000: bayer4x4_lookup = -4'sd2;  // row 2, col 0
                4'b1001: bayer4x4_lookup = -4'sd4;  // row 2, col 1
                4'b1010: bayer4x4_lookup =  4'sd7;  // row 2, col 2
                4'b1011: bayer4x4_lookup =  4'sd5;  // row 2, col 3
                4'b1100: bayer4x4_lookup = -4'sd1;  // row 3, col 0
                4'b1101: bayer4x4_lookup = -4'sd3;  // row 3, col 1
                4'b1110: bayer4x4_lookup =  4'sd6;  // row 3, col 2
                4'b1111: bayer4x4_lookup =  4'sd4;  // row 3, col 3
                default: bayer4x4_lookup =  4'sd0;
            endcase
        end
    endfunction

    wire [3:0] b0_4x4 = bayer4x4_lookup(bayer4_row, bayer4_col0);
    wire [3:0] b1_4x4 = bayer4x4_lookup(bayer4_row, bayer4_col1);
    wire [3:0] b2_4x4 = bayer4x4_lookup(bayer4_row, bayer4_col2);
    wire [3:0] b3_4x4 = bayer4x4_lookup(bayer4_row, bayer4_col3);

    // =========================================================================
    // Standard Bayer Dithering Path with CFA Bias
    // =========================================================================

    localparam BIAS = 9'd10;  // Positive = lower threshold (more white pixels)

    wire [7:0] pix0 = vin[31:24];
    wire [7:0] pix1 = vin[23:16];
    wire [7:0] pix2 = vin[15:8];
    wire [7:0] pix3 = vin[7:0];

    // =========================================================================
    // CFA Position and Threshold Bias (RGBW mode)
    // CFA pattern: Row0=B,W,B,W  Row1=G,R,G,R
    // pix0,pix2: even columns (B or G)
    // pix1,pix3: odd columns (W or R)
    // =========================================================================

    wire cfa_row = y_cnt[0];  // 0=BW row, 1=GR row

    // CFA bias per pixel position
    // Row 0: pix0,pix2=B, pix1,pix3=W
    // Row 1: pix0,pix2=G, pix1,pix3=R
    wire [7:0] cfa_bias_02 = (cfa_row == 1'b0) ? CFA_BIAS_B[7:0] : CFA_BIAS_G[7:0];
    wire [7:0] cfa_bias_13 = (cfa_row == 1'b0) ? CFA_BIAS_W[7:0] : CFA_BIAS_R[7:0];

    // Simple unsigned bias: BIAS + FATTEN - CFA_BIAS, clamped to 0 minimum
    wire [8:0] bias_02 = (BIAS + FATTEN > {1'b0, cfa_bias_02}) ? (BIAS + FATTEN - {1'b0, cfa_bias_02}) : 9'd0;
    wire [8:0] bias_13 = (BIAS + FATTEN > {1'b0, cfa_bias_13}) ? (BIAS + FATTEN - {1'b0, cfa_bias_13}) : 9'd0;

    // 1-bit path: uses CFA bias (for FAST_MONO)
    wire [8:0] a0 = {1'b0, pix0} + bias_02;
    wire [8:0] a1 = {1'b0, pix1} + bias_13;
    wire [8:0] a2 = {1'b0, pix2} + bias_02;
    wire [8:0] a3 = {1'b0, pix3} + bias_13;

    wire [3:0] c0, c1, c2, c3;
    adder_sat adder_sat0 (a0[8:4], b0, c0);
    adder_sat adder_sat1 (a1[8:4], b1, c1);
    adder_sat adder_sat2 (a2[8:4], b2, c2);
    adder_sat adder_sat3 (a3[8:4], b3, c3);

    // 2-bit path: CFA-aware bias for prettier colors (FAST_GREY)
    // W subpixels slightly darker to add depth while preserving color visibility
    // CFA pattern: Row0=B,W,B,W  Row1=G,R,G,R
    // pix0,pix2 = B or G (color), pix1,pix3 = W or R
    localparam W_DARKEN = 4'd0;  // Disabled for testing

    // Color subpixels (B/G): no bias change
    wire [8:0] a0_2b = {1'b0, pix0};
    wire [8:0] a2_2b = {1'b0, pix2};

    // W/R subpixels: darken W only (row 0), keep R natural (row 1)
    // Clamp to 0 to avoid underflow
    wire [7:0] pix1_dark = (pix1 > {4'd0, W_DARKEN}) ? (pix1 - {4'd0, W_DARKEN}) : 8'd0;
    wire [7:0] pix3_dark = (pix3 > {4'd0, W_DARKEN}) ? (pix3 - {4'd0, W_DARKEN}) : 8'd0;
    wire [8:0] a1_2b = (cfa_row == 1'b0) ? {1'b0, pix1_dark} : {1'b0, pix1};
    wire [8:0] a3_2b = (cfa_row == 1'b0) ? {1'b0, pix3_dark} : {1'b0, pix3};

    wire [3:0] c0_2b, c1_2b, c2_2b, c3_2b;
    // Use 4x4 CFA-balanced Bayer (matches simulation bayer_dither_4level_edge_aware_no_simple)
    adder_sat adder_sat0_2b (a0_2b[8:4], b0_4x4, c0_2b);
    adder_sat adder_sat1_2b (a1_2b[8:4], b1_4x4, c1_2b);
    adder_sat adder_sat2_2b (a2_2b[8:4], b2_4x4, c2_2b);
    adder_sat adder_sat3_2b (a3_2b[8:4], b3_4x4, c3_2b);

    // =========================================================================
    // Grayscale Path for Sharp B/W Text (200dpi mode)
    // Uses luminance for all subpixels instead of CFA color mixing
    // Only activated for black text on white backgrounds
    // =========================================================================

    // Saturation detection: max - min across all 4 pixels
    wire [7:0] max_01 = (pix0 > pix1) ? pix0 : pix1;
    wire [7:0] max_23 = (pix2 > pix3) ? pix2 : pix3;
    wire [7:0] max_all = (max_01 > max_23) ? max_01 : max_23;
    wire [7:0] min_01 = (pix0 < pix1) ? pix0 : pix1;
    wire [7:0] min_23 = (pix2 < pix3) ? pix2 : pix3;
    wire [7:0] min_all = (min_01 < min_23) ? min_01 : min_23;
    wire [7:0] saturation = max_all - min_all;
    wire is_low_saturation = (saturation < 8'd30);

    // Luminance approximation: average of all pixels
    // (pix0 + pix1 + pix2 + pix3) / 4
    wire [9:0] lum_sum = {2'b0, pix0} + {2'b0, pix1} + {2'b0, pix2} + {2'b0, pix3};
    wire [7:0] luminance = lum_sum[9:2];  // Divide by 4

    // W_LIGHTEN: Boost dark W pixels to reduce stroke weight on W columns
    // Only applies to W subpixels (row 0, odd columns = pix1, pix3)
    localparam [7:0] W_LIGHTEN = 8'd80;
    wire [7:0] lum_for_w = (luminance < 8'd128) ?
                           ((luminance + W_LIGHTEN > 8'd255) ? 8'd255 : luminance + W_LIGHTEN) :
                           luminance;

    // Grayscale dithering: use luminance for all subpixels
    // But W subpixels use lightened luminance when dark
    wire [8:0] a0_gray = {1'b0, luminance};
    wire [8:0] a1_gray = (cfa_row == 1'b0) ? {1'b0, lum_for_w} : {1'b0, luminance};  // W gets lightened
    wire [8:0] a2_gray = {1'b0, luminance};
    wire [8:0] a3_gray = (cfa_row == 1'b0) ? {1'b0, lum_for_w} : {1'b0, luminance};  // W gets lightened

    wire [3:0] c0_gray, c1_gray, c2_gray, c3_gray;
    // Use 4x4 CFA-balanced Bayer (same as CFA path)
    adder_sat adder_sat0_gray (a0_gray[8:4], b0_4x4, c0_gray);
    adder_sat adder_sat1_gray (a1_gray[8:4], b1_4x4, c1_gray);
    adder_sat adder_sat2_gray (a2_gray[8:4], b2_4x4, c2_gray);
    adder_sat adder_sat3_gray (a3_gray[8:4], b3_4x4, c3_gray);

    // Helper function to find max of two 8-bit values (used for local max detection)
    function [7:0] max2;
        input [7:0] a, b;
        begin
            max2 = (a > b) ? a : b;
        end
    endfunction

    // Local max brightness detection (has_bright_side)
    // Check if current pixel group or neighbors have any bright pixel (>245)
    // This detects white backgrounds for sharp B/W text
    wire [7:0] local_max_cur = max_all;  // Max of current 4 pixels
    wire [7:0] local_max_prev = max2(max2(prev_pix0, prev_pix1), max2(prev_pix2, prev_pix3));
    wire [7:0] local_max_up = max2(max2(prev2_line_pix0, prev2_line_pix1), max2(prev2_line_pix2, prev2_line_pix3));
    wire [7:0] local_max_all = max2(max2(local_max_cur, local_max_prev), local_max_up);
    wire has_bright_side = (local_max_all > 8'd245);

    // Dark pixel check - only use grayscale for dark text (luminance < 150)
    wire is_dark_pixel = (luminance < 8'd150);

    // Per-pixel gradient check using existing edge detection
    // Reuse max_grad_* which already computes gradient per pixel
    localparam [7:0] GRAY_EDGE_THRESH = 8'd80;  // Edge threshold for grayscale path
    wire is_edge_0 = (max_grad_0 > GRAY_EDGE_THRESH);
    wire is_edge_1 = (max_grad_1 > GRAY_EDGE_THRESH);
    wire is_edge_2 = (max_grad_2 > GRAY_EDGE_THRESH);
    wire is_edge_3 = (max_grad_3 > GRAY_EDGE_THRESH);

    // Use grayscale path when: edge + low saturation + bright background + dark pixel
    // This targets black text on white backgrounds specifically
    wire use_gray_0 = is_edge_0 & is_low_saturation & has_bright_side & is_dark_pixel;
    wire use_gray_1 = is_edge_1 & is_low_saturation & has_bright_side & is_dark_pixel;
    wire use_gray_2 = is_edge_2 & is_low_saturation & has_bright_side & is_dark_pixel;
    wire use_gray_3 = is_edge_3 & is_low_saturation & has_bright_side & is_dark_pixel;

    // 1-bit output: just MSB (binary dithering) - uses CFA bias
    wire [3:0] bayer_out_1b = {c0[3], c1[3], c2[3], c3[3]};

    // 2-bit output: top 2 bits (4-level dithering) - plain BIAS
    wire [7:0] bayer_out_2b = {c0_2b[3:2], c1_2b[3:2], c2_2b[3:2], c3_2b[3:2]};

    // For backward compatibility, keep bayer_out as 1-bit
    wire [3:0] bayer_out = bayer_out_1b;

    // =========================================================================
    // Simple Threshold Path (for edges - no dithering)
    // =========================================================================

    // 1-bit: MSB threshold
    wire [3:0] simple_out_1b = {pix0[7], pix1[7], pix2[7], pix3[7]};
    // 2-bit: top 2 bits (4 levels) - apply W_DARKEN to W subpixels for consistency
    wire [7:0] pix1_dark_simple = (pix1 > {4'd0, W_DARKEN}) ? (pix1 - {4'd0, W_DARKEN}) : 8'd0;
    wire [7:0] pix3_dark_simple = (pix3 > {4'd0, W_DARKEN}) ? (pix3 - {4'd0, W_DARKEN}) : 8'd0;
    wire [1:0] simple_02 = pix0[7:6];  // B or G - no darkening
    wire [1:0] simple_13 = (cfa_row == 1'b0) ? pix1_dark_simple[7:6] : pix1[7:6];  // W darkened, R natural
    wire [1:0] simple_22 = pix2[7:6];  // B or G - no darkening
    wire [1:0] simple_33 = (cfa_row == 1'b0) ? pix3_dark_simple[7:6] : pix3[7:6];  // W darkened, R natural
    wire [7:0] simple_out_2b = {simple_02, simple_13, simple_22, simple_33};
    // For backward compatibility
    wire [3:0] simple_out = simple_out_1b;

    // =========================================================================
    // Edge Detection - Horizontal (same-color comparison)
    // RGBW pattern: Row0=B,W,B,W  Row1=G,R,G,R
    // Compare each pixel to the same-color pixel 2 positions back
    //   pix0 <- prev_pix2 (same color)
    //   pix1 <- prev_pix3 (same color)
    //   pix2 <- pix0 (same color)
    //   pix3 <- pix1 (same color)
    // =========================================================================
    
    reg [31:0] prev_vin;
    always @(posedge clk) begin
        prev_vin <= vin;
    end
    
    wire [7:0] prev_pix0 = prev_vin[31:24];
    wire [7:0] prev_pix1 = prev_vin[23:16];
    wire [7:0] prev_pix2 = prev_vin[15:8];
    wire [7:0] prev_pix3 = prev_vin[7:0];
    
    // Same-color horizontal differences (2 pixels apart)
    wire [7:0] h_diff_0 = (pix0 > prev_pix2) ? (pix0 - prev_pix2) : (prev_pix2 - pix0);
    wire [7:0] h_diff_1 = (pix1 > prev_pix3) ? (pix1 - prev_pix3) : (prev_pix3 - pix1);
    wire [7:0] h_diff_2 = (pix2 > pix0) ? (pix2 - pix0) : (pix0 - pix2);
    wire [7:0] h_diff_3 = (pix3 > pix1) ? (pix3 - pix1) : (pix1 - pix3);

    // =========================================================================
    // Edge Detection - Vertical (same-color comparison, 2 lines back)
    // Since rows alternate BW/GR, same color is 2 lines back
    // We need two line buffers to store 2 previous lines
    // =========================================================================
    
    localparam LINE_BUF_DEPTH = (LINE_WIDTH_MAX + 3) / 4;
    localparam LINE_BUF_AW = clog2(LINE_BUF_DEPTH);
    
    // Two line buffers for 2-line lookback
    // Use block RAM to save LUTs (distributed RAM was causing FPGA to not fit)
    (* ram_style = "block" *)
    reg [31:0] line_buffer_0 [0:LINE_BUF_DEPTH-1];  // Previous line (n-1)
    (* ram_style = "block" *)
    reg [31:0] line_buffer_1 [0:LINE_BUF_DEPTH-1];  // Line before that (n-2, same color)
    
    // x_cnt already counts 4-pixel groups (one per clock), so use directly
    wire [LINE_BUF_AW-1:0] line_buf_addr = x_cnt[LINE_BUF_AW-1:0];
    
    // Read from line buffer (n-2 has same color as current line)
    wire [31:0] prev2_line_pixels = line_buffer_1[line_buf_addr];     // n-2 (same color)
    
    wire [7:0] prev2_line_pix0 = prev2_line_pixels[31:24];
    wire [7:0] prev2_line_pix1 = prev2_line_pixels[23:16];
    wire [7:0] prev2_line_pix2 = prev2_line_pixels[15:8];
    wire [7:0] prev2_line_pix3 = prev2_line_pixels[7:0];
    
    // Cascade write: current -> buffer_0 -> buffer_1
    always @(posedge clk) begin
        line_buffer_1[line_buf_addr] <= line_buffer_0[line_buf_addr];
        line_buffer_0[line_buf_addr] <= vin;
    end
    
    // Same-color vertical differences (2 lines back)
    wire [7:0] v_diff_0 = (pix0 > prev2_line_pix0) ? (pix0 - prev2_line_pix0) : (prev2_line_pix0 - pix0);
    wire [7:0] v_diff_1 = (pix1 > prev2_line_pix1) ? (pix1 - prev2_line_pix1) : (prev2_line_pix1 - pix1);
    wire [7:0] v_diff_2 = (pix2 > prev2_line_pix2) ? (pix2 - prev2_line_pix2) : (prev2_line_pix2 - pix2);
    wire [7:0] v_diff_3 = (pix3 > prev2_line_pix3) ? (pix3 - prev2_line_pix3) : (prev2_line_pix3 - pix3);

    // =========================================================================
    // Edge Detection - Diagonal (same-color comparison)
    // Same color diagonally: 2 pixels horizontal + 2 lines vertical
    // Upper-left diagonal: compare to (x-2, y-2)
    // Upper-right diagonal: compare to (x+2, y-2)
    // =========================================================================
    
    // Buffer previous 4-pixel group from 2 lines back for diagonal access
    reg [31:0] prev_prev2_line_pixels;
    always @(posedge clk) begin
        prev_prev2_line_pixels <= prev2_line_pixels;
    end
    
    wire [7:0] prev_prev2_pix0 = prev_prev2_line_pixels[31:24];
    wire [7:0] prev_prev2_pix1 = prev_prev2_line_pixels[23:16];
    wire [7:0] prev_prev2_pix2 = prev_prev2_line_pixels[15:8];
    wire [7:0] prev_prev2_pix3 = prev_prev2_line_pixels[7:0];
    
    // Upper-left diagonal (x-2, y-2) - same color
    // pix0, pix1: need previous group from 2 lines back (prev_prev2)
    // pix2, pix3: need current group from 2 lines back (prev2_line)
    wire [7:0] d_ul_diff_0 = (pix0 > prev_prev2_pix2) ? (pix0 - prev_prev2_pix2) : (prev_prev2_pix2 - pix0);
    wire [7:0] d_ul_diff_1 = (pix1 > prev_prev2_pix3) ? (pix1 - prev_prev2_pix3) : (prev_prev2_pix3 - pix1);
    wire [7:0] d_ul_diff_2 = (pix2 > prev2_line_pix0) ? (pix2 - prev2_line_pix0) : (prev2_line_pix0 - pix2);
    wire [7:0] d_ul_diff_3 = (pix3 > prev2_line_pix1) ? (pix3 - prev2_line_pix1) : (prev2_line_pix1 - pix3);
    
    // Upper-right diagonal (x+2, y-2) - same color
    // Only available for pix0 and pix1 (pix2/pix3 would need next 4-pixel group)
    wire [7:0] d_ur_diff_0 = (pix0 > prev2_line_pix2) ? (pix0 - prev2_line_pix2) : (prev2_line_pix2 - pix0);
    wire [7:0] d_ur_diff_1 = (pix1 > prev2_line_pix3) ? (pix1 - prev2_line_pix3) : (prev2_line_pix3 - pix1);

    // =========================================================================
    // Maximum Gradient Calculation (for soft blending)
    // Find the maximum gradient across all directions for each pixel
    // (uses max2 function defined earlier in grayscale section)
    // =========================================================================

    // Calculate max gradient for each pixel across all directions
    // pix0, pix1: have both upper-left and upper-right diagonals
    // pix2, pix3: only have upper-left diagonal (upper-right would need next group)
    wire [7:0] max_grad_0 = max2(max2(h_diff_0, v_diff_0), max2(d_ul_diff_0, d_ur_diff_0));
    wire [7:0] max_grad_1 = max2(max2(h_diff_1, v_diff_1), max2(d_ul_diff_1, d_ur_diff_1));
    wire [7:0] max_grad_2 = max2(max2(h_diff_2, v_diff_2), d_ul_diff_2);
    wire [7:0] max_grad_3 = max2(max2(h_diff_3, v_diff_3), d_ul_diff_3);

    // =========================================================================
    // Soft Edge Detection with Gradient-Weighted Blending
    // 
    // Instead of binary edge detection, we use 3 zones:
    // - Below EDGE_THRESH_LOW: Full dithering (smooth image areas)
    // - Above EDGE_THRESH_HIGH: Full simple threshold (sharp text edges)
    // - Between: Probabilistic blend based on gradient strength
    //
    // For the transition zone, we use the Bayer matrix position as a
    // spatial dither to decide between dithered and simple output.
    // This creates a smooth visual transition without visible stripes.
    // =========================================================================
    
    // Calculate blend threshold for transition zone
    // When gradient is in transition zone, compare against spatially-varying threshold
    // This uses existing Bayer offsets to create smooth spatial dithering of the blend
    
    // Normalize gradient to transition zone (0 = low thresh, 255 = high thresh)
    // Then compare against position-dependent threshold
    
    localparam [7:0] THRESH_RANGE = EDGE_THRESH_HIGH - EDGE_THRESH_LOW;
    
    // For each pixel, determine if we should use simple output
    // In transition zone: use spatial dithering based on x/y position
    // This avoids coherent stripe artifacts
    
    // Spatial threshold varies based on position (using lower bits of coordinates)
    // Creates 4x4 pattern for smooth blending
    wire [3:0] spatial_phase = {y_pos[1:0], x_pos[1:0]};
    
    // Map spatial phase to threshold offset (0-15 maps to 0-THRESH_RANGE)
    // This creates a Bayer-like pattern for the blend decision
    wire [7:0] spatial_thresh_offset = (spatial_phase * THRESH_RANGE) >> 4;
    wire [7:0] adaptive_thresh = EDGE_THRESH_LOW + spatial_thresh_offset;
    
    // Edge decision with soft blending:
    // - Hard edge (simple) if gradient >= EDGE_THRESH_HIGH
    // - Hard dither if gradient < EDGE_THRESH_LOW  
    // - Spatially-dithered blend in between
    wire use_simple_0 = (max_grad_0 >= EDGE_THRESH_HIGH) || 
                        ((max_grad_0 >= EDGE_THRESH_LOW) && (max_grad_0 >= adaptive_thresh));
    wire use_simple_1 = (max_grad_1 >= EDGE_THRESH_HIGH) || 
                        ((max_grad_1 >= EDGE_THRESH_LOW) && (max_grad_1 >= adaptive_thresh));
    wire use_simple_2 = (max_grad_2 >= EDGE_THRESH_HIGH) || 
                        ((max_grad_2 >= EDGE_THRESH_LOW) && (max_grad_2 >= adaptive_thresh));
    wire use_simple_3 = (max_grad_3 >= EDGE_THRESH_HIGH) || 
                        ((max_grad_3 >= EDGE_THRESH_LOW) && (max_grad_3 >= adaptive_thresh));

    // =========================================================================
    // Output MUX: Select dithered or simple based on soft edge detection
    // =========================================================================

    generate
        if (OUTPUT_BITS == 1) begin: gen_1bit_out
            wire [3:0] final_out;
            assign final_out[3] = use_simple_0 ? simple_out_1b[3] : bayer_out_1b[3];
            assign final_out[2] = use_simple_1 ? simple_out_1b[2] : bayer_out_1b[2];
            assign final_out[1] = use_simple_2 ? simple_out_1b[1] : bayer_out_1b[1];
            assign final_out[0] = use_simple_3 ? simple_out_1b[0] : bayer_out_1b[0];

            always @(posedge clk) begin
                if (rst)
                    vout <= 4'b0;
                else
                    vout <= final_out;
            end
        end
        else begin: gen_2bit_out
            // 2-bit per pixel = 8 bits total for 4 pixels
            // Two paths (matches bayer_dither_4level_edge_aware_no_simple):
            // 1. Grayscale (200dpi): for black text on white (edge + low sat + bright bg + dark pixel)
            // 2. CFA Bayer dither: for everything else
            wire [1:0] out0 = (pix0 >= 8'd250) ? 2'b11 : (pix0 <= 8'd5) ? 2'b00 :
                              use_gray_0 ? c0_gray[3:2] : c0_2b[3:2];
            wire [1:0] out1 = (pix1 >= 8'd250) ? 2'b11 : (pix1 <= 8'd5) ? 2'b00 :
                              use_gray_1 ? c1_gray[3:2] : c1_2b[3:2];
            wire [1:0] out2 = (pix2 >= 8'd250) ? 2'b11 : (pix2 <= 8'd5) ? 2'b00 :
                              use_gray_2 ? c2_gray[3:2] : c2_2b[3:2];
            wire [1:0] out3 = (pix3 >= 8'd250) ? 2'b11 : (pix3 <= 8'd5) ? 2'b00 :
                              use_gray_3 ? c3_gray[3:2] : c3_2b[3:2];
            wire [7:0] final_out = {out0, out1, out2, out3};

            always @(posedge clk) begin
                if (rst)
                    vout <= 8'b0;
                else
                    vout <= final_out;
            end
        end
    endgenerate

endmodule

`default_nettype wire
