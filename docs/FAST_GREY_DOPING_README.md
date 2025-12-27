# FAST_GREY Global Doping and Overdrive Compensation

## Overview

FAST_GREY mode now includes global doping pulses to prevent ghosting, with per-pixel DC bias tracking and dynamic overdrive compensation. This maintains image quality while keeping the display responsive.

## Problem Solved

E-ink displays accumulate charge over time when pixels stay at the same value. This causes:
- Ghosting (faint remnants of previous images)
- Reduced contrast over time
- Uneven gray levels

## Solution: Global Doping with Overdrive Compensation

### Global Doping Pulses

Every ~1 second, idle pixels receive doping pulses:
- **B/W pixels**: 1 frame pulse (Black→drive black, White→drive white)
- **Gray pixels**: 4-frame balanced sequence (2 extreme + 2 reverse)

Gray pixels (DG, LG) are DC-balanced: extreme then reverse cancels out.
B/W pixels accumulate +1 dc_bias per pulse.

Doping stops when dc_bias reaches maximum (3). No further pulses until bias is reset by overdrive.

### DC Bias Tracking

Each pixel tracks accumulated bias in 2 bits (0-3 levels):
- B/W pixels: +1 per doping pulse (stops at 3)
- Gray pixels: 0 (balanced doping, no accumulation)
- Reset to 0 when overdrive is applied (direction switch)

### Dynamic Overdrive

When a pixel switches direction (B→W or W→B), the accumulated dc_bias determines extra drive frames:

| dc_bias | Overdrive | Description |
|---------|-----------|-------------|
| 0 | 0 frames | No compensation needed |
| 1 | 1 frame | Weak bias compensation |
| 2 | 2 frames | Medium bias compensation |
| 3 | 3 frames | Strong bias compensation |

### Timing Balance

Total transition time stays constant at 13 frames. Overdrive borrows from rest/settle:

**B/W Path (MONO + REST):**
| dc_bias | MONO | REST | Total |
|---------|------|------|-------|
| 0 | 6 | 7 | 13 |
| 1 | 7 | 6 | 13 |
| 2 | 8 | 5 | 13 |
| 3 | 9 | 4 | 13 |

**Gray Path (MONO + REVERSE + SETTLE):**
| dc_bias | MONO | REVERSE | SETTLE | Total |
|---------|------|---------|--------|-------|
| 0 | 6 | 2 | 5 | 13 |
| 1 | 7 | 2 | 4 | 13 |
| 2 | 8 | 2 | 3 | 13 |
| 3 | 9 | 2 | 2 | 13 |

REVERSE is fixed at 2 frames (determines gray level).

## Doping Eligibility

Pixels only participate in doping when **truly idle**:
- `fg_counter == 0` (no video mode cooldown)
- `fg_frames == 0` (no transition in progress)

This provides ~1 second immunity after any transition before doping can affect the pixel. Pixels in cooldown output NO_DRIVE during doping sequences.

## Implementation

### State Storage (16-bit, unchanged)

```
[15:12] - Mode (1011 = FAST_GREY)
[11:10] - Stage (DONE=0, MONO=1, HOLD=2, GREY=3)
[9:4]   - Frame counter: [5:4]=fg_counter, [3:0]=fg_frames
[3:2]   - dc_bias (in HOLD/GREY/DONE) or mindrv (in MONO)
[1:0]   - Target level (00=B, 01=DG, 10=LG, 11=W)
```

### Key Constants (defines.vh)

```verilog
// FAST_GREY timing (13 frames total)
`define FASTG_MONO_FRAMES       4'd6    // Base MONO duration
`define FASTG_BW_REST_FRAMES    4'd7    // REST for B/W after MONO
`define FASTG_REVERSE_FRAMES    4'd2    // REVERSE for gray
`define FASTG_SETTLE_FRAMES     4'd5    // SETTLE for gray after reverse
`define FASTG_VIDEO_COOLDOWN    4'd13   // Cooldown for doping immunity

// Global doping schedule
`define DOPING_EXTREME_FRAMES   2'd2    // Frames in extreme phase
`define DOPING_REVERSE_FRAMES   2'd2    // Frames in reverse phase
`define DOPING_WAIT_FRAMES      6'd25   // ~1 sec between cycles

// DC bias
`define DC_BIAS_MAX             2'd3
`define OVERDRIVE_MAX           2'd3
```

### Signal Flow

1. `caster.v` manages global doping timer
2. `doping_active` and `doping_phase` signals broadcast to all pixels
3. Each `pixel_processing` instance responds based on pixel state
4. Only truly idle pixels participate; others output NO_DRIVE

## Benefits

- **No ghosting**: Regular doping pulses prevent charge accumulation
- **No timing penalty**: 13-frame total maintained via overdrive/rest tradeoff
- **Minimal complexity**: 2-bit dc_bias fits in existing state
- **Graceful degradation**: Max 3-frame overdrive still leaves 4-frame rest (B/W) or 2-frame settle (gray)
