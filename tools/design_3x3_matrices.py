#!/usr/bin/env python3
"""Design and compare dither matrices for RGBW CFA - 3x3, 8x8, halved variants."""

import numpy as np
from itertools import permutations
from PIL import Image, ImageDraw, ImageFont

# Values that sum to 0 with good range (for 3x3)
VALUES = [-7, -6, -5, -3, 0, +3, +5, +6, +7]

# Standard 8x8 Bayer matrix (values 0-63, we'll center to -31.5 to +31.5)
BAYER_8x8_RAW = np.array([
    [ 0, 32,  8, 40,  2, 34, 10, 42],
    [48, 16, 56, 24, 50, 18, 58, 26],
    [12, 44,  4, 36, 14, 46,  6, 38],
    [60, 28, 52, 20, 62, 30, 54, 22],
    [ 3, 35, 11, 43,  1, 33,  9, 41],
    [51, 19, 59, 27, 49, 17, 57, 25],
    [15, 47,  7, 39, 13, 45,  5, 37],
    [63, 31, 55, 23, 61, 29, 53, 21]
], dtype=np.float32)

# Center 8x8 to have sum=0 (subtract 31.5)
MATRIX_8x8 = BAYER_8x8_RAW - 31.5  # Range: -31.5 to +31.5

# Scale 8x8 to similar range as 3x3 (±7 vs ±31.5)
# For fair comparison, we can scale or just use raw values
MATRIX_8x8_SCALED = MATRIX_8x8 * (7.0 / 31.5)  # Scale to ±7 range

# CFA-balanced 8x8: each CFA color sees values that sum to 0
# Strategy: assign 16 balanced values to each CFA color position
# 16 values that sum to 0: -7.5, -6.5, -5.5, -4.5, -3.5, -2.5, -1.5, -0.5,
#                          +0.5, +1.5, +2.5, +3.5, +4.5, +5.5, +6.5, +7.5
def create_cfa_balanced_8x8():
    """Create 8x8 matrix where each CFA color sees balanced dither values."""
    # 16 values summing to 0, good spread
    vals = np.array([-7.5, -6.5, -5.5, -4.5, -3.5, -2.5, -1.5, -0.5,
                     +0.5, +1.5, +2.5, +3.5, +4.5, +5.5, +6.5, +7.5])

    # CFA positions in 8x8:
    # B: even row, even col
    # W: even row, odd col
    # G: odd row, even col
    # R: odd row, odd col

    matrix = np.zeros((8, 8), dtype=np.float32)

    # Assign values to maximize local dispersion
    # Use different permutations for each CFA color
    # Bayer-like ordering for good spatial distribution
    bayer_order_4x4 = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]

    b_positions = [(y, x) for y in range(8) for x in range(8) if y % 2 == 0 and x % 2 == 0]
    w_positions = [(y, x) for y in range(8) for x in range(8) if y % 2 == 0 and x % 2 == 1]
    g_positions = [(y, x) for y in range(8) for x in range(8) if y % 2 == 1 and x % 2 == 0]
    r_positions = [(y, x) for y in range(8) for x in range(8) if y % 2 == 1 and x % 2 == 1]

    # Assign with Bayer-like ordering for each CFA
    for i, (y, x) in enumerate(b_positions):
        matrix[y, x] = vals[bayer_order_4x4[i]]
    for i, (y, x) in enumerate(w_positions):
        matrix[y, x] = vals[bayer_order_4x4[(i + 4) % 16]]  # Offset for variation
    for i, (y, x) in enumerate(g_positions):
        matrix[y, x] = vals[bayer_order_4x4[(i + 8) % 16]]
    for i, (y, x) in enumerate(r_positions):
        matrix[y, x] = vals[bayer_order_4x4[(i + 12) % 16]]

    return matrix

MATRIX_8x8_CFA = create_cfa_balanced_8x8()

# Verify CFA balance
def verify_8x8_cfa_balance(matrix):
    """Check that each CFA color sums to 0 in 8x8 tile."""
    sums = {'B': 0, 'W': 0, 'G': 0, 'R': 0}
    for y in range(8):
        for x in range(8):
            if y % 2 == 0 and x % 2 == 0:
                sums['B'] += matrix[y, x]
            elif y % 2 == 0 and x % 2 == 1:
                sums['W'] += matrix[y, x]
            elif y % 2 == 1 and x % 2 == 0:
                sums['G'] += matrix[y, x]
            else:
                sums['R'] += matrix[y, x]
    return sums

print("8x8 CFA-balanced matrix sums:", verify_8x8_cfa_balance(MATRIX_8x8_CFA))

def measure_dispersion(matrix):
    """Sum of absolute differences between adjacent pixels (higher = better)."""
    h, w = matrix.shape
    total = 0
    for y in range(h):
        for x in range(w):
            # Right neighbor
            if x < w - 1:
                total += abs(matrix[y, x] - matrix[y, x+1])
            # Bottom neighbor
            if y < h - 1:
                total += abs(matrix[y, x] - matrix[y+1, x])
            # Diagonal neighbors
            if x < w - 1 and y < h - 1:
                total += abs(matrix[y, x] - matrix[y+1, x+1])
            if x > 0 and y < h - 1:
                total += abs(matrix[y, x] - matrix[y+1, x-1])
    # Normalize by matrix size for fair comparison
    return total / (h * w)

def measure_diagonal_gradient(matrix):
    """Measure how much values increase along main diagonal direction."""
    # For each anti-diagonal (constant x+y), measure variance
    # Lower variance = more diagonal consistency
    score = 0
    for diag_sum in range(5):  # x+y can be 0,1,2,3,4
        vals = []
        for y in range(3):
            for x in range(3):
                if x + y == diag_sum:
                    vals.append(matrix[y, x])
        if len(vals) > 1:
            score += np.std(vals)
    return -score  # Negative because lower variance is better

# Hand-designed matrices

# Original optimal (max dispersion = 144)
MATRIX_OPTIMAL = np.array([
    [-7, -3, +5],
    [ 0, +6, -6],
    [+7, -5, +3]
], dtype=np.float32)

# Diagonal gradient: values increase along main diagonal direction
MATRIX_DIAG_GRAD = np.array([
    [-7, -5, -3],
    [-6,  0, +5],
    [ +3, +6, +7]
], dtype=np.float32)

# Anti-diagonal gradient
MATRIX_ANTIDIAG = np.array([
    [+7, +5, -7],
    [+6,  0, -6],
    [+3, -3, -5]
], dtype=np.float32)

# Checkerboard: alternating +/-
MATRIX_CHECKER = np.array([
    [-7, +6, -5],
    [+7,  0, -6],
    [-3, +5, +3]
], dtype=np.float32)

# Center-out: low in center, high at edges
MATRIX_CENTER = np.array([
    [+7, -5, +6],
    [-6,  0, +5],
    [+3, -7, -3]
], dtype=np.float32)

# Spiral pattern
MATRIX_SPIRAL = np.array([
    [-7, -6, -5],
    [+3,  0, -3],
    [+5, +6, +7]
], dtype=np.float32)

# Horizontal bands (for comparison)
MATRIX_HBANDS = np.array([
    [-7, -6, -5],
    [ 0, +3, -3],
    [+7, +6, +5]
], dtype=np.float32)

# Diamond pattern
MATRIX_DIAMOND = np.array([
    [ 0, -7, +3],
    [-6, +7, -5],
    [+5, -3, +6]
], dtype=np.float32)

# Try to maximize diagonal appearance: same values on anti-diagonals
# Anti-diag sums: (0,0), (0,1)+(1,0), (0,2)+(1,1)+(2,0), (1,2)+(2,1), (2,2)
# We need sum=0, so we need to distribute carefully
MATRIX_ANTIDIAG_SAME = np.array([
    [-7, -3, +6],
    [-3, +6, +5],
    [+6, +5, -6]  # Doesn't sum to 0, need to fix
], dtype=np.float32)

# Let me design one that has diagonal bands
# Band 0 (x+y=0): one value
# Band 1 (x+y=1): two values, should be similar
# Band 2 (x+y=2): three values, should be similar
# Band 3 (x+y=3): two values, should be similar
# Band 4 (x+y=4): one value
# Total sum = 0

# Try: -7 | -6,-5 | -3,0,+3 | +5,+6 | +7
MATRIX_BAND_DIAG = np.array([
    [-7, -6, -3],
    [-5,  0, +5],
    [+3, +6, +7]
], dtype=np.float32)

# Verify sum
print("Checking sums:")
matrices = {
    "Optimal (original)": MATRIX_OPTIMAL,
    "Diagonal gradient": MATRIX_DIAG_GRAD,
    "Anti-diagonal": MATRIX_ANTIDIAG,
    "Checkerboard": MATRIX_CHECKER,
    "Center-out": MATRIX_CENTER,
    "Spiral": MATRIX_SPIRAL,
    "H-bands": MATRIX_HBANDS,
    "Diamond": MATRIX_DIAMOND,
    "Band diagonal": MATRIX_BAND_DIAG,
}

def get_cfa(y, x):
    row = y % 2
    col = x % 2
    if row == 0:
        return 0 if col == 0 else 1  # B, W
    else:
        return 2 if col == 0 else 3  # G, R

# Diagonal phase lookup functions - work with any matrix size
def make_standard_lookup(matrix):
    """Standard lookup: matrix[y%h, x%w]"""
    h, w = matrix.shape
    def lookup(y, x):
        return matrix[y % h, x % w]
    return lookup

def make_diagonal_lookup(matrix):
    """Diagonal shift: matrix[y%h, (x+y)%w]"""
    h, w = matrix.shape
    def lookup(y, x):
        return matrix[y % h, (x + y) % w]
    return lookup

def make_antidiag_lookup(matrix):
    """Anti-diagonal shift: matrix[y%h, (x-y)%w]"""
    h, w = matrix.shape
    def lookup(y, x):
        return matrix[y % h, (x - y) % w]
    return lookup

def check_cfa_balance(matrix, tile_size=6):
    """Check DC balance per CFA color."""
    cfa_sums = {0: 0, 1: 0, 2: 0, 3: 0}
    for y in range(tile_size):
        for x in range(tile_size):
            cfa = get_cfa(y, x)
            val = matrix[y % 3, x % 3]
            cfa_sums[cfa] += val
    return all(abs(s) < 0.01 for s in cfa_sums.values())

def apply_dither_hpi(img, matrix, bias=12, lookup_func=None, halved=True):
    """Apply dithering with HPI quantization."""
    h, w = img.shape
    output = np.zeros_like(img, dtype=np.uint8)

    if lookup_func is None:
        lookup_func = make_standard_lookup(matrix)

    scale = 0.5 if halved else 1.0

    for y in range(h):
        for x in range(w):
            pix = int(img[y, x])
            dither = lookup_func(y, x) * scale

            result = pix + bias + dither * 16
            result = max(0, min(255, result))

            if result >= 192:
                level = 3
            elif result >= 128:
                level = 2
            elif result >= 64:
                level = 1
            else:
                level = 0

            output[y, x] = level * 85

    return output

# CFA luminance weights (how much each filter contributes to perceived brightness)
# Based on typical RGBW response - W is brightest, B is dimmest
CFA_LUM = {
    0: 0.11,   # Blue - darkest filter
    1: 1.0,    # White - no filter, full brightness
    2: 0.59,   # Green - medium, eye most sensitive
    3: 0.30,   # Red - darker filter
}

def apply_dither_hpi_cfa(img, matrix, bias=12, lookup_func=None, halved=True):
    """Apply dithering with HPI quantization and CFA simulation."""
    h, w = img.shape
    # Output as RGB to show CFA effect
    output_rgb = np.zeros((h, w, 3), dtype=np.uint8)
    output_perceived = np.zeros((h, w), dtype=np.float32)

    if lookup_func is None:
        lookup_func = make_standard_lookup(matrix)

    scale = 0.5 if halved else 1.0

    for y in range(h):
        for x in range(w):
            pix = int(img[y, x])
            dither = lookup_func(y, x) * scale

            result = pix + bias + dither * 16
            result = max(0, min(255, result))

            if result >= 192:
                level = 3
            elif result >= 128:
                level = 2
            elif result >= 64:
                level = 1
            else:
                level = 0

            cfa = get_cfa(y, x)
            out_val = level * 85

            # Set RGB based on CFA color (tinted for visualization)
            if cfa == 0:  # Blue
                output_rgb[y, x] = [int(out_val * 0.3), int(out_val * 0.3), out_val]
            elif cfa == 1:  # White
                output_rgb[y, x] = [out_val, out_val, out_val]
            elif cfa == 2:  # Green
                output_rgb[y, x] = [int(out_val * 0.3), out_val, int(out_val * 0.3)]
            else:  # Red
                output_rgb[y, x] = [out_val, int(out_val * 0.3), int(out_val * 0.3)]

            # Perceived brightness through CFA filter
            output_perceived[y, x] = out_val * CFA_LUM[cfa]

    return output_rgb, output_perceived

def simulate_perceived(output_rgb, kernel_size=4):
    """Simulate perceived brightness by blurring RGB then converting to luminance."""
    from scipy.ndimage import uniform_filter

    # Blur each RGB channel (eye's spatial integration)
    r_blur = uniform_filter(output_rgb[:, :, 0].astype(np.float32), size=kernel_size)
    g_blur = uniform_filter(output_rgb[:, :, 1].astype(np.float32), size=kernel_size)
    b_blur = uniform_filter(output_rgb[:, :, 2].astype(np.float32), size=kernel_size)

    # Convert blurred RGB to perceived luminance (standard weights)
    # Y = 0.299*R + 0.587*G + 0.114*B
    luminance = 0.299 * r_blur + 0.587 * g_blur + 0.114 * b_blur

    return np.clip(luminance, 0, 255).astype(np.uint8)

def create_gradient(width, height):
    """Create horizontal gradient."""
    gradient = np.zeros((height, width), dtype=np.uint8)
    for x in range(width):
        val = int(x * 255 / (width - 1))
        gradient[:, x] = val
    return gradient

def measure_perceived_levels(output, window=8):
    """Count unique perceived brightness levels."""
    h, w = output.shape
    levels = []
    for x in range(0, w - window, window):
        patch = output[:, x:x+window]
        avg = np.mean(patch)
        levels.append(avg)
    return len(np.unique(np.round(levels, 1)))

def check_cfa_balance_lookup(lookup_func, tile_size=6):
    """Check DC balance per CFA color with lookup function."""
    cfa_sums = {0: 0, 1: 0, 2: 0, 3: 0}
    for y in range(tile_size):
        for x in range(tile_size):
            cfa = get_cfa(y, x)
            val = lookup_func(y, x)
            cfa_sums[cfa] += val
    # Allow small floating point error
    return all(abs(s) < 0.1 for s in cfa_sums.values())

def main():
    print("=" * 70)
    print("Matrix Comparison: 3x3 vs 8x8, halved vs full, phase variants")
    print("=" * 70)

    # All matrices to test
    test_matrices_3x3 = {
        "3x3 Optimal": MATRIX_OPTIMAL,
        "3x3 Checker": MATRIX_CHECKER,
        "3x3 DiagGrad": MATRIX_DIAG_GRAD,
        "3x3 Diamond": MATRIX_DIAMOND,
    }

    test_matrices_8x8 = {
        "8x8 CFA": MATRIX_8x8_CFA,   # CFA-balanced 8x8 (only balanced version)
    }

    results = []
    gradient = create_gradient(512, 48)

    # Test 3x3 matrices
    for name, mat in test_matrices_3x3.items():
        mat_sum = np.sum(mat)
        disp = measure_dispersion(mat)

        # Test phases × halved variants
        for phase_name, make_lookup in [("std", make_standard_lookup),
                                          ("diag", make_diagonal_lookup),
                                          ("anti", make_antidiag_lookup)]:
            for halved in [True, False]:
                lookup = make_lookup(mat)
                # Use 6x6 tile for 3x3 (LCM of 3 and 2)
                cfa_ok = check_cfa_balance_lookup(lookup, tile_size=6)

                dithered = apply_dither_hpi(gradient, mat, lookup_func=lookup, halved=halved)
                dithered_rgb, _ = apply_dither_hpi_cfa(gradient, mat, lookup_func=lookup, halved=halved)
                perceived_blurred = simulate_perceived(dithered_rgb)

                n_levels = measure_perceived_levels(perceived_blurred)

                half_str = "half" if halved else "full"
                full_name = f"{name} {phase_name} {half_str}"
                results.append({
                    'name': full_name,
                    'matrix': mat,
                    'phase': phase_name,
                    'halved': halved,
                    'sum': mat_sum,
                    'dispersion': disp,
                    'cfa_balanced': cfa_ok,
                    'levels': n_levels,
                    'dithered': dithered,
                    'dithered_rgb': dithered_rgb,
                    'perceived': perceived_blurred,
                    'lookup': lookup
                })

                status = "OK" if abs(mat_sum) < 0.1 and cfa_ok else "BAD"
                print(f"{full_name:30s}: disp={disp:5.1f}, levels={n_levels:2d}, CFA={cfa_ok} [{status}]")

    # Test 8x8 matrices
    for name, mat in test_matrices_8x8.items():
        mat_sum = np.sum(mat)
        disp = measure_dispersion(mat)

        # Test phases × halved variants
        for phase_name, make_lookup in [("std", make_standard_lookup),
                                          ("diag", make_diagonal_lookup),
                                          ("anti", make_antidiag_lookup)]:
            for halved in [True, False]:
                lookup = make_lookup(mat)
                # Use 8x8 tile for 8x8 matrix (LCM of 8 and 2 is 8)
                cfa_ok = check_cfa_balance_lookup(lookup, tile_size=8)

                dithered = apply_dither_hpi(gradient, mat, lookup_func=lookup, halved=halved)
                dithered_rgb, _ = apply_dither_hpi_cfa(gradient, mat, lookup_func=lookup, halved=halved)
                perceived_blurred = simulate_perceived(dithered_rgb)

                n_levels = measure_perceived_levels(perceived_blurred)

                half_str = "half" if halved else "full"
                full_name = f"{name} {phase_name} {half_str}"
                results.append({
                    'name': full_name,
                    'matrix': mat,
                    'phase': phase_name,
                    'halved': halved,
                    'sum': mat_sum,
                    'dispersion': disp,
                    'cfa_balanced': cfa_ok,
                    'levels': n_levels,
                    'dithered': dithered,
                    'dithered_rgb': dithered_rgb,
                    'perceived': perceived_blurred,
                    'lookup': lookup
                })

                status = "OK" if abs(mat_sum) < 0.1 and cfa_ok else "BAD"
                print(f"{full_name:30s}: disp={disp:5.1f}, levels={n_levels:2d}, CFA={cfa_ok} [{status}]")

    # Sort by levels (higher is better)
    results.sort(key=lambda x: (x['levels'], x['dispersion']), reverse=True)

    print("\n" + "=" * 70)
    print("Ranking by levels (then dispersion):")
    print("=" * 70)
    for i, r in enumerate(results):
        ok = "✓" if abs(r['sum']) < 0.1 and r['cfa_balanced'] else "✗"
        print(f"{i+1:2d}. {r['name']:30s}: levels={r['levels']:2d}, disp={r['dispersion']:5.1f} {ok}")

    # Create comparison image with CFA simulation
    print("\nCreating comparison images...")

    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 11)
    except:
        font = ImageFont.load_default()

    # Show ALL results (including CFA-unbalanced like 8x8) - top 15
    valid = results[:15]  # Top 15 by levels

    gap = 4
    height = 48
    width = 512
    n_rows = len(valid)

    # Create 3-column comparison at FULL resolution: CFA RGB | Perceived | Grayscale
    total_w = width * 3 + 20  # 3 columns + gaps
    total_h = n_rows * (14 + height + gap) + 40

    img = Image.new('RGB', (total_w, total_h), (200, 200, 200))
    draw = ImageDraw.Draw(img)

    # Header
    draw.text((5, 5), "CFA Subpixels (raw)", fill=(0, 0, 0), font=font)
    draw.text((width + 10, 5), "Perceived (CFA blurred->lum)", fill=(0, 0, 0), font=font)
    draw.text((width * 2 + 15, 5), "Grayscale (no CFA)", fill=(0, 0, 0), font=font)

    y = 25
    for r in valid:
        label = f"{r['name']} ({r['levels']} lvl, disp={r['dispersion']:.0f})"
        draw.text((5, y), label, fill=(0, 0, 0), font=font)
        y += 14

        # CFA RGB subpixels - FULL resolution
        for row in range(height):
            for col in range(width):
                rgb = tuple(r['dithered_rgb'][row, col])
                img.putpixel((col, y + row), rgb)

        # Perceived (blurred grayscale) - FULL resolution
        for row in range(height):
            for col in range(width):
                v = int(r['perceived'][row, col])
                img.putpixel((width + 10 + col, y + row), (v, v, v))

        # Original grayscale (no CFA) - FULL resolution
        for row in range(height):
            for col in range(width):
                v = int(r['dithered'][row, col])
                img.putpixel((width * 2 + 15 + col, y + row), (v, v, v))

        y += height + gap

    img.save('matrix_phase_gradient.png')
    print("Saved: matrix_phase_gradient.png")

    # Create zoomed pattern view WITH CFA overlay
    # CFA colors: B=(0,0,255), W=(200,200,200), G=(0,255,0), R=(255,0,0)
    CFA_COLORS = {
        0: (80, 80, 220),    # Blue
        1: (180, 180, 180),  # White
        2: (80, 200, 80),    # Green
        3: (220, 80, 80),    # Red
    }
    CFA_NAMES = ['B', 'W', 'G', 'R']

    zoom = 16
    tile = 12
    n_cols = 4
    n_rows_pat = (len(valid) + n_cols - 1) // n_cols

    pat_w = tile * zoom * n_cols + (n_cols - 1) * 10 + 20
    pat_h = n_rows_pat * (tile * zoom + 25) + 20

    pat_img = Image.new('RGB', (pat_w, pat_h), (255, 255, 255))
    draw_p = ImageDraw.Draw(pat_img)

    for idx, r in enumerate(valid):
        col = idx % n_cols
        row = idx // n_cols

        x0 = 10 + col * (tile * zoom + 10)
        y0 = 10 + row * (tile * zoom + 25)

        # Draw label
        draw_p.text((x0, y0), r['name'][:20], fill=(0, 0, 0), font=font)
        y0 += 12

        # Draw pattern using lookup function with CFA overlay
        lookup = r['lookup']
        for py in range(tile):
            for px in range(tile):
                val = lookup(py, px)
                cfa = get_cfa(py, px)
                base_color = CFA_COLORS[cfa]

                # Modulate brightness based on dither value
                # val ranges from -7 to +7, map to brightness factor
                brightness = 1.0 + val / 14.0  # 0.5 to 1.5
                color = tuple(int(min(255, c * brightness)) for c in base_color)

                rx, ry = x0 + px * zoom, y0 + py * zoom
                draw_p.rectangle([rx, ry, rx + zoom - 1, ry + zoom - 1], fill=color)

                # Draw dither value text
                try:
                    small_font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 9)
                except:
                    small_font = font
                text = f"{int(val):+d}"
                draw_p.text((rx + 2, ry + 2), text, fill=(255, 255, 255), font=small_font)

    pat_img.save('matrix_phase_patterns.png')
    print("Saved: matrix_phase_patterns.png")

    # Also create a per-CFA summary showing what each color sees
    print("\nPer-CFA dither value distribution (6x6 tile):")
    for r in valid[:4]:  # Top 4
        print(f"\n{r['name']}:")
        lookup = r['lookup']
        cfa_vals = {0: [], 1: [], 2: [], 3: []}
        for py in range(6):
            for px in range(6):
                cfa = get_cfa(py, px)
                val = lookup(py, px)
                cfa_vals[cfa].append(val)
        for cfa in range(4):
            vals = cfa_vals[cfa]
            print(f"  {CFA_NAMES[cfa]}: {sorted(vals)} sum={sum(vals):.0f}")

if __name__ == "__main__":
    main()
