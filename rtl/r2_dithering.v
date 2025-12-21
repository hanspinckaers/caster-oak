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
//
// Based on: https://blog.demofox.org/2022/02/01/two-low-discrepancy-grids/
//
// 1 cycle latency (same as original, drop-in replacement)
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
    //   W: -64 (White contributes most to perceived brightness)
    //   G: -32 (Green is most visible to human eye)
    //   R: -20 (Red medium contribution)
    //   B: -8  (Blue least visible, small bias)
    //
    // Global brightness bias (positive = brighter output):
    //   Added to all pixels before dithering to improve overall brightness
    // =========================================================================
    localparam [8:0] GLOBAL_BIAS = 9'd12;  // Global brightness boost
    
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
            // B at (even_x, even_y)
            assign cfa_bias_0 = is_w0 ? -8'sd64 : is_g0 ? -8'sd32 : is_r0 ? -8'sd20 : -8'sd8;
            
            // Pixel 1: x_pos + 1
            wire is_w1 = (y_pos[0] == 1'b0) && (x1[0] == 1'b1);
            wire is_g1 = (y_pos[0] == 1'b1) && (x1[0] == 1'b0);
            wire is_r1 = (y_pos[0] == 1'b1) && (x1[0] == 1'b1);
            assign cfa_bias_1 = is_w1 ? -8'sd64 : is_g1 ? -8'sd32 : is_r1 ? -8'sd20 : -8'sd8;
            
            // Pixel 2: x_pos + 2
            wire is_w2 = (y_pos[0] == 1'b0) && (x2[0] == 1'b1);
            wire is_g2 = (y_pos[0] == 1'b1) && (x2[0] == 1'b0);
            wire is_r2 = (y_pos[0] == 1'b1) && (x2[0] == 1'b1);
            assign cfa_bias_2 = is_w2 ? -8'sd64 : is_g2 ? -8'sd32 : is_r2 ? -8'sd20 : -8'sd8;
            
            // Pixel 3: x_pos + 3
            wire is_w3 = (y_pos[0] == 1'b0) && (x3[0] == 1'b1);
            wire is_g3 = (y_pos[0] == 1'b1) && (x3[0] == 1'b0);
            wire is_r3 = (y_pos[0] == 1'b1) && (x3[0] == 1'b1);
            assign cfa_bias_3 = is_w3 ? -8'sd64 : is_g3 ? -8'sd32 : is_r3 ? -8'sd20 : -8'sd8;
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

    // Input pixels with global brightness bias (saturate to 255)
    wire [8:0] pix0_biased = {1'b0, vin[31:24]} + GLOBAL_BIAS;
    wire [8:0] pix1_biased = {1'b0, vin[23:16]} + GLOBAL_BIAS;
    wire [8:0] pix2_biased = {1'b0, vin[15:8]} + GLOBAL_BIAS;
    wire [8:0] pix3_biased = {1'b0, vin[7:0]} + GLOBAL_BIAS;
    
    wire [7:0] pix0 = pix0_biased[8] ? 8'd255 : pix0_biased[7:0];
    wire [7:0] pix1 = pix1_biased[8] ? 8'd255 : pix1_biased[7:0];
    wire [7:0] pix2 = pix2_biased[8] ? 8'd255 : pix2_biased[7:0];
    wire [7:0] pix3 = pix3_biased[8] ? 8'd255 : pix3_biased[7:0];

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

    // Output: take top OUTPUT_BITS from each pixel
    wire [OUTPUT_BITS*4-1:0] dithered = {
        sat0[7-:OUTPUT_BITS],
        sat1[7-:OUTPUT_BITS],
        sat2[7-:OUTPUT_BITS],
        sat3[7-:OUTPUT_BITS]
    };

    // Output register (1 cycle latency)
    always @(posedge clk) begin
        vout <= dithered;
    end

endmodule

`default_nettype wire
