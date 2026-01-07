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

    // +33% gamma: darker shadows, preserved mids/highlights
    always @(in) begin
        case (in)
        // Shadows: darker for more contrast
        6'd0: out = 8'd0;
        6'd1: out = 8'd0;
        6'd2: out = 8'd0;
        6'd3: out = 8'd2;
        6'd4: out = 8'd3;
        6'd5: out = 8'd5;
        6'd6: out = 8'd7;
        6'd7: out = 8'd10;
        6'd8: out = 8'd13;
        6'd9: out = 8'd16;
        6'd10: out = 8'd20;
        6'd11: out = 8'd24;
        6'd12: out = 8'd28;
        6'd13: out = 8'd33;
        6'd14: out = 8'd38;
        6'd15: out = 8'd44;
        // Lower mids: -10% darker
        6'd16: out = 8'd45;
        6'd17: out = 8'd50;
        6'd18: out = 8'd56;
        6'd19: out = 8'd61;
        6'd20: out = 8'd67;
        6'd21: out = 8'd72;
        6'd22: out = 8'd78;
        6'd23: out = 8'd83;
        6'd24: out = 8'd89;
        6'd25: out = 8'd94;
        6'd26: out = 8'd100;
        6'd27: out = 8'd105;
        6'd28: out = 8'd111;
        6'd29: out = 8'd116;
        6'd30: out = 8'd122;
        6'd31: out = 8'd127;
        // Upper mids: -10% darker
        6'd32: out = 8'd132;
        6'd33: out = 8'd137;
        6'd34: out = 8'd142;
        6'd35: out = 8'd147;
        6'd36: out = 8'd152;
        6'd37: out = 8'd156;
        6'd38: out = 8'd160;
        6'd39: out = 8'd164;
        6'd40: out = 8'd168;
        6'd41: out = 8'd172;
        6'd42: out = 8'd176;
        6'd43: out = 8'd180;
        6'd44: out = 8'd184;
        6'd45: out = 8'd188;
        6'd46: out = 8'd192;
        6'd47: out = 8'd196;
        // Highlights: adjusted to match, spread to 246
        6'd48: out = 8'd200;
        6'd49: out = 8'd203;
        6'd50: out = 8'd206;
        6'd51: out = 8'd209;
        6'd52: out = 8'd212;
        6'd53: out = 8'd215;
        6'd54: out = 8'd218;
        6'd55: out = 8'd221;
        6'd56: out = 8'd224;
        6'd57: out = 8'd228;
        6'd58: out = 8'd232;
        6'd59: out = 8'd236;
        6'd60: out = 8'd239;
        6'd61: out = 8'd242;
        6'd62: out = 8'd246;  // 8-bit 251 = still gray
        6'd63: out = 8'd255;  // only true white
        endcase
    end

endmodule
`default_nettype wire
