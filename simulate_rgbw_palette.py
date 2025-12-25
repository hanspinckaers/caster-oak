#!/usr/bin/env python3
"""
RGBW CFA Palette Simulator for Reflective E-ink Display

Simulates all possible colors from 2-bit (4-level) grayscale behind RGBW CFA.
Shows the 13 primaries and all 256 quad combinations.
"""

import numpy as np
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle
import matplotlib.patches as mpatches

# ============================================================================
# Display Physics Constants
# ============================================================================

# Filter transmission coefficients (how much light passes through each filter)
K_B = 0.10  # Blue filter (very dim)
K_G = 0.60  # Green filter (medium)
K_R = 0.30  # Red filter (dimmer)
K_W = 1.00  # White filter (no attenuation)

# 4 gray levels for 2-bit grayscale
GRAY_LEVELS = {
    'B':  0,    # Black (00)
    'DG': 85,   # Dark Gray (01)  - approximately 255/3
    'LG': 170,  # Light Gray (10) - approximately 255*2/3
    'W':  255   # White (11)
}

# CFA pattern for 2×2 quad: [B, W, G, R]
# Row 0: Blue (0,0), White (0,1)
# Row 1: Green (1,0), Red (1,1)
CFA_FILTERS = ['B', 'W', 'G', 'R']
CFA_POSITIONS = [(0, 0), (0, 1), (1, 0), (1, 1)]

# ============================================================================
# Color Calculation
# ============================================================================

def gray_to_rgb(gray_level, filter_type):
    """
    Calculate RGB output for gray level behind a CFA filter.

    Reflective display physics:
    - Gray level = reflectance (0-255)
    - Filter attenuates and colors the reflected light
    - Output = gray_level × filter_transmission × filter_color

    Args:
        gray_level: 0-255 reflectance
        filter_type: 'B', 'G', 'R', or 'W'

    Returns:
        (r, g, b) tuple, each 0-255
    """
    # Normalize gray to 0-1
    reflectance = gray_level / 255.0

    if filter_type == 'B':
        # Blue filter: transmits only blue light
        return (0, 0, int(reflectance * K_B * 255))
    elif filter_type == 'G':
        # Green filter: transmits only green light
        return (0, int(reflectance * K_G * 255), 0)
    elif filter_type == 'R':
        # Red filter: transmits only red light
        return (int(reflectance * K_R * 255), 0, 0)
    elif filter_type == 'W':
        # White/clear filter: transmits all colors equally
        return (int(reflectance * K_W * 255),
                int(reflectance * K_W * 255),
                int(reflectance * K_W * 255))
    else:
        raise ValueError(f"Unknown filter type: {filter_type}")

def quad_to_color(gray_levels):
    """
    Calculate the additive mixed color for a 2×2 CFA quad.

    Args:
        gray_levels: List of 4 gray values [g_B, g_W, g_G, g_R]

    Returns:
        (r, g, b) tuple, each 0-255
    """
    # Start with black (no light)
    r_total, g_total, b_total = 0, 0, 0

    # Add contribution from each subpixel (additive color mixing)
    for i, (gray, filter_type) in enumerate(zip(gray_levels, CFA_FILTERS)):
        r, g, b = gray_to_rgb(gray, filter_type)
        r_total += r
        g_total += g
        b_total += b

    # Average over 4 subpixels and clamp to 255
    r_avg = min(255, r_total // 4)
    g_avg = min(255, g_total // 4)
    b_avg = min(255, b_total // 4)

    return (r_avg, g_avg, b_avg)

# ============================================================================
# Generate Palette
# ============================================================================

def generate_primaries():
    """
    Generate the 13 distinct primary colors.

    Returns:
        List of (name, rgb) tuples
    """
    primaries = []
    gray_names = ['DG', 'LG', 'W']

    # 1. Black (B behind any filter)
    primaries.append(('Black', gray_to_rgb(GRAY_LEVELS['B'], 'B')))

    # 2-4. Blues (DG/LG/W behind B filter)
    for g_name in gray_names:
        rgb = gray_to_rgb(GRAY_LEVELS[g_name], 'B')
        primaries.append((f'Blue-{g_name}', rgb))

    # 5-7. Greens (DG/LG/W behind G filter)
    for g_name in gray_names:
        rgb = gray_to_rgb(GRAY_LEVELS[g_name], 'G')
        primaries.append((f'Green-{g_name}', rgb))

    # 8-10. Reds (DG/LG/W behind R filter)
    for g_name in gray_names:
        rgb = gray_to_rgb(GRAY_LEVELS[g_name], 'R')
        primaries.append((f'Red-{g_name}', rgb))

    # 11-13. Grays (DG/LG/W behind W filter)
    for g_name in gray_names:
        rgb = gray_to_rgb(GRAY_LEVELS[g_name], 'W')
        primaries.append((f'Gray-{g_name}', rgb))

    return primaries

def generate_all_combinations():
    """
    Generate all 256 quad combinations.

    Returns:
        List of (gray_levels, rgb) tuples
    """
    combinations = []
    gray_values = [GRAY_LEVELS['B'], GRAY_LEVELS['DG'],
                   GRAY_LEVELS['LG'], GRAY_LEVELS['W']]

    # Iterate through all 4^4 = 256 combinations
    for g_b in gray_values:
        for g_w in gray_values:
            for g_g in gray_values:
                for g_r in gray_values:
                    gray_levels = [g_b, g_w, g_g, g_r]
                    rgb = quad_to_color(gray_levels)
                    combinations.append((gray_levels, rgb))

    return combinations

# ============================================================================
# Visualization
# ============================================================================

def plot_primaries(primaries):
    """Plot the 13 primary colors as swatches."""
    fig, ax = plt.subplots(figsize=(14, 3))

    swatch_width = 1.0
    for i, (name, rgb) in enumerate(primaries):
        color = tuple(c / 255.0 for c in rgb)  # Normalize to 0-1
        rect = Rectangle((i * swatch_width, 0), swatch_width, 1.0,
                        facecolor=color, edgecolor='black', linewidth=1)
        ax.add_patch(rect)

        # Add label
        ax.text(i * swatch_width + swatch_width/2, -0.15, name,
               ha='center', va='top', fontsize=8, rotation=45)

        # Add RGB values
        ax.text(i * swatch_width + swatch_width/2, 0.5,
               f'{rgb[0]},{rgb[1]},{rgb[2]}',
               ha='center', va='center', fontsize=6,
               color='white' if sum(rgb) < 384 else 'black')

    ax.set_xlim(0, len(primaries) * swatch_width)
    ax.set_ylim(-0.5, 1.0)
    ax.set_aspect('equal')
    ax.axis('off')
    ax.set_title('13 Distinct Primary Colors (Individual Subpixel Outputs)',
                fontsize=14, fontweight='bold', pad=20)

    plt.tight_layout()
    return fig

def plot_all_combinations(combinations, sort_by='brightness'):
    """
    Plot all 256 quad combinations as a color grid.

    Args:
        combinations: List of (gray_levels, rgb) tuples
        sort_by: 'brightness', 'hue', or 'none'
    """
    # Sort combinations
    if sort_by == 'brightness':
        # Sort by luminance (Y = 0.299R + 0.587G + 0.114B)
        combinations = sorted(combinations,
                            key=lambda x: (0.299*x[1][0] + 0.587*x[1][1] + 0.114*x[1][2]))
    elif sort_by == 'hue':
        # Sort by hue (convert to HSV)
        def rgb_to_hsv(rgb):
            r, g, b = [c/255.0 for c in rgb]
            max_c = max(r, g, b)
            min_c = min(r, g, b)
            diff = max_c - min_c

            if diff == 0:
                return (0, 0, max_c)  # Hue undefined for grayscale

            if max_c == r:
                h = ((g - b) / diff) % 6
            elif max_c == g:
                h = ((b - r) / diff) + 2
            else:
                h = ((r - g) / diff) + 4

            s = 0 if max_c == 0 else diff / max_c
            v = max_c

            return (h, s, v)

        combinations = sorted(combinations, key=lambda x: rgb_to_hsv(x[1]))

    # Create 16×16 grid
    fig, ax = plt.subplots(figsize=(16, 16))

    swatch_size = 1.0
    for i, (gray_levels, rgb) in enumerate(combinations):
        row = i // 16
        col = i % 16

        color = tuple(c / 255.0 for c in rgb)  # Normalize to 0-1
        rect = Rectangle((col * swatch_size, (15-row) * swatch_size),
                        swatch_size, swatch_size,
                        facecolor=color, edgecolor='gray', linewidth=0.5)
        ax.add_patch(rect)

        # Add gray level notation for some swatches (not all, too crowded)
        if i % 16 == 0 or i < 16:  # First column and first row
            gray_str = f"{gray_levels[0]},{gray_levels[1]}\n{gray_levels[2]},{gray_levels[3]}"
            ax.text(col * swatch_size + swatch_size/2,
                   (15-row) * swatch_size + swatch_size/2,
                   gray_str, ha='center', va='center', fontsize=4,
                   color='white' if sum(rgb) < 384 else 'black')

    ax.set_xlim(0, 16 * swatch_size)
    ax.set_ylim(0, 16 * swatch_size)
    ax.set_aspect('equal')
    ax.axis('off')

    title = f'All 256 Quad Combinations (4×4 Gray Levels)'
    if sort_by != 'none':
        title += f' - Sorted by {sort_by.capitalize()}'
    ax.set_title(title, fontsize=16, fontweight='bold', pad=20)

    # Add legend explaining the layout
    legend_text = (f'2×2 CFA Quad: [g_B, g_W, g_G, g_R]\n'
                  f'Gray levels: B=0, DG=85, LG=170, W=255\n'
                  f'Additive mixing creates final color')
    ax.text(8, -0.5, legend_text, ha='center', fontsize=10,
           bbox=dict(boxstyle='round', facecolor='wheat', alpha=0.5))

    plt.tight_layout()
    return fig

def plot_grayscale_gradient():
    """
    Plot what a smooth grayscale gradient looks like with filter compensation.
    This simulates the actual dithering algorithm output.
    """
    fig, axes = plt.subplots(2, 1, figsize=(16, 6))

    # Generate 256 grayscale levels
    gradient = []
    for y8 in range(256):
        # Simulate filter-compensated dithering
        # Each subpixel gets compensated value
        # For simplicity, just show what happens with equal gray levels
        rgb = quad_to_color([y8, y8, y8, y8])
        gradient.append(rgb)

    # Plot gradient with equal gray levels (uncompensated)
    for i, rgb in enumerate(gradient):
        color = tuple(c / 255.0 for c in rgb)
        rect = Rectangle((i/256.0 * 16, 0), 16/256.0, 1.0,
                        facecolor=color, edgecolor='none')
        axes[0].add_patch(rect)

    axes[0].set_xlim(0, 16)
    axes[0].set_ylim(0, 1)
    axes[0].set_aspect('auto')
    axes[0].axis('off')
    axes[0].set_title('Grayscale Gradient (Equal Gray Levels - Color Cast)',
                     fontsize=12, fontweight='bold')

    # Plot gradient with filter compensation
    # Simulate the compensation algorithm
    SQRT_INV_K_B = 3.16
    SQRT_INV_K_G = 1.29
    SQRT_INV_K_R = 1.83
    SQRT_INV_K_W = 1.00

    compensated_gradient = []
    for y8 in range(256):
        # Apply filter compensation
        g_b = min(255, int(y8 * SQRT_INV_K_B))
        g_g = min(255, int(y8 * SQRT_INV_K_G))
        g_r = min(255, int(y8 * SQRT_INV_K_R))
        g_w = min(255, int(y8 * SQRT_INV_K_W))

        # Balance luminance (simplified)
        avg_lum = (g_b*K_B + g_g*K_G + g_r*K_R + g_w*K_W) / (K_B + K_G + K_R + K_W)
        correction = y8 - avg_lum

        g_b = max(0, min(255, int(g_b + correction)))
        g_g = max(0, min(255, int(g_g + correction)))
        g_r = max(0, min(255, int(g_r + correction)))
        g_w = max(0, min(255, int(g_w + correction)))

        rgb = quad_to_color([g_b, g_w, g_g, g_r])
        compensated_gradient.append(rgb)

    for i, rgb in enumerate(compensated_gradient):
        color = tuple(c / 255.0 for c in rgb)
        rect = Rectangle((i/256.0 * 16, 0), 16/256.0, 1.0,
                        facecolor=color, edgecolor='none')
        axes[1].add_patch(rect)

    axes[1].set_xlim(0, 16)
    axes[1].set_ylim(0, 1)
    axes[1].set_aspect('auto')
    axes[1].axis('off')
    axes[1].set_title('Grayscale Gradient (Filter-Compensated - Neutral)',
                     fontsize=12, fontweight='bold')

    plt.tight_layout()
    return fig

# ============================================================================
# Main
# ============================================================================

if __name__ == '__main__':
    print("Generating RGBW CFA Palette Visualization...")
    print(f"Filter coefficients: B={K_B}, G={K_G}, R={K_R}, W={K_W}")
    print(f"Gray levels: {GRAY_LEVELS}")

    # Generate palette
    primaries = generate_primaries()
    combinations = generate_all_combinations()

    print(f"\nGenerated {len(primaries)} primary colors")
    print(f"Generated {len(combinations)} quad combinations")

    # Create visualizations
    print("\nCreating visualizations...")

    fig1 = plot_primaries(primaries)
    fig1.savefig('rgbw_primaries.png', dpi=150, bbox_inches='tight')
    print("Saved: rgbw_primaries.png")

    fig2 = plot_all_combinations(combinations, sort_by='brightness')
    fig2.savefig('rgbw_all_combinations_brightness.png', dpi=150, bbox_inches='tight')
    print("Saved: rgbw_all_combinations_brightness.png")

    fig3 = plot_all_combinations(combinations, sort_by='hue')
    fig3.savefig('rgbw_all_combinations_hue.png', dpi=150, bbox_inches='tight')
    print("Saved: rgbw_all_combinations_hue.png")

    fig4 = plot_grayscale_gradient()
    fig4.savefig('rgbw_grayscale_gradient.png', dpi=150, bbox_inches='tight')
    print("Saved: rgbw_grayscale_gradient.png")

    print("\nDone! Generated 4 visualization files.")

    # Show plots
    plt.show()
