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
// Improved R2 Low Discrepancy Grid dithering with:
// 1. Higher precision (16-bit) constants for reduced moire
// 2. CFA-aware brightness bias for RGBW panels
//    - W (White) subpixel biased toward white for better brightness
//    - Accounts for BW/GR 2x2 CFA layout
// 3. Gradient-weighted edge detection with soft blending
//    - Instead of binary threshold, uses gradient magnitude for smooth blending
//    - Eliminates stripe artifacts in images while preserving sharp text edges
//    - Text (high gradient >160) gets full edge-aware treatment
//    - Images (lower gradients) retain smooth dithering
//
// Based on: https://blog.demofox.org/2022/02/01/two-low-discrepancy-grids/
//
// 1 cycle latency (same as original, drop-in replacement)
`timescale 1ns / 1ps
`default_nettype none

module r2_dithering #(
    parameter OUTPUT_BITS = 1,      // 1 or 4
    parameter COLORMODE = "RGBW",
    parameter LINE_WIDTH_MAX = 2200,  // Max pixels per line (compile-time buffer sizing)
    parameter EDGE_THRESH_LOW = 80,   // Below this: full dithering (smooth gradients)
    parameter EDGE_THRESH_HIGH = 160  // Above this: full simple threshold (sharp text)
) (
    input wire                      clk,
    input wire                      rst,
    input wire [31:0]               vin,        // 4 pixels x 8 bits
    output reg [OUTPUT_BITS*4-1:0]  vout,
    input wire [10:0]               x_cnt,      // Full x counter for line buffer addressing
    input wire [10:0]               x_pos,      // Pixel x position
    input wire [10:0]               y_pos       // Pixel y position
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
    // High-precision R2 constants (16-bit fixed point, 0.16 format)
    // phi2   = 0.7548776662 * 65536 = 49471.2 ≈ 49471 (0xC13F)
    // phi2^2 = 0.5698402909 * 65536 = 37346.7 ≈ 37347 (0x91E3)
    // Higher precision reduces moire patterns on uniform gray areas
    // =========================================================================
    localparam [15:0] R2_PHI2    = 16'd49471;
    localparam [15:0] R2_PHI2_SQ = 16'd37347;

    // =========================================================================
    // CFA-aware brightness bias for RGBW
    // CFA Layout (2x2 repeating):
    //   BW  (y%2==0: x%2==0 is B, x%2==1 is W)
    //   GR  (y%2==1: x%2==0 is G, x%2==1 is R)
    //
    // Bias values (negative = brighter output):
    //   W: -40 (White contributes most to perceived brightness)
    //   G: -16 (Green is most visible to human eye)
    //   R: -16 (Red medium contribution)
    //   B:   0 (Blue least visible, no bias)
    // =========================================================================
    
    // Noise attenuation for 4-bit output mode
    localparam NOISE_ATTEN = (OUTPUT_BITS == 1) ? 0 : 4;

    // =========================================================================
    // Stage 0: Calculate x offsets for 4 pixels and determine CFA position
    // =========================================================================
    wire [10:0] x0, x1, x2, x3;
    
    generate
        if (COLORMODE == "RGBW") begin: gen_rgbw_x
            // RGBW: 4 consecutive pixels horizontally
            assign x0 = x_pos;
            assign x1 = x_pos + 11'd1;
            assign x2 = x_pos + 11'd2;
            assign x3 = x_pos + 11'd3;
        end
        else begin: gen_mono_x
            // MONO/DES: consecutive pixels
            assign x0 = x_pos;
            assign x1 = x_pos + 11'd1;
            assign x2 = x_pos + 11'd2;
            assign x3 = x_pos + 11'd3;
        end
    endgenerate

    // =========================================================================
    // CFA-aware brightness bias calculation
    // For each pixel, determine subpixel type and apply appropriate bias
    // =========================================================================
    wire signed [7:0] cfa_bias_0, cfa_bias_1, cfa_bias_2, cfa_bias_3;
    
    generate
        if (COLORMODE == "RGBW") begin: gen_rgbw_bias
            // Determine subpixel type for each of 4 pixels
            // y_pos[0]: 0=even row (BW), 1=odd row (GR)
            // x[0]: 0=left subpixel (B or G), 1=right subpixel (W or R)
            
            // Pixel 0: x_pos
            wire is_w0 = (y_pos[0] == 1'b0) && (x0[0] == 1'b1);  // W at (odd_x, even_y)
            wire is_g0 = (y_pos[0] == 1'b1) && (x0[0] == 1'b0);  // G at (even_x, odd_y)
            wire is_r0 = (y_pos[0] == 1'b1) && (x0[0] == 1'b1);  // R at (odd_x, odd_y)
            // B at (even_x, even_y) - no bias
            assign cfa_bias_0 = is_w0 ? -8'sd40 : (is_g0 || is_r0) ? -8'sd16 : 8'sd0;
            
            // Pixel 1: x_pos + 1
            wire is_w1 = (y_pos[0] == 1'b0) && (x1[0] == 1'b1);
            wire is_g1 = (y_pos[0] == 1'b1) && (x1[0] == 1'b0);
            wire is_r1 = (y_pos[0] == 1'b1) && (x1[0] == 1'b1);
            assign cfa_bias_1 = is_w1 ? -8'sd40 : (is_g1 || is_r1) ? -8'sd16 : 8'sd0;
            
            // Pixel 2: x_pos + 2
            wire is_w2 = (y_pos[0] == 1'b0) && (x2[0] == 1'b1);
            wire is_g2 = (y_pos[0] == 1'b1) && (x2[0] == 1'b0);
            wire is_r2 = (y_pos[0] == 1'b1) && (x2[0] == 1'b1);
            assign cfa_bias_2 = is_w2 ? -8'sd40 : (is_g2 || is_r2) ? -8'sd16 : 8'sd0;
            
            // Pixel 3: x_pos + 3
            wire is_w3 = (y_pos[0] == 1'b0) && (x3[0] == 1'b1);
            wire is_g3 = (y_pos[0] == 1'b1) && (x3[0] == 1'b0);
            wire is_r3 = (y_pos[0] == 1'b1) && (x3[0] == 1'b1);
            assign cfa_bias_3 = is_w3 ? -8'sd40 : (is_g3 || is_r3) ? -8'sd16 : 8'sd0;
        end
        else begin: gen_mono_bias
            // No CFA bias for MONO mode
            assign cfa_bias_0 = 8'sd0;
            assign cfa_bias_1 = 8'sd0;
            assign cfa_bias_2 = 8'sd0;
            assign cfa_bias_3 = 8'sd0;
        end
    endgenerate

    // =========================================================================
    // Compute R2 threshold (combinational)
    // r2 = fract(x * phi2 + y * phi2^2)
    // =========================================================================
    
    // Full precision calculation (11-bit pos * 16-bit const = 27-bit max)
    wire [26:0] r2_full_0 = x0 * R2_PHI2 + y_pos * R2_PHI2_SQ;
    wire [26:0] r2_full_1 = x1 * R2_PHI2 + y_pos * R2_PHI2_SQ;
    wire [26:0] r2_full_2 = x2 * R2_PHI2 + y_pos * R2_PHI2_SQ;
    wire [26:0] r2_full_3 = x3 * R2_PHI2 + y_pos * R2_PHI2_SQ;

    // Extract 8-bit threshold (upper 8 bits of 16-bit fractional part)
    wire [7:0] thresh0 = r2_full_0[15:8];
    wire [7:0] thresh1 = r2_full_1[15:8];
    wire [7:0] thresh2 = r2_full_2[15:8];
    wire [7:0] thresh3 = r2_full_3[15:8];

    // Input pixels
    wire [7:0] pix0 = vin[31:24];
    wire [7:0] pix1 = vin[23:16];
    wire [7:0] pix2 = vin[15:8];
    wire [7:0] pix3 = vin[7:0];

    // =========================================================================
    // Add offset to pixel with saturation (combinational)
    // Includes CFA-aware brightness bias
    // =========================================================================

    // Convert threshold to signed offset (-128 to +127) and add CFA bias
    wire signed [8:0] offset0 = ({1'b0, thresh0} - 9'sd128) + {cfa_bias_0[7], cfa_bias_0};
    wire signed [8:0] offset1 = ({1'b0, thresh1} - 9'sd128) + {cfa_bias_1[7], cfa_bias_1};
    wire signed [8:0] offset2 = ({1'b0, thresh2} - 9'sd128) + {cfa_bias_2[7], cfa_bias_2};
    wire signed [8:0] offset3 = ({1'b0, thresh3} - 9'sd128) + {cfa_bias_3[7], cfa_bias_3};

    // Apply noise attenuation
    wire signed [8:0] atten_offset0 = offset0 >>> NOISE_ATTEN;
    wire signed [8:0] atten_offset1 = offset1 >>> NOISE_ATTEN;
    wire signed [8:0] atten_offset2 = offset2 >>> NOISE_ATTEN;
    wire signed [8:0] atten_offset3 = offset3 >>> NOISE_ATTEN;

    // Add offset to pixel (extra bit for overflow detection)
    wire signed [9:0] sum0 = {1'b0, pix0, 1'b0} + {atten_offset0, 1'b0};
    wire signed [9:0] sum1 = {1'b0, pix1, 1'b0} + {atten_offset1, 1'b0};
    wire signed [9:0] sum2 = {1'b0, pix2, 1'b0} + {atten_offset2, 1'b0};
    wire signed [9:0] sum3 = {1'b0, pix3, 1'b0} + {atten_offset3, 1'b0};

    // Saturate to 0-255 range
    wire [7:0] sat0 = (sum0[9]) ? 8'd0 : (sum0[8]) ? 8'd255 : sum0[8:1];
    wire [7:0] sat1 = (sum1[9]) ? 8'd0 : (sum1[8]) ? 8'd255 : sum1[8:1];
    wire [7:0] sat2 = (sum2[9]) ? 8'd0 : (sum2[8]) ? 8'd255 : sum2[8:1];
    wire [7:0] sat3 = (sum3[9]) ? 8'd0 : (sum3[8]) ? 8'd255 : sum3[8:1];

    // R2 dithered output: take top OUTPUT_BITS from each pixel
    wire [OUTPUT_BITS*4-1:0] r2_out = {
        sat0[7-:OUTPUT_BITS],
        sat1[7-:OUTPUT_BITS],
        sat2[7-:OUTPUT_BITS],
        sat3[7-:OUTPUT_BITS]
    };

    // =========================================================================
    // Simple Threshold Path (for edges - no dithering)
    // =========================================================================
    
    wire [OUTPUT_BITS*4-1:0] simple_out = {
        pix0[7-:OUTPUT_BITS],
        pix1[7-:OUTPUT_BITS],
        pix2[7-:OUTPUT_BITS],
        pix3[7-:OUTPUT_BITS]
    };

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
    
    function [7:0] max2;
        input [7:0] a, b;
        begin
            max2 = (a > b) ? a : b;
        end
    endfunction
    
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
    // For the transition zone, we use the R2 sequence position as a
    // spatial dither to decide between dithered and simple output.
    // This creates a smooth visual transition without visible stripes.
    // =========================================================================
    
    localparam [7:0] THRESH_RANGE = EDGE_THRESH_HIGH - EDGE_THRESH_LOW;
    
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
    // Output MUX: Select R2 dithered or simple based on soft edge detection
    // =========================================================================
    
    wire [OUTPUT_BITS*4-1:0] final_out;
    
    generate
        if (OUTPUT_BITS == 1) begin: gen_1bit_mux
            assign final_out[3] = use_simple_0 ? simple_out[3] : r2_out[3];
            assign final_out[2] = use_simple_1 ? simple_out[2] : r2_out[2];
            assign final_out[1] = use_simple_2 ? simple_out[1] : r2_out[1];
            assign final_out[0] = use_simple_3 ? simple_out[0] : r2_out[0];
        end
        else begin: gen_4bit_mux
            assign final_out[15:12] = use_simple_0 ? simple_out[15:12] : r2_out[15:12];
            assign final_out[11:8]  = use_simple_1 ? simple_out[11:8]  : r2_out[11:8];
            assign final_out[7:4]   = use_simple_2 ? simple_out[7:4]   : r2_out[7:4];
            assign final_out[3:0]   = use_simple_3 ? simple_out[3:0]   : r2_out[3:0];
        end
    endgenerate

    // Output register (1 cycle latency)
    always @(posedge clk) begin
        if (rst) begin
            vout <= {OUTPUT_BITS*4{1'b0}};
        end
        else begin
            vout <= final_out;
        end
    end

endmodule

`default_nettype wire
