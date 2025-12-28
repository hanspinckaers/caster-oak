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

Every ~1 second, idle B/W pixels receive doping pulses:
- **B/W pixels**: 1 frame pulse (Black→drive black, White→drive white)
- **Gray pixels**: No doping (removed - too visually distracting)

B/W pixels accumulate +1 dc_bias per pulse.

### Doping Limits

Doping stops after 5 cycles per idle period:
- **B/W pixels**: Limited by `doping_count` (0-5, 3-bit), increments each cycle
- **B/W pixels**: Also limited by `dc_bias` (stops if dc_bias=3)
- **Gray pixels**: No doping at all

### DC Bias Tracking and Decay

Each pixel tracks accumulated bias in 2 bits (0-3 levels):
- B/W pixels: +1 per doping pulse
- Gray pixels: No change (no doping)
- Reset to 0 when overdrive is applied (direction switch)

**Decay**: After doping completes (`doping_count=5`), dc_bias decays by 1 per doping cycle until it reaches 0.

### Idle Pixel Timeline (B/W)

| Time | Action | dc_bias | doping_count |
|------|--------|---------|--------------|
| 0-1s | Cooldown | 0 | - |
| 1-2s | Doping pulse 1 | 1 | 1 |
| 2-3s | Doping pulse 2 | 2 | 2 |
| 3-4s | Doping pulse 3 | 3 | 3 |
| 4-5s | Doping pulse 4 (dc_bias capped) | 3 | 4 |
| 5-6s | Doping pulse 5 (dc_bias capped) | 3 | 5 |
| 6-7s | Decay | 2 | 5 |
| 7-8s | Decay | 1 | 5 |
| 8-9s | Decay | 0 | 5 |
| 9s+ | Stable | 0 | 5 |

### Overdrive Based on Transition Timing

| Transition Time | dc_bias | Overdrive |
|-----------------|---------|-----------|
| ~2s after idle | 1 | 1 frame |
| ~3s after idle | 2 | 2 frames |
| ~4-6s after idle (peak) | 3 | 3 frames |
| ~7s after idle | 2 | 2 frames |
| ~8s after idle | 1 | 1 frame |
| 9s+ after idle | 0 | 0 frames |

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

## Doping Mode and Eligibility

### Entering Doping Mode

Pixels enter doping mode when **truly idle** and doping starts:
- `fg_counter == 0` (cooldown complete)
- `fg_frames == 0` (no transition in progress)

On entering doping mode, `fg_frames` is set to 15 (marker), and `fg_counter` becomes `doping_count`.

### Doping Mode State

- `fg_frames[3:1] = 111` (fg_frames = 14 or 15): Doping mode active
- `doping_count` (3-bit): `{fg_counter[1:0], fg_frames[0]}` tracks pulses (0-5)
- Exits on any color change (returns to cooldown)

### Cooldown

After any transition, ~1 second cooldown (`FASTG_VIDEO_COOLDOWN=13` frames) before doping eligibility. Pixels in cooldown output NO_DRIVE during doping sequences.

## Implementation

### State Storage (16-bit, unchanged)

```
[15:12] - Mode (1011 = FAST_GREY)
[11:10] - Stage (DONE=0, MONO=1, HOLD=2, GREY=3)
[9:4]   - Frame counter:
          - Cooldown mode: [5:4]=fg_counter (video), [3:0]=fg_frames (0-13)
          - Doping mode: [5:4]=doping_count[2:1], [3:1]=111 (marker), [0]=doping_count[0]
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

1. `caster.v` manages global doping timer, generates:
   - `doping_active`: Doping sequence in progress
   - `doping_phase`: 0=extreme, 1=reverse
   - `doping_first_frame`: First frame of doping sequence
2. Each `pixel_processing` instance responds based on pixel state
3. Only doping-eligible pixels participate; others output NO_DRIVE

## Benefits

- **No ghosting**: Regular doping pulses prevent charge accumulation on B/W pixels
- **Dynamic overdrive**: Compensates based on actual doping received
- **Overdrive decay**: Long-idle pixels return to zero overdrive
- **No timing penalty**: 13-frame total maintained via overdrive/rest tradeoff
- **Minimal complexity**: 2-bit dc_bias and 3-bit doping_count fit in existing state
- **No gray flicker**: Gray pixels excluded from doping for visual stability
