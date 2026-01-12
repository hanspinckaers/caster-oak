#!/usr/bin/env python3
"""Test diagonal shift variants of 3x3 matrix with RGBW CFA."""

import numpy as np
from PIL import Image, ImageDraw, ImageFont

# Optimal 3x3 matrix (sum=0)
MATRIX_3x3 = np.array([
    [-7, -3, +5],
    [ 0, +6, -6],
    [+7, -5, +3]
], dtype=np.float32)

# CFA pattern: 0=B, 1=W, 2=G, 3=R
def get_cfa(y, x):
    row = y % 2
    col = x % 2
    if row == 0:
        return 0 if col == 0 else 1  # B, W
    else:
        return 2 if col == 0 else 3  # G, R

CFA_NAMES = ['Blue', 'White', 'Green', 'Red']

def get_3x3_standard(y, x):
    """Standard 3x3 - no diagonal shift."""
    return MATRIX_3x3[y % 3, x % 3]

def get_3x3_diagonal_1(y, x):
    """Diagonal shift: (x + y) % 3."""
    return MATRIX_3x3[y % 3, (x + y) % 3]

def get_3x3_diagonal_2(y, x):
    """Diagonal shift every 2 lines: (x + y//2) % 3."""
    return MATRIX_3x3[y % 3, (x + y // 2) % 3]

def get_3x3_diagonal_cfa(y, x):
    """Diagonal shift aligned to CFA: (x + y//2) % 3, shift on CFA row boundary."""
    # Shift by 1 every 2 rows (aligned with CFA row pairs)
    return MATRIX_3x3[y % 3, (x + (y // 2)) % 3]

def get_3x3_antidiag(y, x):
    """Anti-diagonal: (x - y) % 3."""
    return MATRIX_3x3[y % 3, (x - y) % 3]

def check_dc_balance(get_dither_func, name, tile_size=6):
    """Check DC balance per CFA color over tile."""
    print(f"\n{name}:")
    cfa_sums = {0: 0, 1: 0, 2: 0, 3: 0}
    cfa_counts = {0: 0, 1: 0, 2: 0, 3: 0}

    for y in range(tile_size):
        for x in range(tile_size):
            cfa = get_cfa(y, x)
            val = get_dither_func(y, x)
            cfa_sums[cfa] += val
            cfa_counts[cfa] += 1

    balanced = True
    for cfa in range(4):
        avg = cfa_sums[cfa] / cfa_counts[cfa] if cfa_counts[cfa] > 0 else 0
        status = "OK" if abs(cfa_sums[cfa]) < 0.01 else "BIAS"
        if abs(cfa_sums[cfa]) >= 0.01:
            balanced = False
        print(f"  {CFA_NAMES[cfa]:6s}: sum={cfa_sums[cfa]:+6.1f}, count={cfa_counts[cfa]}, avg={avg:+.2f} [{status}]")

    return balanced

def create_pattern_image(get_dither_func, name, size=48):
    """Create image showing dither pattern."""
    img = np.zeros((size, size), dtype=np.float32)
    for y in range(size):
        for x in range(size):
            img[y, x] = get_dither_func(y, x)

    # Normalize to 0-255 for visualization
    img_norm = ((img + 8) / 16 * 255).clip(0, 255).astype(np.uint8)
    return img_norm

def create_gradient_dithered(get_dither_func, width=512, height=48, bias=12):
    """Apply dithering to gradient."""
    output = np.zeros((height, width), dtype=np.uint8)

    for y in range(height):
        for x in range(width):
            pix = int(x * 255 / (width - 1))
            dither = get_dither_func(y, x) / 2  # Halved

            # HPI-style: keep precision
            result = pix + bias + dither * 16
            result = max(0, min(255, result))

            # Quantize
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

def create_raw_pattern_zoom(get_dither_func, name, tile_size=12, zoom=16):
    """Show raw dither values as colored heatmap, zoomed."""
    img = Image.new('RGB', (tile_size * zoom, tile_size * zoom), (128, 128, 128))
    draw = ImageDraw.Draw(img)

    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 10)
    except:
        font = None

    for y in range(tile_size):
        for x in range(tile_size):
            val = get_dither_func(y, x)
            # Color: blue for negative, red for positive, white for zero
            if val < 0:
                intensity = int(min(255, -val * 30))
                color = (0, 0, intensity)  # Blue
            elif val > 0:
                intensity = int(min(255, val * 30))
                color = (intensity, 0, 0)  # Red
            else:
                color = (200, 200, 200)  # Gray for zero

            x0, y0 = x * zoom, y * zoom
            draw.rectangle([x0, y0, x0 + zoom - 1, y0 + zoom - 1], fill=color)

            # Draw value
            if font and zoom >= 16:
                text = f"{int(val):+d}"
                draw.text((x0 + 2, y0 + 2), text, fill=(255, 255, 255), font=font)

    return img

def main():
    methods = [
        ("Standard 3x3", get_3x3_standard),
        ("Diagonal (x+y)%3", get_3x3_diagonal_1),
        ("Diagonal (x+y//2)%3", get_3x3_diagonal_2),
        ("Anti-diag (x-y)%3", get_3x3_antidiag),
    ]

    # Create zoomed raw pattern images
    print("Creating zoomed pattern images...")
    zoom_imgs = []
    for name, func in methods:
        img = create_raw_pattern_zoom(func, name, tile_size=12, zoom=20)
        zoom_imgs.append((name, img))

    # Combine side by side
    w, h = zoom_imgs[0][1].size
    combined = Image.new('RGB', (w * 2 + 10, h * 2 + 10 + 40), (255, 255, 255))
    draw_c = ImageDraw.Draw(combined)

    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 14)
    except:
        font = ImageFont.load_default()

    positions = [(0, 20), (w + 10, 20), (0, h + 30), (w + 10, h + 30)]
    for i, (name, img) in enumerate(zoom_imgs):
        px, py = positions[i]
        combined.paste(img, (px, py))
        draw_c.text((px + 5, py - 18), name, fill=(0, 0, 0), font=font)

    combined.save('diagonal_3x3_raw_patterns.png')
    print("Saved: diagonal_3x3_raw_patterns.png")

    print("=" * 60)
    print("DC Balance Check (6x6 tile)")
    print("=" * 60)

    for name, func in methods:
        check_dc_balance(func, name)

    # Create comparison image
    print("\n" + "=" * 60)
    print("Creating comparison images...")
    print("=" * 60)

    # Pattern images
    patterns = []
    for name, func in methods:
        pat = create_pattern_image(func, name)
        patterns.append((name, pat))

    # Gradient images
    gradients = []
    for name, func in methods:
        grad = create_gradient_dithered(func)
        gradients.append((name, grad))

    # Combine into comparison
    gap = 4
    height = 48

    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 12)
    except:
        font = ImageFont.load_default()

    # Pattern comparison
    total_h = len(patterns) * (16 + height + gap) + 20
    img_pat = Image.new('L', (256, total_h), 200)
    draw = ImageDraw.Draw(img_pat)

    y = 10
    for name, pat in patterns:
        draw.text((5, y), name, fill=0, font=font)
        y += 16
        for row in range(min(height, pat.shape[0])):
            for col in range(min(256, pat.shape[1])):
                img_pat.putpixel((col, y + row), int(pat[row % pat.shape[0], col % pat.shape[1]]))
        y += height + gap

    img_pat.save('diagonal_3x3_patterns.png')
    print("Saved: diagonal_3x3_patterns.png")

    # Gradient comparison
    width = 512
    total_h = len(gradients) * (16 + height + gap) + 20
    img_grad = Image.new('L', (width, total_h), 200)
    draw = ImageDraw.Draw(img_grad)

    y = 10
    for name, grad in gradients:
        draw.text((5, y), name, fill=0, font=font)
        y += 16
        for row in range(height):
            for col in range(width):
                img_grad.putpixel((col, y + row), int(grad[row, col]))
        y += height + gap

    img_grad.save('diagonal_3x3_gradients.png')
    print("Saved: diagonal_3x3_gradients.png")

if __name__ == "__main__":
    main()
