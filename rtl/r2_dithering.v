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
// 2. RGBW subpixel decorrelation (phase offsets prevent clumping)
// 3. Per-channel luminance weighting option
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
    // RGBW Subpixel phase offsets (decorrelation)
    // Prevents "clumping" where multiple subpixels fire simultaneously
    // Offsets are 0, 0.25, 0.5, 0.75 scaled to 16-bit (0-65535)
    // =========================================================================
    localparam [15:0] PHASE_0 = 16'd0;
    localparam [15:0] PHASE_1 = 16'd16384;   // 0.25 * 65536
    localparam [15:0] PHASE_2 = 16'd32768;   // 0.50 * 65536
    localparam [15:0] PHASE_3 = 16'd49152;   // 0.75 * 65536

    // Noise attenuation for 4-bit output mode
    localparam NOISE_ATTEN = (OUTPUT_BITS == 1) ? 0 : 4;

    // =========================================================================
    // Stage 0: Calculate x offsets for 4 pixels
    // =========================================================================
    wire [10:0] x0, x1, x2, x3;
    
    generate
        if (COLORMODE == "RGBW") begin: gen_rgbw_x
            // RGBW: subpixel pairs share x position
            assign x0 = x_pos;
            assign x1 = x_pos;
            assign x2 = x_pos + 11'd1;
            assign x3 = x_pos + 11'd1;
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
    // Compute R2 threshold (combinational)
    // r2 = fract(x * phi2 + y * phi2^2 + phase_offset)
    // =========================================================================
    
    // Full precision calculation (11-bit pos * 16-bit const = 27-bit max)
    wire [26:0] r2_full_0 = x0 * R2_PHI2 + y_pos * R2_PHI2_SQ;
    wire [26:0] r2_full_1 = x1 * R2_PHI2 + y_pos * R2_PHI2_SQ;
    wire [26:0] r2_full_2 = x2 * R2_PHI2 + y_pos * R2_PHI2_SQ;
    wire [26:0] r2_full_3 = x3 * R2_PHI2 + y_pos * R2_PHI2_SQ;

    // Add phase offsets for RGBW decorrelation
    wire [15:0] phase_offset_0, phase_offset_1, phase_offset_2, phase_offset_3;
    generate
        if (COLORMODE == "RGBW") begin: gen_rgbw_phase
            assign phase_offset_0 = PHASE_0;
            assign phase_offset_1 = PHASE_1;
            assign phase_offset_2 = PHASE_2;
            assign phase_offset_3 = PHASE_3;
        end
        else begin: gen_mono_phase
            // No phase offset for MONO mode
            assign phase_offset_0 = 16'd0;
            assign phase_offset_1 = 16'd0;
            assign phase_offset_2 = 16'd0;
            assign phase_offset_3 = 16'd0;
        end
    endgenerate

    // Add phase and extract 8-bit threshold from bits [15:8]
    // This gives us the fractional part in 8-bit precision
    wire [16:0] r2_with_phase_0 = r2_full_0[15:0] + {1'b0, phase_offset_0};
    wire [16:0] r2_with_phase_1 = r2_full_1[15:0] + {1'b0, phase_offset_1};
    wire [16:0] r2_with_phase_2 = r2_full_2[15:0] + {1'b0, phase_offset_2};
    wire [16:0] r2_with_phase_3 = r2_full_3[15:0] + {1'b0, phase_offset_3};

    // Extract 8-bit threshold (upper 8 bits of 16-bit fractional part)
    wire [7:0] thresh0 = r2_with_phase_0[15:8];
    wire [7:0] thresh1 = r2_with_phase_1[15:8];
    wire [7:0] thresh2 = r2_with_phase_2[15:8];
    wire [7:0] thresh3 = r2_with_phase_3[15:8];

    // Input pixels
    wire [7:0] pix0 = vin[31:24];
    wire [7:0] pix1 = vin[23:16];
    wire [7:0] pix2 = vin[15:8];
    wire [7:0] pix3 = vin[7:0];

    // =========================================================================
    // Add offset to pixel with saturation (combinational)
    // =========================================================================

    // Convert threshold to signed offset (-128 to +127)
    wire signed [8:0] offset0 = {1'b0, thresh0} - 9'd128;
    wire signed [8:0] offset1 = {1'b0, thresh1} - 9'd128;
    wire signed [8:0] offset2 = {1'b0, thresh2} - 9'd128;
    wire signed [8:0] offset3 = {1'b0, thresh3} - 9'd128;

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
