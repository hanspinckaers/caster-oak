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
// degamma.v
// Hybrid gamma curve for e-ink display:
// - Shadows/mids: gamma ~1.5 for brightness
// - Highlights: steeper curve for better differentiation
//
`default_nettype none
`timescale 1ns / 1ps
module degamma(
    input wire [5:0] in,
    output reg [7:0] out
);

    // Hybrid curve: dark shadows (1.8), bright mids (1.5), reserved highlights
    // Highlights stay gray longer - only true white at max input
    always @(in) begin
        case (in)
        // Shadows: gamma 1.8 (keep dark for contrast)
        6'd0: out = 8'd0;
        6'd1: out = 8'd0;
        6'd2: out = 8'd1;
        6'd3: out = 8'd2;
        6'd4: out = 8'd3;
        6'd5: out = 8'd5;
        6'd6: out = 8'd6;
        6'd7: out = 8'd8;
        6'd8: out = 8'd10;
        6'd9: out = 8'd13;
        6'd10: out = 8'd15;
        6'd11: out = 8'd18;
        6'd12: out = 8'd21;
        6'd13: out = 8'd24;
        6'd14: out = 8'd28;
        6'd15: out = 8'd31;
        // Mids: gamma ~1.5 (brighter, +0.33 from 1.8)
        6'd16: out = 8'd35;
        6'd17: out = 8'd40;
        6'd18: out = 8'd45;
        6'd19: out = 8'd50;
        6'd20: out = 8'd55;
        6'd21: out = 8'd60;
        6'd22: out = 8'd65;
        6'd23: out = 8'd70;
        6'd24: out = 8'd75;
        6'd25: out = 8'd80;
        6'd26: out = 8'd85;
        6'd27: out = 8'd90;
        6'd28: out = 8'd95;
        6'd29: out = 8'd100;
        6'd30: out = 8'd105;
        6'd31: out = 8'd110;
        6'd32: out = 8'd115;
        6'd33: out = 8'd120;
        6'd34: out = 8'd125;
        6'd35: out = 8'd130;
        6'd36: out = 8'd135;
        6'd37: out = 8'd140;
        6'd38: out = 8'd145;
        6'd39: out = 8'd150;
        // Upper mids: continue linear-ish
        6'd40: out = 8'd155;
        6'd41: out = 8'd160;
        6'd42: out = 8'd165;
        6'd43: out = 8'd170;
        6'd44: out = 8'd175;
        6'd45: out = 8'd180;
        6'd46: out = 8'd185;
        6'd47: out = 8'd190;
        // Highlights: spread 48-61, only 62-63 compressed to white
        6'd48: out = 8'd194;
        6'd49: out = 8'd198;
        6'd50: out = 8'd202;
        6'd51: out = 8'd206;
        6'd52: out = 8'd210;
        6'd53: out = 8'd214;
        6'd54: out = 8'd218;
        6'd55: out = 8'd222;
        6'd56: out = 8'd226;
        6'd57: out = 8'd230;
        6'd58: out = 8'd234;
        6'd59: out = 8'd238;
        6'd60: out = 8'd242;
        6'd61: out = 8'd246;
        6'd62: out = 8'd254;  // compress to white
        6'd63: out = 8'd255;
        endcase
    end

endmodule
`default_nettype wire
