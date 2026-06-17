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
// 2. Per-CFA balanced 16x16 less-yellow matrix for 2-bit path (FAST_GREY)
//    - Each CFA color (B,W,G,R) gets independent phase-shifted Bayer pattern
//    - Small CFA trim reduces yellow cast: B+1, G-2, R-1, W+0
//    - Content-adaptive: halved offsets for smooth areas, no dither at text/edges
//    - See docs/PER_CFA_DITHERING.md for derivation
// 3. Gradient-weighted edge detection with soft blending
//    - Instead of binary threshold, uses gradient magnitude for smooth blending
//    - Eliminates stripe artifacts in images while preserving sharp text edges
//    - Text (high gradient >160) gets full edge-aware treatment
//    - Images (lower gradients) retain smooth dithering
// 4. Same-color subpixel comparison to avoid false edges from CFA pattern
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
    parameter FATTEN = 0              // Lower threshold globally (fatter text, 0-20)
) (
    input wire                       clk,
    input wire                       rst,
    input wire                       active,
    input wire [31:0]                vin,        // Input for 2-bit path (FAST_GREY)
    input wire [31:0]                vin_1b,     // Original 1-bit path input (FAST_MONO Bayer)
    input wire [3:0]                 is_colored_in, // True RGB saturation flags from vin_colormixer
    output reg [3:0]                 vout_1b,    // 1-bit per pixel (FAST_MONO) - uses 3x3
    output reg [7:0]                 vout_2b,    // 2-bit per pixel (FAST_GREY) - uses 16x16 half less-yellow CFA
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

    wire cfa_row = y_cnt[0];  // 0=BW row, 1=GR row

    // =========================================================================
    // 16x16 CFA-Balanced Less-Yellow Matrix for 2-bit FAST_GREY
    // Physical 16x16 addressing: x_cnt is a 4-pixel group, y_cnt is the row.
    // The 2-bit dither only needs 16 ranks, so this stores the upper Bayer rank
    // used by the simulator's bayer16cfacool mode.
    // =========================================================================

    function [3:0] bayer16_rank4_lookup;
        input [1:0] row;
        input [1:0] col;
        begin
            case ({row, col})
                4'b00_00: bayer16_rank4_lookup = 4'd0;
                4'b00_01: bayer16_rank4_lookup = 4'd8;
                4'b00_10: bayer16_rank4_lookup = 4'd2;
                4'b00_11: bayer16_rank4_lookup = 4'd10;
                4'b01_00: bayer16_rank4_lookup = 4'd12;
                4'b01_01: bayer16_rank4_lookup = 4'd4;
                4'b01_10: bayer16_rank4_lookup = 4'd14;
                4'b01_11: bayer16_rank4_lookup = 4'd6;
                4'b10_00: bayer16_rank4_lookup = 4'd3;
                4'b10_01: bayer16_rank4_lookup = 4'd11;
                4'b10_10: bayer16_rank4_lookup = 4'd1;
                4'b10_11: bayer16_rank4_lookup = 4'd9;
                4'b11_00: bayer16_rank4_lookup = 4'd15;
                4'b11_01: bayer16_rank4_lookup = 4'd7;
                4'b11_10: bayer16_rank4_lookup = 4'd13;
                4'b11_11: bayer16_rank4_lookup = 4'd5;
                default:  bayer16_rank4_lookup = 4'd0;
            endcase
        end
    endfunction

    function [3:0] bayer16_lessyellow_half_lookup;
        input [1:0] row;
        input [1:0] col;
        input [3:0] phase;
        input [3:0] trim;
        reg [3:0] rank_phase;
        reg [3:0] signed_full;
        reg signed [3:0] half_offset;
        reg signed [4:0] trimmed;
        begin
            rank_phase = bayer16_rank4_lookup(row, col) + phase;
            signed_full = rank_phase + 4'd8; // ((rank + phase) & 15) - 8
            half_offset = {signed_full[3], signed_full[3:1]};
            trimmed = $signed(half_offset) + $signed(trim);
            bayer16_lessyellow_half_lookup =
                (trimmed < -5'sd8) ? (-4'sd8) :
                (trimmed >  5'sd7) ? ( 4'sd7) :
                                      trimmed[3:0];
        end
    endfunction

    wire [1:0] bayer16_row = y_cnt[2:1];
    wire [1:0] bayer16_col01 = {x_cnt[0], 1'b0};
    wire [1:0] bayer16_col23 = {x_cnt[0], 1'b1};
    wire [3:0] bayer16_phase_02 = (cfa_row == 1'b0) ? 4'd8  : 4'd0;  // B/G
    wire [3:0] bayer16_phase_13 = (cfa_row == 1'b0) ? 4'd12 : 4'd4;  // W/R
    wire [3:0] bayer16_trim_02 = (cfa_row == 1'b0) ?  4'sd1 : (-4'sd2);
    wire [3:0] bayer16_trim_13 = (cfa_row == 1'b0) ?  4'sd0 : (-4'sd1);

    wire [3:0] b0_cfa16_ly_half = bayer16_lessyellow_half_lookup(bayer16_row, bayer16_col01, bayer16_phase_02, bayer16_trim_02);
    wire [3:0] b1_cfa16_ly_half = bayer16_lessyellow_half_lookup(bayer16_row, bayer16_col01, bayer16_phase_13, bayer16_trim_13);
    wire [3:0] b2_cfa16_ly_half = bayer16_lessyellow_half_lookup(bayer16_row, bayer16_col23, bayer16_phase_02, bayer16_trim_02);
    wire [3:0] b3_cfa16_ly_half = bayer16_lessyellow_half_lookup(bayer16_row, bayer16_col23, bayer16_phase_13, bayer16_trim_13);

    // =========================================================================
    // Standard Bayer Dithering Path with CFA Bias
    // =========================================================================

    localparam BIAS = 9'd10;  // Positive = lower threshold (more white pixels)

    wire [7:0] pix0 = vin[31:24];
    wire [7:0] pix1 = vin[23:16];
    wire [7:0] pix2 = vin[15:8];
    wire [7:0] pix3 = vin[7:0];

    // Separate pixels for the 1-bit path so FAST_MONO Bayer can keep its
    // original degamma/input while FAST_GREY uses the 8-bit path.
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

    // CFA bias per pixel position
    // Row 0: pix0,pix2=B, pix1,pix3=W
    // Row 1: pix0,pix2=G, pix1,pix3=R
    wire [7:0] cfa_bias_02 = (cfa_row == 1'b0) ? CFA_BIAS_B[7:0] : CFA_BIAS_G[7:0];
    wire [7:0] cfa_bias_13 = (cfa_row == 1'b0) ? CFA_BIAS_W[7:0] : CFA_BIAS_R[7:0];

    // Simple unsigned bias: BIAS + FATTEN - CFA_BIAS, clamped to 0 minimum
    wire [8:0] bias_02 = (BIAS + FATTEN > {1'b0, cfa_bias_02}) ? (BIAS + FATTEN - {1'b0, cfa_bias_02}) : 9'd0;
    wire [8:0] bias_13 = (BIAS + FATTEN > {1'b0, cfa_bias_13}) ? (BIAS + FATTEN - {1'b0, cfa_bias_13}) : 9'd0;

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

    // use true RGB saturation passed from vin_colormixer. Caster packs these
    // as {pix0, pix1, pix2, pix3}, so decode them before per-pixel use.
    wire is_colored_pix0 = is_colored_in[3];
    wire is_colored_pix1 = is_colored_in[2];
    wire is_colored_pix2 = is_colored_in[1];
    wire is_colored_pix3 = is_colored_in[0];

    // Per-CFA threshold selection
    wire [3:0] thresh_02_1 = (cfa_row == 1'b0) ? THRESH_B_1 : THRESH_G_1;
    wire [3:0] thresh_02_2 = (cfa_row == 1'b0) ? THRESH_B_2 : THRESH_G_2;
    wire [3:0] thresh_13_1 = (cfa_row == 1'b0) ? THRESH_W_1 : THRESH_R_1;
    wire [3:0] thresh_13_2 = (cfa_row == 1'b0) ? THRESH_W_2 : THRESH_R_2;

    // Direct bias - max 24, no clamping needed
    wire [8:0] a0_2b = {1'b0, pix0} + {1'b0, bias_2b_02};
    wire [8:0] a1_2b = {1'b0, pix1} + {1'b0, bias_2b_13};
    wire [8:0] a2_2b = {1'b0, pix2} + {1'b0, bias_2b_02};
    wire [8:0] a3_2b = {1'b0, pix3} + {1'b0, bias_2b_13};

    wire [3:0] c0_2b, c1_2b, c2_2b, c3_2b;
    // Use content-adaptive CFA-balanced offsets (halved for edges, full for smooth)
    adder_sat adder_sat0_2b (a0_2b[8:4], b0_adaptive, c0_2b);
    adder_sat adder_sat1_2b (a1_2b[8:4], b1_adaptive, c1_2b);
    adder_sat adder_sat2_2b (a2_2b[8:4], b2_adaptive, c2_2b);
    adder_sat adder_sat3_2b (a3_2b[8:4], b3_adaptive, c3_2b);

    function [1:0] nearest_gray_2b;
        input [7:0] v;
        begin
            nearest_gray_2b = (v >= 8'd213) ? 2'd3 :
                              (v >= 8'd128) ? 2'd2 :
                              (v >= 8'd43)  ? 2'd1 : 2'd0;
        end
    endfunction

    // Helper function to find max of two 8-bit values.
    function [7:0] max2;
        input [7:0] a, b;
        begin
            max2 = (a > b) ? a : b;
        end
    endfunction

    wire [9:0] edge_bg_sum_cur = {2'b0, pix0} + {2'b0, pix1} + {2'b0, pix2} + {2'b0, pix3};
    wire [9:0] edge_bg_sum_prev = {2'b0, prev_pix0} + {2'b0, prev_pix1} +
                                   {2'b0, prev_pix2} + {2'b0, prev_pix3};
    wire [9:0] edge_bg_sum_up = {2'b0, prev2_line_pix0} + {2'b0, prev2_line_pix1} +
                                 {2'b0, prev2_line_pix2} + {2'b0, prev2_line_pix3};
    wire [11:0] edge_bg_sum = {2'b0, edge_bg_sum_cur} + {2'b0, edge_bg_sum_prev} +
                              {2'b0, edge_bg_sum_up};
    wire edge_bg_light = (edge_bg_sum >= 12'd1536);

    // 1-bit output: just MSB (binary dithering) - uses CFA bias
    wire [3:0] bayer_out_1b = {c0[3], c1[3], c2[3], c3[3]};

    // =========================================================================
    // Simple Threshold Path (for edges - no dithering)
    // =========================================================================

    // 1-bit: MSB threshold
    wire [3:0] simple_out_1b = {pix0_1b[7], pix1_1b[7], pix2_1b[7], pix3_1b[7]};

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
    
    // Cascade write: current -> buffer_0 -> buffer_1. Only update during
    // active video so line-buffer address 0 maps to the first visible group.
    always @(posedge clk) begin
        if (active) begin
            line_buffer_1[line_buf_addr] <= line_buffer_0[line_buf_addr];
            line_buffer_0[line_buf_addr] <= vin;
        end
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
    // - Edges/text (high gradient): no dither for clean text
    // - Smooth areas (low gradient): 16x16 less-yellow CFA half offsets
    // =========================================================================

    // Content-adaptive dithering: halved Bayer for smooth areas, NO dither for edges
    // At edges, quantize all channels together (no dithering)
    wire is_dither_edge_0 = (max_grad_0 > EDGE_THRESH_LOW);
    wire is_dither_edge_1 = (max_grad_1 > EDGE_THRESH_LOW);
    wire is_dither_edge_2 = (max_grad_2 > EDGE_THRESH_LOW);
    wire is_dither_edge_3 = (max_grad_3 > EDGE_THRESH_LOW);

    wire no_dither_0 = is_dither_edge_0 && !is_colored_pix0;
    wire no_dither_1 = is_dither_edge_1 && !is_colored_pix1;
    wire no_dither_2 = is_dither_edge_2 && !is_colored_pix2;
    wire no_dither_3 = is_dither_edge_3 && !is_colored_pix3;

    wire [3:0] b0_adaptive = no_dither_0 ? 4'sd0 : b0_cfa16_ly_half;
    wire [3:0] b1_adaptive = no_dither_1 ? 4'sd0 : b1_cfa16_ly_half;
    wire [3:0] b2_adaptive = no_dither_2 ? 4'sd0 : b2_cfa16_ly_half;
    wire [3:0] b3_adaptive = no_dither_3 ? 4'sd0 : b3_cfa16_ly_half;

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
    
    // FAST_MONO Bayer keeps the original edge/simple decision. The FAST_GREY
    // 2-bit path adds colored-edge gating below.
    wire use_simple_mono_0 = (max_grad_0 >= EDGE_THRESH_HIGH) ||
                             ((max_grad_0 >= EDGE_THRESH_LOW) && (max_grad_0 >= adaptive_thresh));
    wire use_simple_mono_1 = (max_grad_1 >= EDGE_THRESH_HIGH) ||
                             ((max_grad_1 >= EDGE_THRESH_LOW) && (max_grad_1 >= adaptive_thresh));
    wire use_simple_mono_2 = (max_grad_2 >= EDGE_THRESH_HIGH) ||
                             ((max_grad_2 >= EDGE_THRESH_LOW) && (max_grad_2 >= adaptive_thresh));
    wire use_simple_mono_3 = (max_grad_3 >= EDGE_THRESH_HIGH) ||
                             ((max_grad_3 >= EDGE_THRESH_LOW) && (max_grad_3 >= adaptive_thresh));

    // Edge decision with soft blending:
    // - Hard edge (simple) if gradient >= EDGE_THRESH_HIGH
    // - Hard dither if gradient < EDGE_THRESH_LOW  
    // - Spatially-dithered blend in between
    wire use_simple_base_0 = !is_colored_pix0 &&
                             ((max_grad_0 >= EDGE_THRESH_HIGH) ||
                              ((max_grad_0 >= EDGE_THRESH_LOW) && (max_grad_0 >= adaptive_thresh)));
    wire use_simple_base_1 = !is_colored_pix1 &&
                             ((max_grad_1 >= EDGE_THRESH_HIGH) ||
                              ((max_grad_1 >= EDGE_THRESH_LOW) && (max_grad_1 >= adaptive_thresh)));
    wire use_simple_base_2 = !is_colored_pix2 &&
                             ((max_grad_2 >= EDGE_THRESH_HIGH) ||
                              ((max_grad_2 >= EDGE_THRESH_LOW) && (max_grad_2 >= adaptive_thresh)));
    wire use_simple_base_3 = !is_colored_pix3 &&
                             ((max_grad_3 >= EDGE_THRESH_HIGH) ||
                              ((max_grad_3 >= EDGE_THRESH_LOW) && (max_grad_3 >= adaptive_thresh)));

    wire text_core_0 = use_simple_base_0 && edge_bg_light && (pix0 <= 8'd96);
    wire text_core_1 = use_simple_base_1 && edge_bg_light && (pix1 <= 8'd96);
    wire text_core_2 = use_simple_base_2 && edge_bg_light && (pix2 <= 8'd96);
    wire text_core_3 = use_simple_base_3 && edge_bg_light && (pix3 <= 8'd96);
    reg [3:0] prev_text_core;
    always @(posedge clk) begin
        if (rst || !active)
            prev_text_core <= 4'b0000;
        else
            prev_text_core <= {text_core_0, text_core_1, text_core_2, text_core_3};
    end

    wire text_halo_0 = edge_bg_light && no_dither_0 && (pix0 > 8'd96) &&
                       (prev_text_core[0] || text_core_1);
    wire text_halo_1 = edge_bg_light && no_dither_1 && (pix1 > 8'd96) &&
                       (text_core_0 || text_core_2);
    wire text_halo_2 = edge_bg_light && no_dither_2 && (pix2 > 8'd96) &&
                       (text_core_1 || text_core_3);
    wire text_halo_3 = edge_bg_light && no_dither_3 && (pix3 > 8'd96) &&
                       text_core_2;

    wire use_simple_0 = use_simple_base_0 || text_halo_0;
    wire use_simple_1 = use_simple_base_1 || text_halo_1;
    wire use_simple_2 = use_simple_base_2 || text_halo_2;
    wire use_simple_3 = use_simple_base_3 || text_halo_3;

    // =========================================================================
    // Output: Always compute both 1-bit and 2-bit paths
    // =========================================================================

    // 1-bit output (3x3 Bayer with CFA bias) - for FAST_MONO
    wire [3:0] final_out_1b;
    assign final_out_1b[3] = use_simple_mono_0 ? simple_out_1b[3] : bayer_out_1b[3];
    assign final_out_1b[2] = use_simple_mono_1 ? simple_out_1b[2] : bayer_out_1b[2];
    assign final_out_1b[1] = use_simple_mono_2 ? simple_out_1b[1] : bayer_out_1b[1];
    assign final_out_1b[0] = use_simple_mono_3 ? simple_out_1b[0] : bayer_out_1b[0];

    // 2-bit output (16x16 less-yellow Bayer) - for FAST_GREY
    // Two paths:
    // 1. Edge/simple: exact pixel nearest-gray mapping, no dither
    // 2. CFA Bayer dither: for everything else

    // Per-CFA threshold quantization (level 3 threshold fixed at 12)
    wire [1:0] quant_02 = (c0_2b >= 4'd12) ? 2'd3 :
                          (c0_2b >= thresh_02_2) ? 2'd2 :
                          (c0_2b >= thresh_02_1) ? 2'd1 : 2'd0;
    wire [1:0] quant_13 = (c1_2b >= 4'd12) ? 2'd3 :
                          (c1_2b >= thresh_13_2) ? 2'd2 :
                          (c1_2b >= thresh_13_1) ? 2'd1 : 2'd0;
    wire [1:0] quant_22 = (c2_2b >= 4'd12) ? 2'd3 :
                          (c2_2b >= thresh_02_2) ? 2'd2 :
                          (c2_2b >= thresh_02_1) ? 2'd1 : 2'd0;
    wire [1:0] quant_33 = (c3_2b >= 4'd12) ? 2'd3 :
                          (c3_2b >= thresh_13_2) ? 2'd2 :
                          (c3_2b >= thresh_13_1) ? 2'd1 : 2'd0;

    wire [1:0] out0_2b = (pix0 >= 8'd250) ? 2'b11 : (pix0 <= 8'd5) ? 2'b00 :
                         use_simple_0 ? nearest_gray_2b(pix0) : quant_02;
    wire [1:0] out1_2b = (pix1 >= 8'd250) ? 2'b11 : (pix1 <= 8'd5) ? 2'b00 :
                         use_simple_1 ? nearest_gray_2b(pix1) : quant_13;
    wire [1:0] out2_2b = (pix2 >= 8'd250) ? 2'b11 : (pix2 <= 8'd5) ? 2'b00 :
                         use_simple_2 ? nearest_gray_2b(pix2) : quant_22;
    wire [1:0] out3_2b = (pix3 >= 8'd250) ? 2'b11 : (pix3 <= 8'd5) ? 2'b00 :
                         use_simple_3 ? nearest_gray_2b(pix3) : quant_33;
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
