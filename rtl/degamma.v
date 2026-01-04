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
// Shadow boost degamma for FAST_GREY 4-level quantization
// Mathematically derived piecewise power curve:
//   Shadows (0-14): γ=0.45 - strong lift to cross 64 threshold earlier
//   Mids (15-44):   γ=0.85 - moderate curve for smooth transitions
//   Highlights (45-63): γ=1.1 - gentle compression to avoid blowout
// Crosses Dark Gray (64) at input 12 vs 19 before = 7 more visible shadow levels
//
`default_nettype none
`timescale 1ns / 1ps
module degamma(
    input wire [5:0] in,
    output reg [7:0] out
);

    // Piecewise power curve optimized for 4-level FAST_GREY quantization
    // Thresholds: 64 (Dark Gray), 128 (Light Gray), 192 (White)
    always @(in) begin
        case (in)
        // True black stays black
        6'd0: out = 8'd0;
        // Shadows: γ=0.45 power curve, targets output 70 at input 14
        6'd1: out = 8'd21;
        6'd2: out = 8'd29;
        6'd3: out = 8'd34;
        6'd4: out = 8'd39;
        6'd5: out = 8'd44;
        6'd6: out = 8'd47;
        6'd7: out = 8'd51;
        6'd8: out = 8'd54;
        6'd9: out = 8'd57;
        6'd10: out = 8'd60;
        6'd11: out = 8'd62;
        6'd12: out = 8'd65;   // Crosses 64 threshold → Dark Gray
        6'd13: out = 8'd67;
        6'd14: out = 8'd70;
        // Mids: γ=0.85 power curve from 70 to 180
        6'd15: out = 8'd76;
        6'd16: out = 8'd81;
        6'd17: out = 8'd85;
        6'd18: out = 8'd89;
        6'd19: out = 8'd93;
        6'd20: out = 8'd98;
        6'd21: out = 8'd101;
        6'd22: out = 8'd105;
        6'd23: out = 8'd109;
        6'd24: out = 8'd113;
        6'd25: out = 8'd116;
        6'd26: out = 8'd120;
        6'd27: out = 8'd124;
        6'd28: out = 8'd127;
        6'd29: out = 8'd131;   // Crosses 128 threshold → Light Gray
        6'd30: out = 8'd134;
        6'd31: out = 8'd137;
        6'd32: out = 8'd141;
        6'd33: out = 8'd144;
        6'd34: out = 8'd147;
        6'd35: out = 8'd151;
        6'd36: out = 8'd154;
        6'd37: out = 8'd157;
        6'd38: out = 8'd160;
        6'd39: out = 8'd164;
        6'd40: out = 8'd167;
        6'd41: out = 8'd170;
        6'd42: out = 8'd173;
        6'd43: out = 8'd176;
        6'd44: out = 8'd180;
        // Highlights: γ=1.1 gentle compression from 180 to 255
        6'd45: out = 8'd182;
        6'd46: out = 8'd186;
        6'd47: out = 8'd189;
        6'd48: out = 8'd193;   // Crosses 192 threshold → White
        6'd49: out = 8'd197;
        6'd50: out = 8'd201;
        6'd51: out = 8'd205;
        6'd52: out = 8'd208;
        6'd53: out = 8'd212;
        6'd54: out = 8'd217;
        6'd55: out = 8'd221;
        6'd56: out = 8'd225;
        6'd57: out = 8'd229;
        6'd58: out = 8'd233;
        6'd59: out = 8'd237;
        6'd60: out = 8'd242;
        6'd61: out = 8'd246;
        6'd62: out = 8'd250;
        6'd63: out = 8'd255;
        endcase
    end

endmodule
`default_nettype wire
