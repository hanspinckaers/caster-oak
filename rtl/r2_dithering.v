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
// R2 Low Discrepancy Grid dithering implementation, 1 cycle latency
// Based on: https://blog.demofox.org/2022/02/01/two-low-discrepancy-grids-plus-shaped-sampling-ldg-and-r2-ldg/
//
// R2 sequence provides better spatial distribution than Bayer while being
// fully deterministic (no temporal flicker). Good for e-ink displays.
//
// threshold = fract(x * phi2 + y * phi2^2)
// where phi2 = 0.7548776662466927 (plastic constant)
// and phi2^2 = 0.5698402909980532
//
`timescale 1ns / 1ps
`default_nettype none

module r2_dithering #(
    parameter OUTPUT_BITS = 1, // 1 or 4
    parameter COLORMODE = "MONO"
) (
    input wire                      clk,
    input wire [31:0]               vin,        // 4 pixels x 8 bits
    output reg [OUTPUT_BITS*4-1:0]  vout,
    input wire [10:0]               x_pos,      // Pixel x position (from scan_h_cnt)
    input wire [10:0]               y_pos       // Pixel y position (from scan_v_cnt)
);

    // For 1-bit output, use full noise range
    // For 4-bit output, attenuate noise to avoid excessive dithering

    // R2 constants in 8.8 fixed point (scaled to get 8-bit fractional output)
    // phi2   = 0.7548776662 * 256 = 193.25 ≈ 193 = 0xC1
    // phi2^2 = 0.5698402909 * 256 = 145.88 ≈ 146 = 0x92
    localparam [7:0] R2_PHI2 = 8'd193;
    localparam [7:0] R2_PHI2_SQ = 8'd146;

    // Noise attenuation for 4-bit output mode
    localparam NOISE_ATTEN = (OUTPUT_BITS == 1) ? 0 : 4;

    // Calculate x offsets for 4 adjacent pixels
    // In MONO mode: pixels are at x+0, x+1, x+2, x+3
    // In RGBW mode: pixels are at x+0, x+0, x+1, x+1 (subpixel pairs)
    wire [10:0] x0, x1, x2, x3;
    
    generate
        if (COLORMODE == "RGBW") begin: gen_rgbw_x
            assign x0 = x_pos;
            assign x1 = x_pos;
            assign x2 = x_pos + 11'd1;
            assign x3 = x_pos + 11'd1;
        end
        else begin: gen_mono_x
            assign x0 = x_pos;
            assign x1 = x_pos + 11'd1;
            assign x2 = x_pos + 11'd2;
            assign x3 = x_pos + 11'd3;
        end
    endgenerate

    // Compute R2 threshold for each pixel
    // threshold = (x * R2_PHI2 + y * R2_PHI2_SQ) mod 256
    // We only keep the lower 8 bits (fractional part)
    wire [18:0] r2_full_0 = x0 * R2_PHI2 + y_pos * R2_PHI2_SQ;
    wire [18:0] r2_full_1 = x1 * R2_PHI2 + y_pos * R2_PHI2_SQ;
    wire [18:0] r2_full_2 = x2 * R2_PHI2 + y_pos * R2_PHI2_SQ;
    wire [18:0] r2_full_3 = x3 * R2_PHI2 + y_pos * R2_PHI2_SQ;

    // Extract 8-bit threshold (keep lower bits for fract())
    wire [7:0] thresh0 = r2_full_0[7:0];
    wire [7:0] thresh1 = r2_full_1[7:0];
    wire [7:0] thresh2 = r2_full_2[7:0];
    wire [7:0] thresh3 = r2_full_3[7:0];

    // Input pixels (8 bits each, MSB first)
    wire [7:0] pix0 = vin[31:24];
    wire [7:0] pix1 = vin[23:16];
    wire [7:0] pix2 = vin[15:8];
    wire [7:0] pix3 = vin[7:0];

    // Convert threshold to signed offset (-128 to +127)
    wire signed [8:0] offset0 = {1'b0, thresh0} - 9'd128;
    wire signed [8:0] offset1 = {1'b0, thresh1} - 9'd128;
    wire signed [8:0] offset2 = {1'b0, thresh2} - 9'd128;
    wire signed [8:0] offset3 = {1'b0, thresh3} - 9'd128;

    // Apply noise attenuation for 4-bit mode
    wire signed [8:0] atten_offset0 = offset0 >>> NOISE_ATTEN;
    wire signed [8:0] atten_offset1 = offset1 >>> NOISE_ATTEN;
    wire signed [8:0] atten_offset2 = offset2 >>> NOISE_ATTEN;
    wire signed [8:0] atten_offset3 = offset3 >>> NOISE_ATTEN;

    // Add offset to pixel with saturation
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

    always @(posedge clk) begin
        vout <= dithered;
    end

endmodule

`default_nettype wire
