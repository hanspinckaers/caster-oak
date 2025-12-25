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
    parameter LINE_WIDTH_MAX = 2200,  // Max pixels per line (compile-time buffer sizing)
    parameter EDGE_THRESH_LOW = 80,   // Below this: full dithering (smooth gradients)
    parameter EDGE_THRESH_HIGH = 160, // Above this: full simple threshold (sharp text)
    // CFA threshold bias - for equal perceived thickness (1-bit path only)
    // W=high (stays black more, counters brightness)
    // B/G/R=low (turns white more, counters dimness)
    parameter CFA_BIAS_B = 20,        // Blue - easy to turn ON
    parameter CFA_BIAS_W = 50,        // White - hard to turn ON
    parameter CFA_BIAS_G = 20,        // Green - easy to turn ON
    parameter CFA_BIAS_R = 20,        // Red - easy to turn ON
    parameter FATTEN = 0,             // Lower threshold globally (fatter text, 0-20)
    parameter W_DARKEN = 4'd0         // Darken W subpixels in 2-bit simple path
) (
    input wire                       clk,
    input wire                       rst,
    input wire [31:0]                vin,
    output reg [3:0]                 vout_1b,    // 1-bit per pixel (FAST_MONO) - uses 3x3
    output reg [7:0]                 vout_2b,    // 2-bit per pixel (FAST_GREY) - uses 8x8
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
    // 8x8 Bayer Matrix for 2-bit path (FAST_GREY) - Smooth gradients
    // Standard ordered dither pattern normalized to 4-bit signed (-8 to +7)
    // Larger matrix = smoother gradients with less visible pattern
    // =========================================================================

    // Column addressing: x_pos[0] selects first/second half of 8-pixel cycle
    // Group 0,2,4...: columns 0,1,2,3 | Group 1,3,5...: columns 4,5,6,7
    wire [2:0] bayer8_row = y_cnt[2:0];
    wire [2:0] bayer8_col0 = {x_pos[0], 2'b00};  // 0 or 4
    wire [2:0] bayer8_col1 = {x_pos[0], 2'b01};  // 1 or 5
    wire [2:0] bayer8_col2 = {x_pos[0], 2'b10};  // 2 or 6
    wire [2:0] bayer8_col3 = {x_pos[0], 2'b11};  // 3 or 7

    // 8x8 Bayer lookup - standard ordered dither normalized to -8..+7
    // Note: Not CFA-balanced, but has superior spatial distribution
    // Brightness compensation done via BIAS_2B parameter
    function [3:0] bayer8x8_lookup;
        input [2:0] row;
        input [2:0] col;
        begin
            case ({row, col})
                // Row 0
                6'b000_000: bayer8x8_lookup = -4'sd8;
                6'b000_001: bayer8x8_lookup =  4'sd0;
                6'b000_010: bayer8x8_lookup = -4'sd6;
                6'b000_011: bayer8x8_lookup =  4'sd2;
                6'b000_100: bayer8x8_lookup = -4'sd7;
                6'b000_101: bayer8x8_lookup =  4'sd1;
                6'b000_110: bayer8x8_lookup = -4'sd5;
                6'b000_111: bayer8x8_lookup =  4'sd3;
                // Row 1
                6'b001_000: bayer8x8_lookup =  4'sd4;
                6'b001_001: bayer8x8_lookup = -4'sd4;
                6'b001_010: bayer8x8_lookup =  4'sd6;
                6'b001_011: bayer8x8_lookup = -4'sd2;
                6'b001_100: bayer8x8_lookup =  4'sd5;
                6'b001_101: bayer8x8_lookup = -4'sd3;
                6'b001_110: bayer8x8_lookup =  4'sd7;
                6'b001_111: bayer8x8_lookup = -4'sd1;
                // Row 2
                6'b010_000: bayer8x8_lookup = -4'sd5;
                6'b010_001: bayer8x8_lookup =  4'sd3;
                6'b010_010: bayer8x8_lookup = -4'sd7;
                6'b010_011: bayer8x8_lookup =  4'sd1;
                6'b010_100: bayer8x8_lookup = -4'sd4;
                6'b010_101: bayer8x8_lookup =  4'sd4;
                6'b010_110: bayer8x8_lookup = -4'sd6;
                6'b010_111: bayer8x8_lookup =  4'sd2;
                // Row 3
                6'b011_000: bayer8x8_lookup =  4'sd7;
                6'b011_001: bayer8x8_lookup = -4'sd1;
                6'b011_010: bayer8x8_lookup =  4'sd5;
                6'b011_011: bayer8x8_lookup = -4'sd3;
                6'b011_100: bayer8x8_lookup =  4'sd6;
                6'b011_101: bayer8x8_lookup = -4'sd2;
                6'b011_110: bayer8x8_lookup =  4'sd4;
                6'b011_111: bayer8x8_lookup = -4'sd4;
                // Row 4
                6'b100_000: bayer8x8_lookup = -4'sd7;
                6'b100_001: bayer8x8_lookup =  4'sd1;
                6'b100_010: bayer8x8_lookup = -4'sd5;
                6'b100_011: bayer8x8_lookup =  4'sd3;
                6'b100_100: bayer8x8_lookup = -4'sd8;
                6'b100_101: bayer8x8_lookup =  4'sd0;
                6'b100_110: bayer8x8_lookup = -4'sd6;
                6'b100_111: bayer8x8_lookup =  4'sd2;
                // Row 5
                6'b101_000: bayer8x8_lookup =  4'sd5;
                6'b101_001: bayer8x8_lookup = -4'sd3;
                6'b101_010: bayer8x8_lookup =  4'sd7;
                6'b101_011: bayer8x8_lookup = -4'sd1;
                6'b101_100: bayer8x8_lookup =  4'sd4;
                6'b101_101: bayer8x8_lookup = -4'sd4;
                6'b101_110: bayer8x8_lookup =  4'sd6;
                6'b101_111: bayer8x8_lookup = -4'sd2;
                // Row 6
                6'b110_000: bayer8x8_lookup = -4'sd4;
                6'b110_001: bayer8x8_lookup =  4'sd4;
                6'b110_010: bayer8x8_lookup = -4'sd6;
                6'b110_011: bayer8x8_lookup =  4'sd2;
                6'b110_100: bayer8x8_lookup = -4'sd5;
                6'b110_101: bayer8x8_lookup =  4'sd3;
                6'b110_110: bayer8x8_lookup = -4'sd7;
                6'b110_111: bayer8x8_lookup =  4'sd1;
                // Row 7
                6'b111_000: bayer8x8_lookup =  4'sd6;
                6'b111_001: bayer8x8_lookup = -4'sd2;
                6'b111_010: bayer8x8_lookup =  4'sd4;
                6'b111_011: bayer8x8_lookup = -4'sd4;
                6'b111_100: bayer8x8_lookup =  4'sd7;
                6'b111_101: bayer8x8_lookup = -4'sd1;
                6'b111_110: bayer8x8_lookup =  4'sd5;
                6'b111_111: bayer8x8_lookup = -4'sd3;
                default: bayer8x8_lookup =  4'sd0;
            endcase
        end
    endfunction

    wire [3:0] b0_8x8 = bayer8x8_lookup(bayer8_row, bayer8_col0);
    wire [3:0] b1_8x8 = bayer8x8_lookup(bayer8_row, bayer8_col1);
    wire [3:0] b2_8x8 = bayer8x8_lookup(bayer8_row, bayer8_col2);
    wire [3:0] b3_8x8 = bayer8x8_lookup(bayer8_row, bayer8_col3);

    // Halved 8x8 Bayer offsets for reduced dither range (less stripy)
    // Arithmetic right shift: {sign, sign, [3:1]} = value/2
    wire [3:0] b0_8x8_half = {b0_8x8[3], b0_8x8[3:1]};
    wire [3:0] b1_8x8_half = {b1_8x8[3], b1_8x8[3:1]};
    wire [3:0] b2_8x8_half = {b2_8x8[3], b2_8x8[3:1]};
    wire [3:0] b3_8x8_half = {b3_8x8[3], b3_8x8[3:1]};

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

    // =========================================================================
    // Filter-Compensated Vector Dithering for 2-bit RGBW (FAST_GREY)
    //
    // Exploits gray-behind-CFA physics on REFLECTIVE displays:
    //   Reflectance (gray level) × Filter = Colored light output
    //
    //   Example: Red filter
    //     - B(00) behind R filter = BLACK (no light to reflect)
    //     - DG(01) behind R filter = very dark red
    //     - LG(10) behind R filter = medium red
    //     - W(11) behind R filter = bright saturated red
    //
    //   Palette structure:
    //     - 13 distinct primaries:
    //       • 1 black (B(00) behind any filter)
    //       • 3 blues (DG/LG/W behind B filter)
    //       • 3 greens (DG/LG/W behind G filter)
    //       • 3 reds (DG/LG/W behind R filter)
    //       • 3 grays (DG/LG/W behind W filter)
    //     - 256 combinations per 2×2 CFA quad (4 positions × 4 gray levels)
    //     - Thousands of effective colors via 8×8 spatial dithering + additive mixing
    //
    // Algorithm (for grayscale Y8 input → neutral gray):
    //   1. Filter compensation: Balance RGB contributions for achromatic output
    //      - Blue (k=0.10 dim) needs brighter gray for equal RGB contribution
    //      - Green (k=0.60) needs moderate gray
    //      - Red (k=0.30) needs bright gray
    //      - White (k=1.00) carries achromatic luminance
    //   2. Luminance balancing: Ensure total brightness matches Y8 target
    //   3. Independent dithering: Each subpixel to 2-bit, mix additively
    //
    // Result: Neutral grayscale exploiting full 256-combination palette
    // Future: RGB color input → saturated colors via unequal channel levels
    // =========================================================================

    // Filter transmission coefficients (scaled by 256)
    // These represent how much light passes through each filter
    localparam [7:0] K_B = 8'd26;   // Blue: 0.10 × 256 (very dim)
    localparam [7:0] K_G = 8'd154;  // Green: 0.60 × 256 (medium)
    localparam [7:0] K_R = 8'd77;   // Red: 0.30 × 256 (dimmer)
    localparam [7:0] K_W = 8'd256;  // White: 1.00 × 256 (special case, full brightness)

    // Step 1: Filter compensation
    // To achieve neutral gray at luminance Y, each subpixel needs different gray level
    // Perceived_luminance = gray_level × filter_transmission
    // Therefore: gray_level = Y / filter_transmission
    //
    // Use square root compensation to avoid excessive saturation:
    // gray_level ≈ Y × sqrt(1/k) = Y / sqrt(k)
    // This gives partial compensation with better headroom

    // Sqrt inverse approximations (×256 for fixed point)
    // sqrt(1/0.10) ≈ 3.16 → 809
    // sqrt(1/0.60) ≈ 1.29 → 330
    // sqrt(1/0.30) ≈ 1.83 → 468
    // sqrt(1/1.00) = 1.00 → 256
    localparam [15:0] SQRT_INV_K_B = 16'd809;   // Strong compensation for blue
    localparam [15:0] SQRT_INV_K_G = 16'd330;   // Mild compensation for green
    localparam [15:0] SQRT_INV_K_R = 16'd468;   // Medium compensation for red
    localparam [15:0] SQRT_INV_K_W = 16'd256;   // No compensation for white

    // Compute compensated targets per pixel based on CFA position
    // Row 0: B(even), W(odd)  |  Row 1: G(even), R(odd)

    // Multiply Y8 × sqrt_inv_k (both scaled by 256, so result >> 8)
    wire [15:0] comp0_raw = (cfa_row == 1'b0) ?
                            (pix0 * SQRT_INV_K_B[9:2]) :  // Blue compensation
                            (pix0 * SQRT_INV_K_G[9:2]);   // Green compensation
    wire [15:0] comp1_raw = (cfa_row == 1'b0) ?
                            (pix1 * SQRT_INV_K_W[9:2]) :  // White (none)
                            (pix1 * SQRT_INV_K_R[9:2]);   // Red compensation
    wire [15:0] comp2_raw = (cfa_row == 1'b0) ?
                            (pix2 * SQRT_INV_K_B[9:2]) :  // Blue
                            (pix2 * SQRT_INV_K_G[9:2]);   // Green
    wire [15:0] comp3_raw = (cfa_row == 1'b0) ?
                            (pix3 * SQRT_INV_K_W[9:2]) :  // White
                            (pix3 * SQRT_INV_K_R[9:2]);   // Red

    // Saturate at 255
    wire [7:0] target0_comp = (comp0_raw[15:8] != 0) ? 8'd255 : comp0_raw[7:0];
    wire [7:0] target1_comp = (comp1_raw[15:8] != 0) ? 8'd255 : comp1_raw[7:0];
    wire [7:0] target2_comp = (comp2_raw[15:8] != 0) ? 8'd255 : comp2_raw[7:0];
    wire [7:0] target3_comp = (comp3_raw[15:8] != 0) ? 8'd255 : comp3_raw[7:0];

    // Step 2: Luminance balancing
    // Check if total perceived luminance matches target
    // Y_perceived = (k0×g0 + k1×g1 + k2×g2 + k3×g3) / (k0+k1+k2+k3)

    wire [7:0] k0 = (cfa_row == 1'b0) ? K_B : K_G;
    wire [7:0] k1 = (cfa_row == 1'b0) ? K_W : K_R;
    wire [7:0] k2 = (cfa_row == 1'b0) ? K_B : K_G;
    wire [7:0] k3 = (cfa_row == 1'b0) ? K_W : K_R;

    // Weighted contributions (16-bit products)
    wire [15:0] lum0 = target0_comp * k0;  // Y × k
    wire [15:0] lum1 = target1_comp * k1;
    wire [15:0] lum2 = target2_comp * k2;
    wire [15:0] lum3 = target3_comp * k3;
    wire [17:0] lum_total = {2'b0, lum0} + {2'b0, lum1} + {2'b0, lum2} + {2'b0, lum3};

    // Target luminance: average of input pixels
    wire [9:0] target_lum_sum = {2'b0, pix0} + {2'b0, pix1} + {2'b0, pix2} + {2'b0, pix3};
    wire [7:0] target_lum_avg = target_lum_sum[9:2];  // ÷4

    // Current perceived average (divide by 4, account for k scaling)
    // lum_total is sum of (Y×k), need to divide by (sum of k) ≈ 512, then by 4
    // lum_total >> 10 gives average Y
    wire [7:0] current_lum_avg = lum_total[17:10];

    // Error signal (signed)
    wire signed [8:0] lum_error = {1'b0, target_lum_avg} - {1'b0, current_lum_avg};

    // Apply correction globally (scale and distribute)
    wire signed [9:0] correction = lum_error <<< 1;  // ×2 for stronger correction

    // Saturating signed add
    function [7:0] apply_correction;
        input [7:0] value;
        input signed [9:0] corr;
        reg signed [9:0] result;
        begin
            result = $signed({2'b0, value}) + corr;
            if (result < 0)
                apply_correction = 8'd0;
            else if (result > 255)
                apply_correction = 8'd255;
            else
                apply_correction = result[7:0];
        end
    endfunction

    // Final balanced targets
    wire [7:0] target0_final = apply_correction(target0_comp, correction);
    wire [7:0] target1_final = apply_correction(target1_comp, correction);
    wire [7:0] target2_final = apply_correction(target2_comp, correction);
    wire [7:0] target3_final = apply_correction(target3_comp, correction);

    // Step 3: Independent dithering to 2-bit per channel
    wire [8:0] a0_indep = {1'b0, target0_final};
    wire [8:0] a1_indep = {1'b0, target1_final};
    wire [8:0] a2_indep = {1'b0, target2_final};
    wire [8:0] a3_indep = {1'b0, target3_final};

    wire [3:0] c0_indep, c1_indep, c2_indep, c3_indep;
    adder_sat adder_sat0_indep (a0_indep[8:4], b0_8x8_half, c0_indep);
    adder_sat adder_sat1_indep (a1_indep[8:4], b1_8x8_half, c1_indep);
    adder_sat adder_sat2_indep (a2_indep[8:4], b2_8x8_half, c2_indep);
    adder_sat adder_sat3_indep (a3_indep[8:4], b3_8x8_half, c3_indep);

    // 2-bit path: per-CFA brightness bias for FAST_GREY (legacy path, kept for compatibility)
    // Compensates for 8x8 Bayer matrix CFA imbalance:
    // B avg=-5.7, W avg=+1.9, G avg=+5.6, R avg=-1.9
    // Add inverse to each CFA color to neutralize
    localparam [7:0] BIAS_2B = 8'd15;      // Base brightness boost
    localparam [7:0] BIAS_2B_B = BIAS_2B + 8'd6;   // B needs +6 (was darkened by -5.7)
    localparam [7:0] BIAS_2B_W = BIAS_2B - 8'd2;   // W needs -2 (was brightened by +1.9)
    localparam [7:0] BIAS_2B_G = BIAS_2B - 8'd6;   // G needs -6 (was brightened by +5.6)
    localparam [7:0] BIAS_2B_R = BIAS_2B + 8'd2;   // R needs +2 (was darkened by -1.9)

    // Select bias based on CFA position (cfa_row: 0=BW, 1=GR)
    wire [7:0] bias_2b_02 = (cfa_row == 1'b0) ? BIAS_2B_B : BIAS_2B_G;  // B or G
    wire [7:0] bias_2b_13 = (cfa_row == 1'b0) ? BIAS_2B_W : BIAS_2B_R;  // W or R

    wire [8:0] a0_2b = {1'b0, pix0} + {1'b0, bias_2b_02};
    wire [8:0] a1_2b = {1'b0, pix1} + {1'b0, bias_2b_13};
    wire [8:0] a2_2b = {1'b0, pix2} + {1'b0, bias_2b_02};
    wire [8:0] a3_2b = {1'b0, pix3} + {1'b0, bias_2b_13};

    wire [3:0] c0_2b, c1_2b, c2_2b, c3_2b;
    // Use 8x8 Bayer with halved offsets for smooth gradients
    adder_sat adder_sat0_2b (a0_2b[8:4], b0_8x8_half, c0_2b);
    adder_sat adder_sat1_2b (a1_2b[8:4], b1_8x8_half, c1_2b);
    adder_sat adder_sat2_2b (a2_2b[8:4], b2_8x8_half, c2_2b);
    adder_sat adder_sat3_2b (a3_2b[8:4], b3_8x8_half, c3_2b);

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
    // Also apply BIAS_2B for consistent brightness with CFA path
    wire [8:0] a0_gray = {1'b0, luminance} + {1'b0, BIAS_2B};
    wire [8:0] a1_gray = (cfa_row == 1'b0) ? ({1'b0, lum_for_w} + {1'b0, BIAS_2B}) : ({1'b0, luminance} + {1'b0, BIAS_2B});
    wire [8:0] a2_gray = {1'b0, luminance} + {1'b0, BIAS_2B};
    wire [8:0] a3_gray = (cfa_row == 1'b0) ? ({1'b0, lum_for_w} + {1'b0, BIAS_2B}) : ({1'b0, luminance} + {1'b0, BIAS_2B});

    wire [3:0] c0_gray, c1_gray, c2_gray, c3_gray;
    // Use 8x8 Bayer with halved offsets (same as CFA path)
    adder_sat adder_sat0_gray (a0_gray[8:4], b0_8x8_half, c0_gray);
    adder_sat adder_sat1_gray (a1_gray[8:4], b1_8x8_half, c1_gray);
    adder_sat adder_sat2_gray (a2_gray[8:4], b2_8x8_half, c2_gray);
    adder_sat adder_sat3_gray (a3_gray[8:4], b3_8x8_half, c3_gray);

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
    // Output: Always compute both 1-bit and 2-bit paths
    // =========================================================================

    // 1-bit output (3x3 Bayer with CFA bias) - for FAST_MONO
    wire [3:0] final_out_1b;
    assign final_out_1b[3] = use_simple_0 ? simple_out_1b[3] : bayer_out_1b[3];
    assign final_out_1b[2] = use_simple_1 ? simple_out_1b[2] : bayer_out_1b[2];
    assign final_out_1b[1] = use_simple_2 ? simple_out_1b[1] : bayer_out_1b[1];
    assign final_out_1b[0] = use_simple_3 ? simple_out_1b[0] : bayer_out_1b[0];

    // 2-bit output (8x8 smooth Bayer) - for FAST_GREY
    // Two paths:
    // 1. Grayscale (200dpi): for black text on white (edge + low sat + bright bg + dark pixel)
    // 2. Independent per-channel: exploits full combinatorial palette (default)
    wire [1:0] out0_2b = (pix0 >= 8'd250) ? 2'b11 : (pix0 <= 8'd5) ? 2'b00 :
                         use_gray_0 ? c0_gray[3:2] : c0_indep[3:2];
    wire [1:0] out1_2b = (pix1 >= 8'd250) ? 2'b11 : (pix1 <= 8'd5) ? 2'b00 :
                         use_gray_1 ? c1_gray[3:2] : c1_indep[3:2];
    wire [1:0] out2_2b = (pix2 >= 8'd250) ? 2'b11 : (pix2 <= 8'd5) ? 2'b00 :
                         use_gray_2 ? c2_gray[3:2] : c2_indep[3:2];
    wire [1:0] out3_2b = (pix3 >= 8'd250) ? 2'b11 : (pix3 <= 8'd5) ? 2'b00 :
                         use_gray_3 ? c3_gray[3:2] : c3_indep[3:2];
    wire [7:0] final_out_2b = {out0_2b, out1_2b, out2_2b, out3_2b};

    always @(posedge clk) begin
        if (rst) begin
            vout_1b <= 4'b0;
            vout_2b <= 8'b0;
        end else begin
            vout_1b <= final_out_1b;
            vout_2b <= final_out_2b;
        end
    end

endmodule

`default_nettype wire
