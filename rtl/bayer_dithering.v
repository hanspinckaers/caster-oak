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
// 1. Phase-scrambling to break visible grid pattern
// 2. Edge-aware bypass for sharp text/lines (horizontal + vertical)
//
// 1 cycle latency (same as original)
`timescale 1ns / 1ps
`default_nettype none

module bayer_dithering #(
    parameter COLORMODE = "RGBW",
    parameter LINE_WIDTH = 2200  // Max pixels per line (for line buffer)
) (
    input wire        clk,
    input wire        rst,
    input wire [31:0] vin,
    output reg [3:0]  vout,
    input wire [10:0] x_cnt,      // Full x counter for line buffer addressing
    input wire [10:0] y_cnt,      // Full y counter for line change detection
    input wire [2:0]  x_pos,      // X position for Bayer matrix (mod 8)
    input wire [2:0]  y_pos       // Y position for Bayer matrix (mod 8)
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
    // Phase Scrambling: Shift X index based on Y position
    // This breaks vertical alignment of dither pattern
    // =========================================================================
    
    // Shift pattern every 4 rows using higher Y bits
    wire [1:0] phase_shift = y_cnt[3:2];
    wire [1:0] x_scrambled = x_pos[1:0] + phase_shift;

    // =========================================================================
    // Bayer Matrix Lookup (with scrambled X index)
    // =========================================================================
    
    wire [3:0] b0, b1, b2, b3;

    generate
    if (COLORMODE == "MONO") begin: gen_mono_dither
        // MONO mode uses y_pos[1:0] only, no x dependency in original
        // Add phase scrambling to break pattern
        wire [1:0] y_idx = y_pos[1:0] + phase_shift;
        assign b0 =
            (y_idx == 2'b00) ? (-4'd8) :
            (y_idx == 2'b01) ? (4'd4) :
            (y_idx == 2'b10) ? (-4'd5) :
                               (4'd7);
        assign b1 =
            (y_idx == 2'b00) ? (4'd0) :
            (y_idx == 2'b01) ? (-4'd4) :
            (y_idx == 2'b10) ? (4'd3) :
                               (-4'd1);
        assign b2 =
            (y_idx == 2'b00) ? (-4'd6) :
            (y_idx == 2'b01) ? (4'd6) :
            (y_idx == 2'b10) ? (-4'd7) :
                               (4'd5);
        assign b3 =
            (y_idx == 2'b00) ? (4'd2) :
            (y_idx == 2'b01) ? (-4'd2) :
            (y_idx == 2'b10) ? (4'd1) :
                               (-4'd3);
    end
    else if (COLORMODE == "DES") begin: gen_des_dither
        assign b0 =
            (y_pos[2:0] == 3'd0) ? ((x_scrambled == 2'd0) ? (-4'd7) : (x_scrambled == 2'd1) ? ( 4'd7) : ( 4'd0)) :
            (y_pos[2:0] == 3'd1) ? ((x_scrambled == 2'd0) ? (-4'd7) : (x_scrambled == 2'd1) ? ( 4'd0) : ( 4'd0)) :
                                   ((x_scrambled == 2'd0) ? (-4'd7) : (x_scrambled == 2'd1) ? ( 4'd7) : ( 4'd7));
        assign b1 =
            (y_pos[2:0] == 3'd0) ? ((x_scrambled == 2'd0) ? ( 4'd7) : (x_scrambled == 2'd1) ? ( 4'd0) : (-4'd7)) :
            (y_pos[2:0] == 3'd1) ? ((x_scrambled == 2'd0) ? ( 4'd0) : (x_scrambled == 2'd1) ? ( 4'd0) : (-4'd7)) :
                                   ((x_scrambled == 2'd0) ? ( 4'd7) : (x_scrambled == 2'd1) ? ( 4'd7) : (-4'd7));
        assign b2 =
            (y_pos[2:0] == 3'd0) ? ((x_scrambled == 2'd0) ? ( 4'd0) : (x_scrambled == 2'd1) ? (-4'd7) : ( 4'd7)) :
            (y_pos[2:0] == 3'd1) ? ((x_scrambled == 2'd0) ? ( 4'd0) : (x_scrambled == 2'd1) ? (-4'd7) : ( 4'd0)) :
                                   ((x_scrambled == 2'd0) ? ( 4'd7) : (x_scrambled == 2'd1) ? (-4'd7) : ( 4'd7));
        assign b3 =
            (y_pos[2:0] == 3'd0) ? ((x_scrambled == 2'd0) ? (-4'd7) : (x_scrambled == 2'd1) ? ( 4'd7) : ( 4'd0)) :
            (y_pos[2:0] == 3'd1) ? ((x_scrambled == 2'd0) ? (-4'd7) : (x_scrambled == 2'd1) ? ( 4'd0) : ( 4'd0)) :
                                   ((x_scrambled == 2'd0) ? (-4'd7) : (x_scrambled == 2'd1) ? ( 4'd7) : ( 4'd7));
    end
    else if (COLORMODE == "RGBW") begin: gen_rgbw_dither
        // OAK 3x3 Matrix with phase scrambling
        assign b0 =
            (y_pos[2:0] == 3'd0) ? ((x_scrambled == 2'd0) ? (-4'd7) : (x_scrambled == 2'd1) ? ( 4'd0) : (x_scrambled == 2'd2) ? ( 4'd3) : (-4'd4)) :
            (y_pos[2:0] == 3'd1) ? ((x_scrambled == 2'd0) ? ( 4'd5) : (x_scrambled == 2'd1) ? (-4'd6) : (x_scrambled == 2'd2) ? ( 4'd6) : ( 4'd2)) :
            (y_pos[2:0] == 3'd2) ? ((x_scrambled == 2'd0) ? ( 4'd7) : (x_scrambled == 2'd1) ? (-4'd5) : (x_scrambled == 2'd2) ? (-4'd3) : ( 4'd1)) :
                                   ((x_scrambled == 2'd0) ? (-4'd2) : (x_scrambled == 2'd1) ? ( 4'd4) : (x_scrambled == 2'd2) ? (-4'd8) : ( 4'd3));
        assign b1 =
            (y_pos[2:0] == 3'd0) ? ((x_scrambled == 2'd0) ? ( 4'd0) : (x_scrambled == 2'd1) ? ( 4'd3) : (x_scrambled == 2'd2) ? (-4'd7) : ( 4'd5)) :
            (y_pos[2:0] == 3'd1) ? ((x_scrambled == 2'd0) ? (-4'd6) : (x_scrambled == 2'd1) ? ( 4'd6) : (x_scrambled == 2'd2) ? ( 4'd5) : (-4'd3)) :
            (y_pos[2:0] == 3'd2) ? ((x_scrambled == 2'd0) ? (-4'd5) : (x_scrambled == 2'd1) ? (-4'd3) : (x_scrambled == 2'd2) ? ( 4'd7) : ( 4'd0)) :
                                   ((x_scrambled == 2'd0) ? ( 4'd4) : (x_scrambled == 2'd1) ? (-4'd8) : (x_scrambled == 2'd2) ? (-4'd2) : ( 4'd6));
        assign b2 =
            (y_pos[2:0] == 3'd0) ? ((x_scrambled == 2'd0) ? ( 4'd3) : (x_scrambled == 2'd1) ? (-4'd7) : (x_scrambled == 2'd2) ? ( 4'd0) : (-4'd5)) :
            (y_pos[2:0] == 3'd1) ? ((x_scrambled == 2'd0) ? ( 4'd6) : (x_scrambled == 2'd1) ? ( 4'd5) : (x_scrambled == 2'd2) ? (-4'd6) : ( 4'd2)) :
            (y_pos[2:0] == 3'd2) ? ((x_scrambled == 2'd0) ? (-4'd3) : (x_scrambled == 2'd1) ? ( 4'd7) : (x_scrambled == 2'd2) ? (-4'd5) : ( 4'd4)) :
                                   ((x_scrambled == 2'd0) ? (-4'd8) : (x_scrambled == 2'd1) ? (-4'd2) : (x_scrambled == 2'd2) ? ( 4'd4) : (-4'd1));
        assign b3 =
            (y_pos[2:0] == 3'd0) ? ((x_scrambled == 2'd0) ? (-4'd7) : (x_scrambled == 2'd1) ? ( 4'd0) : (x_scrambled == 2'd2) ? ( 4'd3) : ( 4'd6)) :
            (y_pos[2:0] == 3'd1) ? ((x_scrambled == 2'd0) ? ( 4'd5) : (x_scrambled == 2'd1) ? (-4'd6) : (x_scrambled == 2'd2) ? ( 4'd6) : (-4'd4)) :
            (y_pos[2:0] == 3'd2) ? ((x_scrambled == 2'd0) ? ( 4'd7) : (x_scrambled == 2'd1) ? (-4'd5) : (x_scrambled == 2'd2) ? (-4'd3) : ( 4'd1)) :
                                   ((x_scrambled == 2'd0) ? (-4'd2) : (x_scrambled == 2'd1) ? ( 4'd4) : (x_scrambled == 2'd2) ? (-4'd8) : ( 4'd2));
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
    // Edge Detection - Horizontal (compare with previous pixel group)
    // =========================================================================
    
    reg [31:0] prev_vin;
    always @(posedge clk) begin
        prev_vin <= vin;
    end
    
    // Binary representation: is pixel > 128?
    wire [3:0] curr_binary = {pix0[7], pix1[7], pix2[7], pix3[7]};
    wire [3:0] prev_binary = {prev_vin[31], prev_vin[23], prev_vin[15], prev_vin[7]};
    
    // Horizontal edge: compare current pixel 0 with previous pixel 3
    // and detect transitions within current group
    wire h_edge_0 = (curr_binary[3] != prev_binary[0]);  // pix0 vs prev_pix3
    wire h_edge_1 = (curr_binary[2] != curr_binary[3]);  // pix1 vs pix0
    wire h_edge_2 = (curr_binary[1] != curr_binary[2]);  // pix2 vs pix1
    wire h_edge_3 = (curr_binary[0] != curr_binary[1]);  // pix3 vs pix2

    // =========================================================================
    // Edge Detection - Vertical (compare with previous line)
    // Uses binary line buffer (1 bit per pixel)
    // =========================================================================
    
    // Line buffer: stores 1-bit per pixel (is_white) for previous line
    // For 4 pixels per clock, we store 4 bits per address
    // Using distributed RAM for combinational read (no latency)
    localparam LINE_BUF_DEPTH = (LINE_WIDTH + 3) / 4;  // Round up
    localparam LINE_BUF_AW = clog2(LINE_BUF_DEPTH);
    
    (* ram_style = "distributed" *)
    reg [3:0] line_buffer [0:LINE_BUF_DEPTH-1];
    
    wire [LINE_BUF_AW-1:0] line_buf_addr = x_cnt[10:2];  // Divide by 4
    
    // Combinational read from line buffer (distributed RAM)
    wire [3:0] prev_line_binary = line_buffer[line_buf_addr];
    
    // Write current line to buffer (registered)
    always @(posedge clk) begin
        line_buffer[line_buf_addr] <= curr_binary;
    end
    
    // Vertical edge detection (combinational, no delay needed with distributed RAM)
    wire v_edge_0 = (curr_binary[3] != prev_line_binary[3]);
    wire v_edge_1 = (curr_binary[2] != prev_line_binary[2]);
    wire v_edge_2 = (curr_binary[1] != prev_line_binary[1]);
    wire v_edge_3 = (curr_binary[0] != prev_line_binary[0]);

    // =========================================================================
    // Combined Edge Detection (all combinational)
    // =========================================================================
    
    // Edge detected if horizontal OR vertical edge
    wire is_edge_0 = h_edge_0 || v_edge_0;
    wire is_edge_1 = h_edge_1 || v_edge_1;
    wire is_edge_2 = h_edge_2 || v_edge_2;
    wire is_edge_3 = h_edge_3 || v_edge_3;

    // =========================================================================
    // Output MUX: Select dithered or simple based on edge
    // =========================================================================
    
    wire [3:0] final_out;
    assign final_out[3] = is_edge_0 ? simple_out[3] : bayer_out[3];
    assign final_out[2] = is_edge_1 ? simple_out[2] : bayer_out[2];
    assign final_out[1] = is_edge_2 ? simple_out[1] : bayer_out[1];
    assign final_out[0] = is_edge_3 ? simple_out[0] : bayer_out[0];

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
