#!/usr/bin/env python3
"""
RGBW CFA Palette Swatches - Systematic Grid

Shows all possible colors from 2-bit RGBW reflective display.
Organized by filter type and gray level.
"""

import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle
import matplotlib.patches as mpatches

# Filter transmission coefficients
K_B = 0.10
K_G = 0.60
K_R = 0.30
K_W = 1.00

# Gray levels (0-255)
GRAY_LEVELS = [0, 85, 170, 255]  # B, DG, LG, W
GRAY_NAMES = ['B(00)', 'DG(01)', 'LG(10)', 'W(11)']

# Filters
FILTERS = ['B', 'G', 'R', 'W']
FILTER_NAMES = ['Blue Filter', 'Green Filter', 'Red Filter', 'White Filter']

def gray_to_rgb(gray_level, filter_type):
    """Calculate RGB for gray level behind CFA filter (reflective display)."""
    reflectance = gray_level / 255.0

    if filter_type == 'B':
        return (0, 0, int(reflectance * K_B * 255))
    elif filter_type == 'G':
        return (0, int(reflectance * K_G * 255), 0)
    elif filter_type == 'R':
        return (int(reflectance * K_R * 255), 0, 0)
    elif filter_type == 'W':
        lum = int(reflectance * K_W * 255)
        return (lum, lum, lum)

def create_systematic_swatches():
    """Create systematic 4×4 grid of filter×gray combinations."""
    fig, ax = plt.subplots(figsize=(12, 12))

    swatch_size = 2.0
    gap = 0.1
    label_offset = 0.3

    # Draw swatches
    for row, (filter_type, filter_name) in enumerate(zip(FILTERS, FILTER_NAMES)):
        for col, (gray_level, gray_name) in enumerate(zip(GRAY_LEVELS, GRAY_NAMES)):
            # Calculate position (inverted Y for top-down)
            x = col * (swatch_size + gap)
            y = (3 - row) * (swatch_size + gap)  # Invert for top-down

            # Get color
            rgb = gray_to_rgb(gray_level, filter_type)
            color = tuple(c / 255.0 for c in rgb)

            # Draw swatch
            rect = Rectangle((x, y), swatch_size, swatch_size,
                           facecolor=color, edgecolor='black', linewidth=2)
            ax.add_patch(rect)

            # Add RGB values in center
            text_color = 'white' if sum(rgb) < 384 else 'black'
            ax.text(x + swatch_size/2, y + swatch_size/2,
                   f'R:{rgb[0]}\nG:{rgb[1]}\nB:{rgb[2]}',
                   ha='center', va='center', fontsize=9,
                   color=text_color, fontweight='bold',
                   family='monospace')

            # Add gray level label at top
            if row == 0:  # Only on first row
                ax.text(x + swatch_size/2, y + swatch_size + label_offset,
                       gray_name,
                       ha='center', va='bottom', fontsize=11,
                       fontweight='bold')

            # Add filter label on left
            if col == 0:  # Only on first column
                ax.text(x - label_offset, y + swatch_size/2,
                       filter_name,
                       ha='right', va='center', fontsize=11,
                       fontweight='bold', rotation=0)

    # Add title
    ax.text(4.3, 9.5,
           'RGBW Reflective Display Palette\nAll Filter × Gray Level Combinations',
           ha='center', va='top', fontsize=16, fontweight='bold')

    # Add physics explanation
    explanation = (
        'Reflective Display Physics:\n'
        'Color = Reflectance (Gray Level) × Filter Transmission\n\n'
        'Note: B(00) behind any filter = BLACK (no light to reflect)\n'
        '→ Only 13 distinct colors (not 16)'
    )
    ax.text(4.3, -1.5, explanation,
           ha='center', va='top', fontsize=10,
           bbox=dict(boxstyle='round', facecolor='wheat', alpha=0.8))

    # Add filter coefficients
    coeff_text = f'Filter Coefficients: B={K_B}, G={K_G}, R={K_R}, W={K_W}'
    ax.text(4.3, -2.8, coeff_text,
           ha='center', va='top', fontsize=9, style='italic')

    ax.set_xlim(-1.5, 10.0)
    ax.set_ylim(-3.5, 10.0)
    ax.set_aspect('equal')
    ax.axis('off')

    plt.tight_layout()
    return fig

def create_primaries_list():
    """Create list view of the 13 distinct primaries."""
    fig, ax = plt.subplots(figsize=(16, 3))

    primaries = []

    # Black (only count once)
    primaries.append(('Black\n(B behind any)', gray_to_rgb(0, 'B')))

    # Blues (3)
    for i, gray in enumerate([85, 170, 255]):
        primaries.append((f'Blue-{GRAY_NAMES[i+1]}', gray_to_rgb(gray, 'B')))

    # Greens (3)
    for i, gray in enumerate([85, 170, 255]):
        primaries.append((f'Green-{GRAY_NAMES[i+1]}', gray_to_rgb(gray, 'G')))

    # Reds (3)
    for i, gray in enumerate([85, 170, 255]):
        primaries.append((f'Red-{GRAY_NAMES[i+1]}', gray_to_rgb(gray, 'R')))

    # Grays (3)
    for i, gray in enumerate([85, 170, 255]):
        primaries.append((f'Gray-{GRAY_NAMES[i+1]}', gray_to_rgb(gray, 'W')))

    swatch_width = 1.0
    for i, (name, rgb) in enumerate(primaries):
        color = tuple(c / 255.0 for c in rgb)
        rect = Rectangle((i * swatch_width, 0), swatch_width, 1.0,
                        facecolor=color, edgecolor='black', linewidth=2)
        ax.add_patch(rect)

        # Label
        ax.text(i * swatch_width + swatch_width/2, -0.15, name,
               ha='center', va='top', fontsize=9, rotation=45)

        # RGB
        text_color = 'white' if sum(rgb) < 384 else 'black'
        ax.text(i * swatch_width + swatch_width/2, 0.5,
               f'{rgb[0]},{rgb[1]},{rgb[2]}',
               ha='center', va='center', fontsize=7,
               color=text_color, family='monospace')

    ax.set_xlim(0, len(primaries) * swatch_width)
    ax.set_ylim(-0.6, 1.1)
    ax.set_aspect('equal')
    ax.axis('off')
    ax.set_title('13 Distinct Primary Colors (Unique Individual Outputs)',
                fontsize=14, fontweight='bold', pad=20)

    plt.tight_layout()
    return fig

if __name__ == '__main__':
    print("Creating RGBW palette swatches...")

    # Create systematic 4×4 grid
    fig1 = create_systematic_swatches()
    fig1.savefig('rgbw_systematic_grid.png', dpi=200, bbox_inches='tight',
                facecolor='white')
    print("Saved: rgbw_systematic_grid.png")

    # Create primaries list
    fig2 = create_primaries_list()
    fig2.savefig('rgbw_13_primaries.png', dpi=200, bbox_inches='tight',
                facecolor='white')
    print("Saved: rgbw_13_primaries.png")

    print("\nDone! Created 2 visualization files.")
    plt.show()
