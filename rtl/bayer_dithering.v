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
    // Standard Bayer Dithering Path with CFA Bias
    // =========================================================================

    localparam BIAS = 9'd10;

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

    // Adjusted bias: BIAS + FATTEN - CFA_BIAS
    // FATTEN lowers threshold (more pixels ON = fatter text)
    // CFA_BIAS raises threshold (fewer pixels ON for that color)
    wire signed [9:0] adj_bias_02 = $signed({1'b0, BIAS}) + $signed({1'b0, FATTEN[8:0]}) - $signed({2'b0, cfa_bias_02});
    wire signed [9:0] adj_bias_13 = $signed({1'b0, BIAS}) + $signed({1'b0, FATTEN[8:0]}) - $signed({2'b0, cfa_bias_13});

    // Clamp to valid range
    wire [8:0] bias_02 = (adj_bias_02 < 0) ? 9'd0 : (adj_bias_02 > 255) ? 9'd255 : adj_bias_02[8:0];
    wire [8:0] bias_13 = (adj_bias_13 < 0) ? 9'd0 : (adj_bias_13 > 255) ? 9'd255 : adj_bias_13[8:0];

    wire [8:0] a0 = {1'b0, pix0} + bias_02;
    wire [8:0] a1 = {1'b0, pix1} + bias_13;
    wire [8:0] a2 = {1'b0, pix2} + bias_02;
    wire [8:0] a3 = {1'b0, pix3} + bias_13;

    wire [3:0] c0, c1, c2, c3;
    adder_sat adder_sat0 (a0[8:4], b0, c0);
    adder_sat adder_sat1 (a1[8:4], b1, c1);
    adder_sat adder_sat2 (a2[8:4], b2, c2);
    adder_sat adder_sat3 (a3[8:4], b3, c3);

    // 1-bit output: just MSB (binary dithering)
    wire [3:0] bayer_out_1b = {c0[3], c1[3], c2[3], c3[3]};

    // 2-bit output: Scale down bayer offsets for 4-level mode
    // For 4 levels, we want dithering within each level band, not across all levels
    // Use halved bayer offsets (b/2) to preserve more contrast
    wire [3:0] b0_half = {b0[3], b0[3:1]};  // Arithmetic shift right (sign extend)
    wire [3:0] b1_half = {b1[3], b1[3:1]};
    wire [3:0] b2_half = {b2[3], b2[3:1]};
    wire [3:0] b3_half = {b3[3], b3[3:1]};

    wire [3:0] c0_4lvl, c1_4lvl, c2_4lvl, c3_4lvl;
    adder_sat adder_sat0_4lvl (a0[8:4], b0_half, c0_4lvl);
    adder_sat adder_sat1_4lvl (a1[8:4], b1_half, c1_4lvl);
    adder_sat adder_sat2_4lvl (a2[8:4], b2_half, c2_4lvl);
    adder_sat adder_sat3_4lvl (a3[8:4], b3_half, c3_4lvl);

    // 2-bit output: top 2 bits with reduced dithering
    wire [7:0] bayer_out_2b = {c0_4lvl[3:2], c1_4lvl[3:2], c2_4lvl[3:2], c3_4lvl[3:2]};

    // For backward compatibility, keep bayer_out as 1-bit
    wire [3:0] bayer_out = bayer_out_1b;

    // =========================================================================
    // Simple Threshold Path (for edges - no dithering)
    // =========================================================================

    // 1-bit: MSB threshold
    wire [3:0] simple_out_1b = {pix0[7], pix1[7], pix2[7], pix3[7]};
    // 2-bit: top 2 bits (4 levels)
    wire [7:0] simple_out_2b = {pix0[7:6], pix1[7:6], pix2[7:6], pix3[7:6]};
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
    // =========================================================================
    
    // Helper function to find max of two 8-bit values
    function [7:0] max2;
        input [7:0] a, b;
        begin
            max2 = (a > b) ? a : b;
        end
    endfunction
    
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
            // Match 1-bit Bayer behavior exactly:
            // - MSB = c[3] from 1-bit Bayer (decides white vs black)
            // - LSB = c[2] from 4-level calc (decides gray level within half)
            // When 1-bit says white (c[3]=1), output is 10 or 11
            // When 1-bit says black (c[3]=0), output is 00 or 01
            wire [1:0] out0 = {bayer_out_1b[3], c0_4lvl[2]};
            wire [1:0] out1 = {bayer_out_1b[2], c1_4lvl[2]};
            wire [1:0] out2 = {bayer_out_1b[1], c2_4lvl[2]};
            wire [1:0] out3 = {bayer_out_1b[0], c3_4lvl[2]};
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
