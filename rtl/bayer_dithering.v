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
//
// 1 cycle latency (same as original)
`timescale 1ns / 1ps
`default_nettype none

module bayer_dithering #(
    parameter COLORMODE = "RGBW",
    parameter LINE_WIDTH_MAX = 2200,  // Max pixels per line (compile-time buffer sizing)
    parameter EDGE_THRESH_LOW = 80,   // Below this: full dithering (smooth gradients)
    parameter EDGE_THRESH_HIGH = 160  // Above this: full simple threshold (sharp text)
) (
    input wire        clk,
    input wire        rst,
    input wire [31:0] vin,
    output reg [3:0]  vout,
    input wire [10:0] x_cnt,      // Full x counter for line buffer addressing
    input wire [10:0] y_cnt,      // Full y counter for line change detection
    input wire [2:0]  x_pos,      // X position for Bayer matrix (mod 8)
    input wire [2:0]  y_pos       // Y position for Bayer matrix (mod 8)
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
    // Standard Bayer Dithering Path
    // =========================================================================
    
    localparam BIAS = 9'd10;
    
    wire [7:0] pix0 = vin[31:24];
    wire [7:0] pix1 = vin[23:16];
    wire [7:0] pix2 = vin[15:8];
    wire [7:0] pix3 = vin[7:0];
    
    wire [8:0] a0 = {1'b0, pix0} + BIAS;
    wire [8:0] a1 = {1'b0, pix1} + BIAS;
    wire [8:0] a2 = {1'b0, pix2} + BIAS;
    wire [8:0] a3 = {1'b0, pix3} + BIAS;

    wire [3:0] c0, c1, c2, c3;
    adder_sat adder_sat0 (a0[8:4], b0, c0);
    adder_sat adder_sat1 (a1[8:4], b1, c1);
    adder_sat adder_sat2 (a2[8:4], b2, c2);
    adder_sat adder_sat3 (a3[8:4], b3, c3);
    
    wire [3:0] bayer_out = {c0[3], c1[3], c2[3], c3[3]};

    // =========================================================================
    // Simple Threshold Path (for edges - no dithering)
    // =========================================================================
    
    wire [3:0] simple_out = {pix0[7], pix1[7], pix2[7], pix3[7]};

    // =========================================================================
    // Edge Detection - Horizontal (gradient magnitude)
    // =========================================================================
    
    reg [31:0] prev_vin;
    always @(posedge clk) begin
        prev_vin <= vin;
    end
    
    wire [7:0] prev_pix3 = prev_vin[7:0];
    
    wire [7:0] h_diff_0 = (pix0 > prev_pix3) ? (pix0 - prev_pix3) : (prev_pix3 - pix0);
    wire [7:0] h_diff_1 = (pix1 > pix0) ? (pix1 - pix0) : (pix0 - pix1);
    wire [7:0] h_diff_2 = (pix2 > pix1) ? (pix2 - pix1) : (pix1 - pix2);
    wire [7:0] h_diff_3 = (pix3 > pix2) ? (pix3 - pix2) : (pix2 - pix3);

    // =========================================================================
    // Edge Detection - Vertical (gradient magnitude)
    // =========================================================================
    
    localparam LINE_BUF_DEPTH = (LINE_WIDTH_MAX + 3) / 4;
    localparam LINE_BUF_AW = clog2(LINE_BUF_DEPTH);
    
    (* ram_style = "distributed" *)
    reg [31:0] line_buffer [0:LINE_BUF_DEPTH-1];
    
    wire [LINE_BUF_AW-1:0] line_buf_addr = x_cnt[10:2];
    
    wire [31:0] prev_line_pixels = line_buffer[line_buf_addr];
    wire [7:0] prev_line_pix0 = prev_line_pixels[31:24];
    wire [7:0] prev_line_pix1 = prev_line_pixels[23:16];
    wire [7:0] prev_line_pix2 = prev_line_pixels[15:8];
    wire [7:0] prev_line_pix3 = prev_line_pixels[7:0];
    
    always @(posedge clk) begin
        line_buffer[line_buf_addr] <= vin;
    end
    
    wire [7:0] v_diff_0 = (pix0 > prev_line_pix0) ? (pix0 - prev_line_pix0) : (prev_line_pix0 - pix0);
    wire [7:0] v_diff_1 = (pix1 > prev_line_pix1) ? (pix1 - prev_line_pix1) : (prev_line_pix1 - pix1);
    wire [7:0] v_diff_2 = (pix2 > prev_line_pix2) ? (pix2 - prev_line_pix2) : (prev_line_pix2 - pix2);
    wire [7:0] v_diff_3 = (pix3 > prev_line_pix3) ? (pix3 - prev_line_pix3) : (prev_line_pix3 - pix3);

    // =========================================================================
    // Edge Detection - Diagonal
    // =========================================================================
    
    reg [31:0] prev_prev_line_pixels;
    always @(posedge clk) begin
        prev_prev_line_pixels <= prev_line_pixels;
    end
    wire [7:0] prev_prev_line_pix3 = prev_prev_line_pixels[7:0];
    
    wire [7:0] d_ul_diff_0 = (pix0 > prev_prev_line_pix3) ? (pix0 - prev_prev_line_pix3) : (prev_prev_line_pix3 - pix0);
    wire [7:0] d_ul_diff_1 = (pix1 > prev_line_pix0) ? (pix1 - prev_line_pix0) : (prev_line_pix0 - pix1);
    wire [7:0] d_ul_diff_2 = (pix2 > prev_line_pix1) ? (pix2 - prev_line_pix1) : (prev_line_pix1 - pix2);
    wire [7:0] d_ul_diff_3 = (pix3 > prev_line_pix2) ? (pix3 - prev_line_pix2) : (prev_line_pix2 - pix3);
    
    wire [7:0] d_ur_diff_0 = (pix0 > prev_line_pix1) ? (pix0 - prev_line_pix1) : (prev_line_pix1 - pix0);
    wire [7:0] d_ur_diff_1 = (pix1 > prev_line_pix2) ? (pix1 - prev_line_pix2) : (prev_line_pix2 - pix1);
    wire [7:0] d_ur_diff_2 = (pix2 > prev_line_pix3) ? (pix2 - prev_line_pix3) : (prev_line_pix3 - pix2);

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
    wire [7:0] max_grad_0 = max2(max2(h_diff_0, v_diff_0), max2(d_ul_diff_0, d_ur_diff_0));
    wire [7:0] max_grad_1 = max2(max2(h_diff_1, v_diff_1), max2(d_ul_diff_1, d_ur_diff_1));
    wire [7:0] max_grad_2 = max2(max2(h_diff_2, v_diff_2), max2(d_ul_diff_2, d_ur_diff_2));
    wire [7:0] max_grad_3 = max2(max2(h_diff_3, v_diff_3), d_ul_diff_3);  // No d_ur for pix3

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
    
    wire [3:0] final_out;
    assign final_out[3] = use_simple_0 ? simple_out[3] : bayer_out[3];
    assign final_out[2] = use_simple_1 ? simple_out[2] : bayer_out[2];
    assign final_out[1] = use_simple_2 ? simple_out[1] : bayer_out[1];
    assign final_out[0] = use_simple_3 ? simple_out[0] : bayer_out[0];

    // Output register (1 cycle latency, same as original)
    always @(posedge clk) begin
        if (rst) begin
            vout <= 4'b0;
        end
        else begin
            vout <= final_out;
        end
    end

endmodule

`default_nettype wire
