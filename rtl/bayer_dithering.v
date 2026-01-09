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
// 1. Original 3x3 Bayer matrix for 1-bit path (FAST_MONO)
// 2. Per-CFA balanced 8x8 matrix with content-adaptive offsets for 2-bit path (FAST_GREY)
//    - Each CFA color (B,W,G,R) gets independent phase-shifted 4x4 Bayer pattern
//    - Content-adaptive: halved offsets for text/edges, full for smooth gradients
//    - See docs/PER_CFA_DITHERING.md for derivation
// 3. Gradient-weighted edge detection with soft blending
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
    input wire [31:0]                vin,        // Input for 2-bit path (FAST_GREY)
    input wire [31:0]                vin_1b,     // Input for 1-bit path (FAST_MONO) - can use different degamma
    input wire [3:0]                 is_colored_in, // True RGB saturation flags from vin_colormixer
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
    // Per-CFA Balanced 8x8 Bayer Matrix
    // Each CFA color (B,W,G,R) sees an independent phase-shifted 4x4 Bayer
    // This eliminates CFA color bias without needing per-color bias hacks
    // See docs/PER_CFA_DITHERING.md for derivation
    // =========================================================================

    function [3:0] bayer8x8_cfa_lookup;
        input [2:0] row;
        input [2:0] col;
        begin
            // GRBW phase order: G=0, R=4, B=8, W=12
            // G activates first (phase 0), then R, B, W last
            case ({row, col})
                // Row 0: B=0, W=4, B=-8, W=-4, B=2, W=6, B=-6, W=-2
                6'b000_000: bayer8x8_cfa_lookup =  4'sd0;
                6'b000_001: bayer8x8_cfa_lookup =  4'sd4;
                6'b000_010: bayer8x8_cfa_lookup = -4'sd8;
                6'b000_011: bayer8x8_cfa_lookup = -4'sd4;
                6'b000_100: bayer8x8_cfa_lookup =  4'sd2;
                6'b000_101: bayer8x8_cfa_lookup =  4'sd6;
                6'b000_110: bayer8x8_cfa_lookup = -4'sd6;
                6'b000_111: bayer8x8_cfa_lookup = -4'sd2;
                // Row 1: G=-8, R=-4, G=0, R=4, G=-6, R=-2, G=2, R=6
                6'b001_000: bayer8x8_cfa_lookup = -4'sd8;
                6'b001_001: bayer8x8_cfa_lookup = -4'sd4;
                6'b001_010: bayer8x8_cfa_lookup =  4'sd0;
                6'b001_011: bayer8x8_cfa_lookup =  4'sd4;
                6'b001_100: bayer8x8_cfa_lookup = -4'sd6;
                6'b001_101: bayer8x8_cfa_lookup = -4'sd2;
                6'b001_110: bayer8x8_cfa_lookup =  4'sd2;
                6'b001_111: bayer8x8_cfa_lookup =  4'sd6;
                // Row 2: B=-4, W=0, B=4, W=-8, B=-2, W=2, B=6, W=-6
                6'b010_000: bayer8x8_cfa_lookup = -4'sd4;
                6'b010_001: bayer8x8_cfa_lookup =  4'sd0;
                6'b010_010: bayer8x8_cfa_lookup =  4'sd4;
                6'b010_011: bayer8x8_cfa_lookup = -4'sd8;
                6'b010_100: bayer8x8_cfa_lookup = -4'sd2;
                6'b010_101: bayer8x8_cfa_lookup =  4'sd2;
                6'b010_110: bayer8x8_cfa_lookup =  4'sd6;
                6'b010_111: bayer8x8_cfa_lookup = -4'sd6;
                // Row 3: G=4, R=-8, G=-4, R=0, G=6, R=-6, G=-2, R=2
                6'b011_000: bayer8x8_cfa_lookup =  4'sd4;
                6'b011_001: bayer8x8_cfa_lookup = -4'sd8;
                6'b011_010: bayer8x8_cfa_lookup = -4'sd4;
                6'b011_011: bayer8x8_cfa_lookup =  4'sd0;
                6'b011_100: bayer8x8_cfa_lookup =  4'sd6;
                6'b011_101: bayer8x8_cfa_lookup = -4'sd6;
                6'b011_110: bayer8x8_cfa_lookup = -4'sd2;
                6'b011_111: bayer8x8_cfa_lookup =  4'sd2;
                // Row 4: B=3, W=7, B=-5, W=-1, B=1, W=5, B=-7, W=-3
                6'b100_000: bayer8x8_cfa_lookup =  4'sd3;
                6'b100_001: bayer8x8_cfa_lookup =  4'sd7;
                6'b100_010: bayer8x8_cfa_lookup = -4'sd5;
                6'b100_011: bayer8x8_cfa_lookup = -4'sd1;
                6'b100_100: bayer8x8_cfa_lookup =  4'sd1;
                6'b100_101: bayer8x8_cfa_lookup =  4'sd5;
                6'b100_110: bayer8x8_cfa_lookup = -4'sd7;
                6'b100_111: bayer8x8_cfa_lookup = -4'sd3;
                // Row 5: G=-5, R=-1, G=3, R=7, G=-7, R=-3, G=1, R=5
                6'b101_000: bayer8x8_cfa_lookup = -4'sd5;
                6'b101_001: bayer8x8_cfa_lookup = -4'sd1;
                6'b101_010: bayer8x8_cfa_lookup =  4'sd3;
                6'b101_011: bayer8x8_cfa_lookup =  4'sd7;
                6'b101_100: bayer8x8_cfa_lookup = -4'sd7;
                6'b101_101: bayer8x8_cfa_lookup = -4'sd3;
                6'b101_110: bayer8x8_cfa_lookup =  4'sd1;
                6'b101_111: bayer8x8_cfa_lookup =  4'sd5;
                // Row 6: B=-1, W=3, B=7, W=-5, B=-3, W=1, B=5, W=-7
                6'b110_000: bayer8x8_cfa_lookup = -4'sd1;
                6'b110_001: bayer8x8_cfa_lookup =  4'sd3;
                6'b110_010: bayer8x8_cfa_lookup =  4'sd7;
                6'b110_011: bayer8x8_cfa_lookup = -4'sd5;
                6'b110_100: bayer8x8_cfa_lookup = -4'sd3;
                6'b110_101: bayer8x8_cfa_lookup =  4'sd1;
                6'b110_110: bayer8x8_cfa_lookup =  4'sd5;
                6'b110_111: bayer8x8_cfa_lookup = -4'sd7;
                // Row 7: G=7, R=-5, G=-1, R=3, G=5, R=-7, G=-3, R=1
                6'b111_000: bayer8x8_cfa_lookup =  4'sd7;
                6'b111_001: bayer8x8_cfa_lookup = -4'sd5;
                6'b111_010: bayer8x8_cfa_lookup = -4'sd1;
                6'b111_011: bayer8x8_cfa_lookup =  4'sd3;
                6'b111_100: bayer8x8_cfa_lookup =  4'sd5;
                6'b111_101: bayer8x8_cfa_lookup = -4'sd7;
                6'b111_110: bayer8x8_cfa_lookup = -4'sd3;
                6'b111_111: bayer8x8_cfa_lookup =  4'sd1;
                default: bayer8x8_cfa_lookup = 4'sd0;
            endcase
        end
    endfunction

    wire [3:0] b0_cfa = bayer8x8_cfa_lookup(bayer8_row, bayer8_col0);
    wire [3:0] b1_cfa = bayer8x8_cfa_lookup(bayer8_row, bayer8_col1);
    wire [3:0] b2_cfa = bayer8x8_cfa_lookup(bayer8_row, bayer8_col2);
    wire [3:0] b3_cfa = bayer8x8_cfa_lookup(bayer8_row, bayer8_col3);

    // Halved CFA offsets for text antialiasing
    wire [3:0] b0_cfa_half = {b0_cfa[3], b0_cfa[3:1]};
    wire [3:0] b1_cfa_half = {b1_cfa[3], b1_cfa[3:1]};
    wire [3:0] b2_cfa_half = {b2_cfa[3], b2_cfa[3:1]};
    wire [3:0] b3_cfa_half = {b3_cfa[3], b3_cfa[3:1]};

    // =========================================================================
    // Optimized 3x3 CFA-Balanced Matrix for 2-bit path (FAST_GREY)
    // 14% better dispersion than previous, DC balanced for RGBW CFA
    // Matrix values:
    //      x=0  x=1  x=2
    // y=0: -7   -3   +5
    // y=1:  0   +6   -6
    // y=2: +7   -5   +3
    // =========================================================================

    // Row mod 3 for 3x3 matrix
    wire [1:0] bayer3_row = (y_cnt[2:0] == 3'd0 || y_cnt[2:0] == 3'd3 || y_cnt[2:0] == 3'd6) ? 2'd0 :
                            (y_cnt[2:0] == 3'd1 || y_cnt[2:0] == 3'd4 || y_cnt[2:0] == 3'd7) ? 2'd1 :
                            2'd2;

    // Column base mod 3 (x_pos is first pixel's x mod 8)
    wire [1:0] xbase_mod3 = (x_pos == 3'd0 || x_pos == 3'd3 || x_pos == 3'd6) ? 2'd0 :
                            (x_pos == 3'd1 || x_pos == 3'd4 || x_pos == 3'd7) ? 2'd1 :
                            2'd2;

    // Column for each of 4 consecutive pixels (offset 0,1,2,3 from base)
    wire [1:0] bayer3_col0 = xbase_mod3;                                                        // +0 mod 3
    wire [1:0] bayer3_col1 = (xbase_mod3 == 2'd2) ? 2'd0 : (xbase_mod3 + 2'd1);                  // +1 mod 3
    wire [1:0] bayer3_col2 = (xbase_mod3 == 2'd0) ? 2'd2 : (xbase_mod3 == 2'd1) ? 2'd0 : 2'd1;   // +2 mod 3
    wire [1:0] bayer3_col3 = xbase_mod3;                                                        // +3 mod 3 = +0

    // Optimized 3x3 CFA-balanced matrix lookup
    function [3:0] cfa_bayer3x3_opt_lookup;
        input [1:0] row;
        input [1:0] col;
        begin
            case ({row, col})
                4'b00_00: cfa_bayer3x3_opt_lookup = -4'sd7;
                4'b00_01: cfa_bayer3x3_opt_lookup = -4'sd3;
                4'b00_10: cfa_bayer3x3_opt_lookup =  4'sd5;
                4'b01_00: cfa_bayer3x3_opt_lookup =  4'sd0;
                4'b01_01: cfa_bayer3x3_opt_lookup =  4'sd6;
                4'b01_10: cfa_bayer3x3_opt_lookup = -4'sd6;
                4'b10_00: cfa_bayer3x3_opt_lookup =  4'sd7;
                4'b10_01: cfa_bayer3x3_opt_lookup = -4'sd5;
                4'b10_10: cfa_bayer3x3_opt_lookup =  4'sd3;
                default:  cfa_bayer3x3_opt_lookup =  4'sd0;
            endcase
        end
    endfunction

    wire [3:0] b0_3x3_opt = cfa_bayer3x3_opt_lookup(bayer3_row, bayer3_col0);
    wire [3:0] b1_3x3_opt = cfa_bayer3x3_opt_lookup(bayer3_row, bayer3_col1);
    wire [3:0] b2_3x3_opt = cfa_bayer3x3_opt_lookup(bayer3_row, bayer3_col2);
    wire [3:0] b3_3x3_opt = cfa_bayer3x3_opt_lookup(bayer3_row, bayer3_col3);

    // =========================================================================
    // Optimized 7x7 CFA-Balanced Matrix for 2-bit path (FAST_GREY)
    // 7 is coprime with 2, so over 14x14 period each CFA color sees all 49
    // values exactly once - automatically CFA-balanced!
    // 49 unique levels (vs 9 for 3x3) for smoother gradients
    // Period 7 > typical stroke width 1-3 for sharper text
    // =========================================================================

    // Proper mod 7 for row coordinate (y_cnt can be up to ~1000)
    wire [2:0] bayer7_row = y_cnt % 7;

    // For column, x_cnt counts 4-pixel groups
    // Actual pixel x positions: x_cnt*4, x_cnt*4+1, x_cnt*4+2, x_cnt*4+3
    wire [13:0] x_pos_base = {x_cnt, 2'b00};  // x_cnt * 4
    wire [2:0] bayer7_col0 = x_pos_base % 7;
    wire [2:0] bayer7_col1 = (x_pos_base + 14'd1) % 7;
    wire [2:0] bayer7_col2 = (x_pos_base + 14'd2) % 7;
    wire [2:0] bayer7_col3 = (x_pos_base + 14'd3) % 7;

    // Optimized 7x7 matrix lookup (simulated annealing optimized)
    // DC-balanced, good spatial dispersion
    function [3:0] bayer7x7_opt_lookup;
        input [2:0] row;
        input [2:0] col;
        begin
            case ({row, col})
                // Row 0: -7, +5, +7, +2, -3, -4, +6
                6'b000_000: bayer7x7_opt_lookup = -4'sd7;
                6'b000_001: bayer7x7_opt_lookup =  4'sd5;
                6'b000_010: bayer7x7_opt_lookup =  4'sd7;
                6'b000_011: bayer7x7_opt_lookup =  4'sd2;
                6'b000_100: bayer7x7_opt_lookup = -4'sd3;
                6'b000_101: bayer7x7_opt_lookup = -4'sd4;
                6'b000_110: bayer7x7_opt_lookup =  4'sd6;
                // Row 1: +7, +4, +3, 0, -3, +7, -4
                6'b001_000: bayer7x7_opt_lookup =  4'sd7;
                6'b001_001: bayer7x7_opt_lookup =  4'sd4;
                6'b001_010: bayer7x7_opt_lookup =  4'sd3;
                6'b001_011: bayer7x7_opt_lookup =  4'sd0;
                6'b001_100: bayer7x7_opt_lookup = -4'sd3;
                6'b001_101: bayer7x7_opt_lookup =  4'sd7;
                6'b001_110: bayer7x7_opt_lookup = -4'sd4;
                // Row 2: +1, -8, -7, -4, +3, 0, -7
                6'b010_000: bayer7x7_opt_lookup =  4'sd1;
                6'b010_001: bayer7x7_opt_lookup = -4'sd8;
                6'b010_010: bayer7x7_opt_lookup = -4'sd7;
                6'b010_011: bayer7x7_opt_lookup = -4'sd4;
                6'b010_100: bayer7x7_opt_lookup =  4'sd3;
                6'b010_101: bayer7x7_opt_lookup =  4'sd0;
                6'b010_110: bayer7x7_opt_lookup = -4'sd7;
                // Row 3: -1, +1, +1, +2, +4, -3, +5
                6'b011_000: bayer7x7_opt_lookup = -4'sd1;
                6'b011_001: bayer7x7_opt_lookup =  4'sd1;
                6'b011_010: bayer7x7_opt_lookup =  4'sd1;
                6'b011_011: bayer7x7_opt_lookup =  4'sd2;
                6'b011_100: bayer7x7_opt_lookup =  4'sd4;
                6'b011_101: bayer7x7_opt_lookup = -4'sd3;
                6'b011_110: bayer7x7_opt_lookup =  4'sd5;
                // Row 4: +2, +2, +6, -2, -5, +3, -6
                6'b100_000: bayer7x7_opt_lookup =  4'sd2;
                6'b100_001: bayer7x7_opt_lookup =  4'sd2;
                6'b100_010: bayer7x7_opt_lookup =  4'sd6;
                6'b100_011: bayer7x7_opt_lookup = -4'sd2;
                6'b100_100: bayer7x7_opt_lookup = -4'sd5;
                6'b100_101: bayer7x7_opt_lookup =  4'sd3;
                6'b100_110: bayer7x7_opt_lookup = -4'sd6;
                // Row 5: +5, +4, -6, -1, +7, -1, -2
                6'b101_000: bayer7x7_opt_lookup =  4'sd5;
                6'b101_001: bayer7x7_opt_lookup =  4'sd4;
                6'b101_010: bayer7x7_opt_lookup = -4'sd6;
                6'b101_011: bayer7x7_opt_lookup = -4'sd1;
                6'b101_100: bayer7x7_opt_lookup =  4'sd7;
                6'b101_101: bayer7x7_opt_lookup = -4'sd1;
                6'b101_110: bayer7x7_opt_lookup = -4'sd2;
                // Row 6: -2, -5, -6, -2, 0, +6, -5
                6'b110_000: bayer7x7_opt_lookup = -4'sd2;
                6'b110_001: bayer7x7_opt_lookup = -4'sd5;
                6'b110_010: bayer7x7_opt_lookup = -4'sd6;
                6'b110_011: bayer7x7_opt_lookup = -4'sd2;
                6'b110_100: bayer7x7_opt_lookup =  4'sd0;
                6'b110_101: bayer7x7_opt_lookup =  4'sd6;
                6'b110_110: bayer7x7_opt_lookup = -4'sd5;
                default: bayer7x7_opt_lookup = 4'sd0;
            endcase
        end
    endfunction

    wire [3:0] b0_7x7 = bayer7x7_opt_lookup(bayer7_row, bayer7_col0);
    wire [3:0] b1_7x7 = bayer7x7_opt_lookup(bayer7_row, bayer7_col1);
    wire [3:0] b2_7x7 = bayer7x7_opt_lookup(bayer7_row, bayer7_col2);
    wire [3:0] b3_7x7 = bayer7x7_opt_lookup(bayer7_row, bayer7_col3);

    // =========================================================================
    // Standard Bayer Dithering Path with CFA Bias
    // =========================================================================

    localparam BIAS = 9'd10;  // Positive = lower threshold (more white pixels)

    wire [7:0] pix0 = vin[31:24];
    wire [7:0] pix1 = vin[23:16];
    wire [7:0] pix2 = vin[15:8];
    wire [7:0] pix3 = vin[7:0];

    // Separate pixels for 1-bit path (uses different degamma - 2.2 for FAST_MONO)
    wire [7:0] pix0_1b = vin_1b[31:24];
    wire [7:0] pix1_1b = vin_1b[23:16];
    wire [7:0] pix2_1b = vin_1b[15:8];
    wire [7:0] pix3_1b = vin_1b[7:0];

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

    // 1-bit path: uses CFA bias (for FAST_MONO) - uses pix_1b (2.2 degamma)
    wire [8:0] a0 = {1'b0, pix0_1b} + bias_02;
    wire [8:0] a1 = {1'b0, pix1_1b} + bias_13;
    wire [8:0] a2 = {1'b0, pix2_1b} + bias_02;
    wire [8:0] a3 = {1'b0, pix3_1b} + bias_13;

    wire [3:0] c0, c1, c2, c3;
    adder_sat adder_sat0 (a0[8:4], b0, c0);
    adder_sat adder_sat1 (a1[8:4], b1, c1);
    adder_sat adder_sat2 (a2[8:4], b2, c2);
    adder_sat adder_sat3 (a3[8:4], b3, c3);

    // 2-bit path: per-CFA brightness bias for FAST_GREY
    // Luminance now balanced via per-CFA reversal frames in pixel_processing.v
    localparam [7:0] BIAS_2B = 8'd9;       // Base brightness boost
    localparam [7:0] BIAS_2B_B = 8'd2;     // Blue: minimal
    localparam [7:0] BIAS_2B_W = 8'd2;     // White: reduced (was 9, now balanced via reversal)
    localparam [7:0] BIAS_2B_G = 8'd24;    // Green: high (eye sensitive)
    localparam [7:0] BIAS_2B_R = 8'd16;    // Red: medium

    // Per-CFA quantization thresholds (in 4-bit space: 0-15)
    // Disabled per-CFA variation - using uniform thresholds
    // Luminance balanced via reversal frames instead
    localparam [3:0] THRESH_B_1 = 4'd4;    // Blue 0→1 (uniform)
    localparam [3:0] THRESH_B_2 = 4'd8;    // Blue 1→2 (uniform)
    localparam [3:0] THRESH_W_1 = 4'd4;    // White 0→1 (uniform)
    localparam [3:0] THRESH_W_2 = 4'd8;    // White 1→2 (uniform)
    localparam [3:0] THRESH_G_1 = 4'd4;    // Green 0→1 (uniform)
    localparam [3:0] THRESH_G_2 = 4'd8;    // Green 1→2 (uniform)
    localparam [3:0] THRESH_R_1 = 4'd4;    // Red 0→1 (uniform)
    localparam [3:0] THRESH_R_2 = 4'd8;    // Red 1→2 (uniform)

    // Per-CFA bias selection
    // Row 0 (cfa_row=0): pix0,pix2=B, pix1,pix3=W
    // Row 1 (cfa_row=1): pix0,pix2=G, pix1,pix3=R
    wire [7:0] bias_2b_02 = (cfa_row == 1'b0) ? BIAS_2B_B : BIAS_2B_G;
    wire [7:0] bias_2b_13 = (cfa_row == 1'b0) ? BIAS_2B_W : BIAS_2B_R;

    // =========================================================================
    // Input-Based Neighbor Bias for Consistent Colored Text Stroke Width
    // At colored edges, if pixel differs from neighbors, bias toward neighbors
    // This normalizes stroke width by snapping outlier pixels
    // IMPORTANT: Uses IMMEDIATE neighbors (1 pixel away), not same-color neighbors!
    // Python: neighbor_avg = (up + down + left + right) / 4
    // =========================================================================

    // =========================================================================
    // Colored edge detection for text stroke thickening
    // At colored text edges, apply darkening bias to compensate for CFA thinning
    // =========================================================================

    // Use true RGB saturation passed from vin_colormixer (is_colored_in)
    // This is computed BEFORE CFA sampling, so it's accurate even at edges
    // Combined with gradient to detect colored edges specifically
    wire is_colored_edge_0 = is_colored_in[0] && (max_grad_0 > 8'd20);
    wire is_colored_edge_1 = is_colored_in[1] && (max_grad_1 > 8'd20);
    wire is_colored_edge_2 = is_colored_in[2] && (max_grad_2 > 8'd20);
    wire is_colored_edge_3 = is_colored_in[3] && (max_grad_3 > 8'd20);

    // Compute neighbor average for each pixel (up + left + right) / 3
    // Python: neighbor_avg = (up + down + left + right) / 4
    // We use 3 neighbors since "down" requires another line buffer
    // pix0: left=prev_pix3, right=pix1, up=prev1_line_pix0
    // pix1: left=pix0, right=pix2, up=prev1_line_pix1
    // pix2: left=pix1, right=pix3, up=prev1_line_pix2
    // pix3: left=pix2, right=pix2 (proxy), up=prev1_line_pix3
    wire [9:0] neighbor_sum_0 = {2'b0, prev_pix3} + {2'b0, pix1} + {2'b0, prev1_line_pix0};
    wire [9:0] neighbor_sum_1 = {2'b0, pix0} + {2'b0, pix2} + {2'b0, prev1_line_pix1};
    wire [9:0] neighbor_sum_2 = {2'b0, pix1} + {2'b0, pix3} + {2'b0, prev1_line_pix2};
    wire [9:0] neighbor_sum_3 = {2'b0, pix2} + {2'b0, pix2} + {2'b0, prev1_line_pix3};

    // Divide by 3: approximate as (sum * 85) >> 8 ≈ sum * 0.332
    // Or simpler: (sum * 11) >> 5 = sum * 0.34375 (close enough)
    wire [13:0] neighbor_prod_0 = neighbor_sum_0 * 11;
    wire [13:0] neighbor_prod_1 = neighbor_sum_1 * 11;
    wire [13:0] neighbor_prod_2 = neighbor_sum_2 * 11;
    wire [13:0] neighbor_prod_3 = neighbor_sum_3 * 11;
    wire [7:0] neighbor_avg_0 = neighbor_prod_0[12:5];
    wire [7:0] neighbor_avg_1 = neighbor_prod_1[12:5];
    wire [7:0] neighbor_avg_2 = neighbor_prod_2[12:5];
    wire [7:0] neighbor_avg_3 = neighbor_prod_3[12:5];

    // Compute diff = pixel - neighbor_avg (signed)
    wire signed [8:0] diff_0 = $signed({1'b0, pix0}) - $signed({1'b0, neighbor_avg_0});
    wire signed [8:0] diff_1 = $signed({1'b0, pix1}) - $signed({1'b0, neighbor_avg_1});
    wire signed [8:0] diff_2 = $signed({1'b0, pix2}) - $signed({1'b0, neighbor_avg_2});
    wire signed [8:0] diff_3 = $signed({1'b0, pix3}) - $signed({1'b0, neighbor_avg_3});

    // Scale by ~0.3: multiply by 5, divide by 16
    wire signed [12:0] scaled_0 = diff_0 * 5;
    wire signed [12:0] scaled_1 = diff_1 * 5;
    wire signed [12:0] scaled_2 = diff_2 * 5;
    wire signed [12:0] scaled_3 = diff_3 * 5;
    wire signed [8:0] bias_0 = scaled_0 >>> 4;
    wire signed [8:0] bias_1 = scaled_1 >>> 4;
    wire signed [8:0] bias_2 = scaled_2 >>> 4;
    wire signed [8:0] bias_3 = scaled_3 >>> 4;

    // Clamp bias to ±31 and apply only at colored edges
    wire signed [5:0] clamped_bias_0 = (bias_0 > 9'sd31) ? 6'sd31 : (bias_0 < -9'sd32) ? -6'sd32 : bias_0[5:0];
    wire signed [5:0] clamped_bias_1 = (bias_1 > 9'sd31) ? 6'sd31 : (bias_1 < -9'sd32) ? -6'sd32 : bias_1[5:0];
    wire signed [5:0] clamped_bias_2 = (bias_2 > 9'sd31) ? 6'sd31 : (bias_2 < -9'sd32) ? -6'sd32 : bias_2[5:0];
    wire signed [5:0] clamped_bias_3 = (bias_3 > 9'sd31) ? 6'sd31 : (bias_3 < -9'sd32) ? -6'sd32 : bias_3[5:0];

    wire signed [5:0] neighbor_bias_0 = is_colored_edge_0 ? clamped_bias_0 : 6'sd0;
    wire signed [5:0] neighbor_bias_1 = is_colored_edge_1 ? clamped_bias_1 : 6'sd0;
    wire signed [5:0] neighbor_bias_2 = is_colored_edge_2 ? clamped_bias_2 : 6'sd0;
    wire signed [5:0] neighbor_bias_3 = is_colored_edge_3 ? clamped_bias_3 : 6'sd0;

    // Per-CFA threshold selection
    wire [3:0] thresh_02_1 = (cfa_row == 1'b0) ? THRESH_B_1 : THRESH_G_1;
    wire [3:0] thresh_02_2 = (cfa_row == 1'b0) ? THRESH_B_2 : THRESH_G_2;
    wire [3:0] thresh_13_1 = (cfa_row == 1'b0) ? THRESH_W_1 : THRESH_R_1;
    wire [3:0] thresh_13_2 = (cfa_row == 1'b0) ? THRESH_W_2 : THRESH_R_2;

    // Direct bias - max 24, no clamping needed
    // pix1_adj/pix3_adj: for W (row 0), use light gray when saturated mid-dark
    wire [8:0] a0_2b = {1'b0, pix0} + {1'b0, bias_2b_02};
    wire [8:0] a1_2b = {1'b0, pix1_adj} + {1'b0, bias_2b_13};
    wire [8:0] a2_2b = {1'b0, pix2} + {1'b0, bias_2b_02};
    wire [8:0] a3_2b = {1'b0, pix3_adj} + {1'b0, bias_2b_13};

    wire [3:0] c0_2b, c1_2b, c2_2b, c3_2b;
    // Use content-adaptive CFA-balanced offsets (halved for edges, full for smooth)
    adder_sat adder_sat0_2b (a0_2b[8:4], b0_adaptive, c0_2b);
    adder_sat adder_sat1_2b (a1_2b[8:4], b1_adaptive, c1_2b);
    adder_sat adder_sat2_2b (a2_2b[8:4], b2_adaptive, c2_2b);
    adder_sat adder_sat3_2b (a3_2b[8:4], b3_adaptive, c3_2b);

    // =========================================================================
    // Grayscale Path for Sharp B/W Text (200dpi mode)
    // Uses luminance for all subpixels instead of CFA color mixing
    // Only activated for black text on white backgrounds
    // =========================================================================

    // Saturation detection: max - min across all 4 pixels (current row only)
    wire [7:0] max_01 = (pix0 > pix1) ? pix0 : pix1;
    wire [7:0] max_23 = (pix2 > pix3) ? pix2 : pix3;
    wire [7:0] max_all = (max_01 > max_23) ? max_01 : max_23;
    wire [7:0] min_01 = (pix0 < pix1) ? pix0 : pix1;
    wire [7:0] min_23 = (pix2 < pix3) ? pix2 : pix3;
    wire [7:0] min_all = (min_01 < min_23) ? min_01 : min_23;
    wire [7:0] saturation = max_all - min_all;
    wire is_low_saturation = (saturation < 8'd30);

    // True saturation: use both current row AND previous row (all 4 CFA colors)
    // Row 0 (BW): pix0=B, pix1=W, prev1_pix0=G, prev1_pix1=R
    // Row 1 (GR): pix0=G, pix1=R, prev1_pix0=B, prev1_pix1=W
    // prev1_line_pix0/1 defined later but Verilog handles forward refs
    wire [7:0] max_cur = (pix0 > pix1) ? pix0 : pix1;
    wire [7:0] max_prev = (prev1_line_pix0 > prev1_line_pix1) ? prev1_line_pix0 : prev1_line_pix1;
    wire [7:0] max_true = (max_cur > max_prev) ? max_cur : max_prev;
    wire [7:0] min_cur = (pix0 < pix1) ? pix0 : pix1;
    wire [7:0] min_prev = (prev1_line_pix0 < prev1_line_pix1) ? prev1_line_pix0 : prev1_line_pix1;
    wire [7:0] min_true = (min_cur < min_prev) ? min_cur : min_prev;
    wire [7:0] true_saturation = max_true - min_true;

    // Use true saturation for W adjustment (sees all RGBW channels)
    // DISABLED - causes ugly artifacts
    wire is_saturated = 1'b0;

    // Luminance approximation: average of all pixels
    // (pix0 + pix1 + pix2 + pix3) / 4
    wire [9:0] lum_sum = {2'b0, pix0} + {2'b0, pix1} + {2'b0, pix2} + {2'b0, pix3};
    wire [7:0] luminance = lum_sum[9:2];  // Divide by 4

    // Saturated mid-dark W adjustment for CFA path
    // Bright W pixels in saturated color areas are distracting
    // Use luminance instead of raw W so it matches the color's perceived brightness
    wire is_not_bright = (luminance < 8'd220);  // Include most colors except near-white
    wire is_sat_colored = is_saturated && is_not_bright;
    // When saturated on W row, use scaled luminance so W blends darker
    // Clamp to minimum 64, but only if original wasn't already dark
    wire [7:0] lum_half = luminance >> 1;
    wire [7:0] lum_for_sat = (lum_half < 8'd64 && luminance > 8'd80) ? 8'd64 : lum_half;
    wire [7:0] pix1_adj = (is_sat_colored && cfa_row == 1'b0) ? lum_for_sat : pix1;
    wire [7:0] pix3_adj = (is_sat_colored && cfa_row == 1'b0) ? lum_for_sat : pix3;

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
    // Use content-adaptive CFA-balanced offsets (same as CFA path)
    adder_sat adder_sat0_gray (a0_gray[8:4], b0_adaptive, c0_gray);
    adder_sat adder_sat1_gray (a1_gray[8:4], b1_adaptive, c1_gray);
    adder_sat adder_sat2_gray (a2_gray[8:4], b2_adaptive, c2_gray);
    adder_sat adder_sat3_gray (a3_gray[8:4], b3_adaptive, c3_gray);

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

    // 1-bit: MSB threshold (uses pix_1b for 2.2 degamma)
    wire [3:0] simple_out_1b = {pix0_1b[7], pix1_1b[7], pix2_1b[7], pix3_1b[7]};
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
    wire [31:0] prev1_line_pixels = line_buffer_0[line_buf_addr];     // n-1 (opposite CFA row)

    wire [7:0] prev2_line_pix0 = prev2_line_pixels[31:24];
    wire [7:0] prev2_line_pix1 = prev2_line_pixels[23:16];
    wire [7:0] prev2_line_pix2 = prev2_line_pixels[15:8];
    wire [7:0] prev2_line_pix3 = prev2_line_pixels[7:0];

    // Previous line pixels (opposite CFA row: if current is BW, prev1 is GR)
    wire [7:0] prev1_line_pix0 = prev1_line_pixels[31:24];
    wire [7:0] prev1_line_pix1 = prev1_line_pixels[23:16];
    wire [7:0] prev1_line_pix2 = prev1_line_pixels[15:8];
    wire [7:0] prev1_line_pix3 = prev1_line_pixels[7:0];
    
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
    // Content-Adaptive Dither Offset Selection
    // - Edges/text (high gradient): halved CFA offsets for fine antialiasing
    // - Smooth areas (low gradient): full CFA offsets for better gradients
    // =========================================================================

    // Content-adaptive dithering: halved bayer for smooth areas, NO dither for edges
    // At edges, quantize all channels together (no dithering)
    wire is_dither_edge_0 = (max_grad_0 > EDGE_THRESH_LOW);
    wire is_dither_edge_1 = (max_grad_1 > EDGE_THRESH_LOW);
    wire is_dither_edge_2 = (max_grad_2 > EDGE_THRESH_LOW);
    wire is_dither_edge_3 = (max_grad_3 > EDGE_THRESH_LOW);

    // All pixels at edges: no dither for clean text
    wire no_dither_0 = is_dither_edge_0;
    wire no_dither_1 = is_dither_edge_1;
    wire no_dither_2 = is_dither_edge_2;
    wire no_dither_3 = is_dither_edge_3;

    wire [3:0] b0_adaptive = no_dither_0 ? 4'sd0 : b0_cfa_half;
    wire [3:0] b1_adaptive = no_dither_1 ? 4'sd0 : b1_cfa_half;
    wire [3:0] b2_adaptive = no_dither_2 ? 4'sd0 : b2_cfa_half;
    wire [3:0] b3_adaptive = no_dither_3 ? 4'sd0 : b3_cfa_half;

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
    // Two paths (matches bayer_dither_4level_edge_aware_no_simple):
    // 1. Grayscale (200dpi): for black text on white (edge + low sat + bright bg + dark pixel)
    // 2. CFA Bayer dither: for everything else

    // =========================================================================
    // Apply Fixed Darkening at Colored Edges
    // Simple approach: subtract 2 levels at colored edges for consistent stroke width
    // Allows full 0-15 range for sharpness
    // =========================================================================

    // Fixed darkening: disabled (was -1 level at colored edges)
    wire signed [4:0] darken_0 = 5'sd0;
    wire signed [4:0] darken_1 = 5'sd0;
    wire signed [4:0] darken_2 = 5'sd0;
    wire signed [4:0] darken_3 = 5'sd0;

    // Apply darkening
    wire signed [5:0] c0_biased_raw = $signed({2'b00, c0_2b}) + darken_0;
    wire signed [5:0] c1_biased_raw = $signed({2'b00, c1_2b}) + darken_1;
    wire signed [5:0] c2_biased_raw = $signed({2'b00, c2_2b}) + darken_2;
    wire signed [5:0] c3_biased_raw = $signed({2'b00, c3_2b}) + darken_3;

    // Clamp to 0-15 range (allow full range for sharpness)
    wire [3:0] c0_biased = (c0_biased_raw < 6'sd0) ? 4'd0 :
                           (c0_biased_raw > 6'sd15) ? 4'd15 : c0_biased_raw[3:0];
    wire [3:0] c1_biased = (c1_biased_raw < 6'sd0) ? 4'd0 :
                           (c1_biased_raw > 6'sd15) ? 4'd15 : c1_biased_raw[3:0];
    wire [3:0] c2_biased = (c2_biased_raw < 6'sd0) ? 4'd0 :
                           (c2_biased_raw > 6'sd15) ? 4'd15 : c2_biased_raw[3:0];
    wire [3:0] c3_biased = (c3_biased_raw < 6'sd0) ? 4'd0 :
                           (c3_biased_raw > 6'sd15) ? 4'd15 : c3_biased_raw[3:0];

    // Per-CFA threshold quantization (level 3 threshold fixed at 12)
    // Now uses biased values for consistent colored text stroke width
    wire [1:0] quant_02 = (c0_biased >= 4'd12) ? 2'd3 :
                          (c0_biased >= thresh_02_2) ? 2'd2 :
                          (c0_biased >= thresh_02_1) ? 2'd1 : 2'd0;
    wire [1:0] quant_13 = (c1_biased >= 4'd12) ? 2'd3 :
                          (c1_biased >= thresh_13_2) ? 2'd2 :
                          (c1_biased >= thresh_13_1) ? 2'd1 : 2'd0;
    wire [1:0] quant_22 = (c2_biased >= 4'd12) ? 2'd3 :
                          (c2_biased >= thresh_02_2) ? 2'd2 :
                          (c2_biased >= thresh_02_1) ? 2'd1 : 2'd0;
    wire [1:0] quant_33 = (c3_biased >= 4'd12) ? 2'd3 :
                          (c3_biased >= thresh_13_2) ? 2'd2 :
                          (c3_biased >= thresh_13_1) ? 2'd1 : 2'd0;

    wire [1:0] out0_2b = (pix0 >= 8'd250) ? 2'b11 : (pix0 <= 8'd5) ? 2'b00 :
                         use_gray_0 ? c0_gray[3:2] : quant_02;
    wire [1:0] out1_2b = (pix1 >= 8'd250) ? 2'b11 : (pix1 <= 8'd5) ? 2'b00 :
                         use_gray_1 ? c1_gray[3:2] : quant_13;
    wire [1:0] out2_2b = (pix2 >= 8'd250) ? 2'b11 : (pix2 <= 8'd5) ? 2'b00 :
                         use_gray_2 ? c2_gray[3:2] : quant_22;
    wire [1:0] out3_2b = (pix3 >= 8'd250) ? 2'b11 : (pix3 <= 8'd5) ? 2'b00 :
                         use_gray_3 ? c3_gray[3:2] : quant_33;
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
