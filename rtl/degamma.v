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

    // +25% gamma boost: brighter shadows/mids, tapered highlights
    // Values scaled by ~1.25, with soft rolloff at top to preserve highlight detail
    always @(in) begin
        case (in)
        // Shadows: boosted by 1.25x
        6'd0: out = 8'd0;
        6'd1: out = 8'd0;
        6'd2: out = 8'd1;
        6'd3: out = 8'd3;
        6'd4: out = 8'd4;
        6'd5: out = 8'd6;
        6'd6: out = 8'd8;
        6'd7: out = 8'd10;
        6'd8: out = 8'd12;
        6'd9: out = 8'd16;
        6'd10: out = 8'd19;
        6'd11: out = 8'd22;
        6'd12: out = 8'd26;
        6'd13: out = 8'd30;
        6'd14: out = 8'd35;
        6'd15: out = 8'd39;
        // Mids: boosted by 1.25x
        6'd16: out = 8'd44;
        6'd17: out = 8'd50;
        6'd18: out = 8'd56;
        6'd19: out = 8'd62;
        6'd20: out = 8'd69;
        6'd21: out = 8'd75;
        6'd22: out = 8'd81;
        6'd23: out = 8'd88;
        6'd24: out = 8'd94;
        6'd25: out = 8'd100;
        6'd26: out = 8'd106;
        6'd27: out = 8'd112;
        6'd28: out = 8'd119;
        6'd29: out = 8'd125;
        6'd30: out = 8'd131;
        6'd31: out = 8'd138;
        6'd32: out = 8'd144;
        6'd33: out = 8'd150;
        6'd34: out = 8'd156;
        6'd35: out = 8'd162;
        6'd36: out = 8'd169;
        6'd37: out = 8'd175;
        6'd38: out = 8'd181;
        6'd39: out = 8'd188;
        // Upper mids: tapered boost (1.2x to 1.1x)
        6'd40: out = 8'd193;
        6'd41: out = 8'd198;
        6'd42: out = 8'd203;
        6'd43: out = 8'd208;
        6'd44: out = 8'd213;
        6'd45: out = 8'd218;
        6'd46: out = 8'd222;
        6'd47: out = 8'd226;
        // Highlights: gentle rolloff to preserve detail
        6'd48: out = 8'd230;
        6'd49: out = 8'd233;
        6'd50: out = 8'd236;
        6'd51: out = 8'd239;
        6'd52: out = 8'd241;
        6'd53: out = 8'd243;
        6'd54: out = 8'd245;
        6'd55: out = 8'd247;
        6'd56: out = 8'd248;
        6'd57: out = 8'd249;
        6'd58: out = 8'd250;
        6'd59: out = 8'd251;
        6'd60: out = 8'd252;
        6'd61: out = 8'd253;
        6'd62: out = 8'd254;
        6'd63: out = 8'd255;
        endcase
    end

endmodule
`default_nettype wire
