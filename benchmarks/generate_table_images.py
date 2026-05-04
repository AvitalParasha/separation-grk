#!/usr/bin/env python3
"""
Generate SVG table images from runtime/strix_runtime files.

Produces:
  benchmarks/results/<category>/<family>.svg   — per-family comparison table
  benchmarks/results/<category>/summary.svg    — category summary table

Usage:
  python3 benchmarks/generate_table_images.py [R2R|R2P|P2R|all]
"""

import os
import sys
import re

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# --- SVG rendering helpers ---

FONT = "Menlo, Consolas, monospace"
FONT_SIZE = 13
HEADER_FONT_SIZE = 13
ROW_HEIGHT = 28
HEADER_HEIGHT = 32
PADDING_X = 12
TITLE_HEIGHT = 36
TITLE_FONT_SIZE = 15


def text_width_estimate(text, font_size):
    """Rough character-width estimate for monospace font."""
    return len(str(text)) * font_size * 0.62


def render_table_svg(title, headers, rows, col_aligns=None):
    """Render a table as an SVG string.

    Args:
        title: Table title string
        headers: List of column header strings
        rows: List of lists of cell strings
        col_aligns: List of 'l', 'r', or 'c' per column
    """
    n_cols = len(headers)
    if col_aligns is None:
        col_aligns = ['l'] * n_cols

    # Compute column widths based on content
    col_widths = []
    for c in range(n_cols):
        max_w = text_width_estimate(headers[c], HEADER_FONT_SIZE)
        for row in rows:
            if c < len(row):
                max_w = max(max_w, text_width_estimate(row[c], FONT_SIZE))
        col_widths.append(max_w + PADDING_X * 2)

    table_width = sum(col_widths) + 2  # 1px border each side
    n_rows = len(rows)
    table_height = TITLE_HEIGHT + HEADER_HEIGHT + n_rows * ROW_HEIGHT + 4

    svg_parts = []
    svg_parts.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" '
        f'width="{table_width}" height="{table_height}" '
        f'viewBox="0 0 {table_width} {table_height}">'
    )

    # Background
    svg_parts.append(
        f'<rect width="{table_width}" height="{table_height}" '
        f'fill="white" rx="4"/>'
    )

    # Title
    svg_parts.append(
        f'<text x="{table_width / 2}" y="{TITLE_HEIGHT * 0.7}" '
        f'font-family="{FONT}" font-size="{TITLE_FONT_SIZE}" '
        f'font-weight="bold" text-anchor="middle" fill="#222">'
        f'{escape_xml(title)}</text>'
    )

    y_offset = TITLE_HEIGHT

    # Header background
    svg_parts.append(
        f'<rect x="1" y="{y_offset}" width="{table_width - 2}" '
        f'height="{HEADER_HEIGHT}" fill="#2c3e50"/>'
    )

    # Header text
    x = 1
    for c, hdr in enumerate(headers):
        tx = _cell_x(x, col_widths[c], col_aligns[c])
        anchor = _anchor(col_aligns[c])
        svg_parts.append(
            f'<text x="{tx}" y="{y_offset + HEADER_HEIGHT * 0.68}" '
            f'font-family="{FONT}" font-size="{HEADER_FONT_SIZE}" '
            f'font-weight="bold" text-anchor="{anchor}" fill="white">'
            f'{escape_xml(hdr)}</text>'
        )
        x += col_widths[c]

    y_offset += HEADER_HEIGHT

    # Header bottom line
    svg_parts.append(
        f'<line x1="1" y1="{y_offset}" x2="{table_width - 1}" '
        f'y2="{y_offset}" stroke="#bdc3c7" stroke-width="2"/>'
    )

    # Rows
    for r_idx, row in enumerate(rows):
        ry = y_offset + r_idx * ROW_HEIGHT

        # Alternating row background
        if r_idx % 2 == 0:
            svg_parts.append(
                f'<rect x="1" y="{ry}" width="{table_width - 2}" '
                f'height="{ROW_HEIGHT}" fill="#f8f9fa"/>'
            )

        x = 1
        for c in range(n_cols):
            cell = row[c] if c < len(row) else ""
            tx = _cell_x(x, col_widths[c], col_aligns[c])
            anchor = _anchor(col_aligns[c])
            fill = _cell_color(cell)
            svg_parts.append(
                f'<text x="{tx}" y="{ry + ROW_HEIGHT * 0.68}" '
                f'font-family="{FONT}" font-size="{FONT_SIZE}" '
                f'text-anchor="{anchor}" fill="{fill}">'
                f'{escape_xml(cell)}</text>'
            )
            x += col_widths[c]

        # Row separator
        svg_parts.append(
            f'<line x1="1" y1="{ry + ROW_HEIGHT}" '
            f'x2="{table_width - 1}" y2="{ry + ROW_HEIGHT}" '
            f'stroke="#ecf0f1" stroke-width="0.5"/>'
        )

    # Bottom border
    svg_parts.append(
        f'<line x1="1" y1="{table_height - 2}" '
        f'x2="{table_width - 1}" y2="{table_height - 2}" '
        f'stroke="#bdc3c7" stroke-width="2"/>'
    )

    svg_parts.append('</svg>')
    return '\n'.join(svg_parts)


def _cell_x(col_start, col_width, align):
    if align == 'r':
        return col_start + col_width - PADDING_X
    elif align == 'c':
        return col_start + col_width / 2
    else:
        return col_start + PADDING_X


def _anchor(align):
    return {'l': 'start', 'r': 'end', 'c': 'middle'}.get(align, 'start')


def _cell_color(text):
    t = text.strip().upper()
    if t == 'T/O' or t == 'TIMEOUT':
        return '#e74c3c'
    if t.startswith('>'):
        return '#e67e22'
    if '---' in t:
        return '#95a5a6'
    return '#2c3e50'


def escape_xml(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


# --- Data parsing ---

def parse_runtime_file(filepath):
    """Parse a runtime file into dict: {test_name: (seconds_str, result)}."""
    results = {}
    if not os.path.isfile(filepath):
        return results
    with open(filepath) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('Test') or line.startswith('----'):
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            name = parts[0]
            result = parts[-1]
            # seconds is second field (e.g., "0.013s" or "-")
            seconds = parts[1] if len(parts) >= 2 else "-"
            results[name] = (seconds, result)
    return results


def compute_speedup(sgrk_time_str, strix_time_str, strix_result, timeout=5400):
    """Compute speedup string."""
    if strix_result in ('TIMEOUT',):
        sgrk_num = sgrk_time_str.rstrip('s')
        try:
            bound = timeout / float(sgrk_num)
            return f">{bound:,.0f}x"
        except (ValueError, ZeroDivisionError):
            return "---"
    if strix_result in ('SKIPPED', 'CONVERT_ERROR') or sgrk_time_str == '-' or strix_time_str == '-':
        return "---"
    try:
        sgrk_v = float(sgrk_time_str.rstrip('s'))
        strix_v = float(strix_time_str.rstrip('s'))
        s = strix_v / sgrk_v
        if s >= 100:
            return f"{s:,.0f}x"
        else:
            return f"{s:.1f}x"
    except (ValueError, ZeroDivisionError):
        return "---"


def extract_instance_number(name):
    """Extract instance number from e.g. 'cleaning_robots_3.sgrk' -> '3'."""
    m = re.search(r'_(\d+)\.sgrk$', name)
    return m.group(1) if m else "1"


def extract_nk(name):
    """Extract (n, k) from e.g. 'noc_router_r2r_3_4.sgrk' -> ('3', '4')."""
    m = re.search(r'_(\d+)_(\d+)\.sgrk$', name)
    if m:
        return m.group(1), m.group(2)
    return None, None


def is_nk_family(test_names):
    """Check if this family uses n_k naming convention (multiple distinct n AND k values)."""
    n_vals = set()
    k_vals = set()
    for name in test_names:
        n, k = extract_nk(name)
        if n is not None:
            n_vals.add(n)
            k_vals.add(k)
    # Only treat as n,k if there are multiple n values AND multiple k values
    return len(n_vals) > 1 and len(k_vals) > 1


def format_time(time_str):
    """Format time for display: strip trailing 's'."""
    if time_str == '-':
        return '---'
    return time_str.rstrip('s')


def format_strix_time(time_str, result):
    if result == 'TIMEOUT':
        return 'T/O'
    if result in ('SKIPPED', 'CONVERT_ERROR'):
        return '---'
    return format_time(time_str)


# --- Main ---

def generate_family_svg(cat, family, family_dir, results_dir, timeout):
    """Generate per-family SVG table(s). Returns list of info dicts for nk families."""
    sgrk_data = parse_runtime_file(os.path.join(family_dir, 'runtime'))
    strix_data = parse_runtime_file(os.path.join(family_dir, 'strix_runtime'))
    spot_data = parse_runtime_file(os.path.join(family_dir, 'spot_runtime'))

    if not sgrk_data:
        return None

    has_spot = bool(spot_data)

    test_names = sorted(sgrk_data.keys(), key=lambda n: (
        [int(x) for x in re.findall(r'\d+', n)]
    ))

    # Check if this is an n,k family (like noc_router)
    if is_nk_family(test_names):
        return _generate_nk_family_svgs(
            cat, family, family_dir, results_dir, timeout,
            sgrk_data, strix_data, spot_data, has_spot, test_names
        )

    # Standard single-table family
    if has_spot:
        headers = ['#', 'sgrk (s)', 'Strix (s)', 'Spot (s)', 'Strix Sp.', 'Spot Sp.', 'Result']
        col_aligns = ['r', 'r', 'r', 'r', 'r', 'r', 'l']
    else:
        headers = ['#', 'sgrk (s)', 'Strix (s)', 'Speedup', 'Result']
        col_aligns = ['r', 'r', 'r', 'r', 'l']
    rows = []

    for name in test_names:
        inst = extract_instance_number(name)
        sgrk_time, sgrk_result = sgrk_data[name]
        strix_time, strix_result = strix_data.get(name, ('-', 'N/A'))

        strix_speedup = compute_speedup(sgrk_time, strix_time, strix_result, timeout)
        result_display = sgrk_result if sgrk_result != 'TIMEOUT' else 'TIMEOUT'

        if has_spot:
            spot_time, spot_result = spot_data.get(name, ('-', 'N/A'))
            spot_speedup = compute_speedup(sgrk_time, spot_time, spot_result, timeout)
            rows.append([
                inst,
                format_time(sgrk_time),
                format_strix_time(strix_time, strix_result),
                format_strix_time(spot_time, spot_result),
                strix_speedup,
                spot_speedup,
                result_display,
            ])
        else:
            rows.append([
                inst,
                format_time(sgrk_time),
                format_strix_time(strix_time, strix_result),
                strix_speedup,
                result_display,
            ])

    family_pretty = family.replace('_', ' ')
    title = f"{cat}: {family_pretty}"
    svg = render_table_svg(title, headers, rows, col_aligns)

    out_path = os.path.join(results_dir, f"{family}.svg")
    with open(out_path, 'w') as f:
        f.write(svg)
    return [{
        'family': family,
        'tests': len(rows),
        'sgrk_data': sgrk_data,
        'strix_data': strix_data,
        'spot_data': spot_data,
        'test_names': test_names,
        'is_nk_sub': False,
    }]


def _generate_nk_family_svgs(cat, family, family_dir, results_dir, timeout,
                              sgrk_data, strix_data, spot_data, has_spot, test_names):
    """Generate one SVG per k-value for n,k families (e.g., noc_router)."""
    from collections import OrderedDict
    k_groups = OrderedDict()
    for name in test_names:
        n, k = extract_nk(name)
        if k is None:
            continue
        k_int = int(k)
        if k_int not in k_groups:
            k_groups[k_int] = []
        k_groups[k_int].append((name, n))

    results = []
    for k_val, entries in sorted(k_groups.items()):
        # Sort entries by n
        entries.sort(key=lambda x: int(x[1]))

        if has_spot:
            headers = ['n', 'sgrk (s)', 'Strix (s)', 'Spot (s)', 'Strix Sp.', 'Spot Sp.', 'Result']
            col_aligns = ['r', 'r', 'r', 'r', 'r', 'r', 'l']
        else:
            headers = ['n', 'sgrk (s)', 'Strix (s)', 'Speedup', 'Result']
            col_aligns = ['r', 'r', 'r', 'r', 'l']
        rows = []

        sub_test_names = []
        for name, n in entries:
            sub_test_names.append(name)
            sgrk_time, sgrk_result = sgrk_data[name]
            strix_time, strix_result = strix_data.get(name, ('-', 'N/A'))

            strix_speedup = compute_speedup(sgrk_time, strix_time, strix_result, timeout)
            result_display = sgrk_result if sgrk_result != 'TIMEOUT' else 'TIMEOUT'

            if has_spot:
                spot_time, spot_result = spot_data.get(name, ('-', 'N/A'))
                spot_speedup = compute_speedup(sgrk_time, spot_time, spot_result, timeout)
                rows.append([
                    n,
                    format_time(sgrk_time),
                    format_strix_time(strix_time, strix_result),
                    format_strix_time(spot_time, spot_result),
                    strix_speedup,
                    spot_speedup,
                    result_display,
                ])
            else:
                rows.append([
                    n,
                    format_time(sgrk_time),
                    format_strix_time(strix_time, strix_result),
                    strix_speedup,
                    result_display,
                ])

        family_pretty = family.replace('_', ' ')
        title = f"{cat}: {family_pretty} (k={k_val})"
        svg = render_table_svg(title, headers, rows, col_aligns)

        svg_name = f"{family}_k{k_val}"
        out_path = os.path.join(results_dir, f"{svg_name}.svg")
        with open(out_path, 'w') as f:
            f.write(svg)

        results.append({
            'family': family,
            'svg_name': svg_name,
            'k_val': k_val,
            'tests': len(rows),
            'sgrk_data': {n: sgrk_data[n] for n in sub_test_names},
            'strix_data': {n: strix_data.get(n, ('-', 'N/A')) for n in sub_test_names},
            'spot_data': {n: spot_data.get(n, ('-', 'N/A')) for n in sub_test_names} if spot_data else {},
            'test_names': sub_test_names,
            'is_nk_sub': True,
        })

    return results


def generate_summary_svg(cat, family_infos, results_dir, timeout):
    """Generate category summary SVG table."""
    has_any_spot = any(bool(info.get('spot_data')) for info in family_infos)

    if has_any_spot:
        headers = ['Family', 'Tests', 'Match', 'Strix T/O', 'Spot T/O',
                   'sgrk Range (s)', 'Strix Range (s)', 'Spot Range (s)']
        col_aligns = ['l', 'r', 'r', 'r', 'r', 'r', 'r', 'r']
    else:
        headers = ['Family', 'Tests', 'Match', 'Strix T/O', 'sgrk Range (s)', 'Strix Range (s)']
        col_aligns = ['l', 'r', 'r', 'r', 'r', 'r']
    rows = []

    for info in family_infos:
        family_pretty = info['family'].replace('_', ' ')
        n_tests = info['tests']

        matches = 0
        strix_timeouts = 0
        spot_timeouts = 0
        sgrk_vals = []
        strix_vals = []
        spot_vals = []

        for name in info['test_names']:
            sgrk_time, sgrk_result = info['sgrk_data'][name]
            strix_time, strix_result = info['strix_data'].get(name, ('-', 'N/A'))

            sgrk_norm = sgrk_result.upper()
            strix_norm = strix_result.upper()

            if strix_norm in ('TIMEOUT', 'SKIPPED'):
                strix_timeouts += 1
            elif sgrk_norm == strix_norm:
                matches += 1

            if sgrk_time != '-':
                try:
                    sgrk_vals.append(float(sgrk_time.rstrip('s')))
                except ValueError:
                    pass
            if strix_time != '-' and strix_result not in ('TIMEOUT', 'SKIPPED'):
                try:
                    strix_vals.append(float(strix_time.rstrip('s')))
                except ValueError:
                    pass

            if info.get('spot_data'):
                spot_time, spot_result = info['spot_data'].get(name, ('-', 'N/A'))
                if spot_result in ('TIMEOUT', 'SKIPPED'):
                    spot_timeouts += 1
                if spot_time != '-' and spot_result not in ('TIMEOUT', 'SKIPPED'):
                    try:
                        spot_vals.append(float(spot_time.rstrip('s')))
                    except ValueError:
                        pass

        def _range_str(vals):
            if not vals:
                return "N/A"
            if min(vals) == max(vals):
                return f"{min(vals):.3f}"
            return f"{min(vals):.3f} - {max(vals):.3f}"

        if has_any_spot:
            rows.append([
                family_pretty, str(n_tests), str(matches),
                str(strix_timeouts), str(spot_timeouts),
                _range_str(sgrk_vals), _range_str(strix_vals), _range_str(spot_vals),
            ])
        else:
            rows.append([
                family_pretty, str(n_tests), str(matches),
                str(strix_timeouts),
                _range_str(sgrk_vals), _range_str(strix_vals),
            ])

    tool_list = "sgrk vs Strix vs Spot" if has_any_spot else "sgrk vs Strix"
    title = f"{cat} Benchmark Summary: {tool_list}"
    svg = render_table_svg(title, headers, rows, col_aligns)

    out_path = os.path.join(results_dir, "summary.svg")
    with open(out_path, 'w') as f:
        f.write(svg)


def generate_slideshow(all_slides, results_base_dir, slideshow_name="slideshow.html"):
    """Generate an HTML slideshow from all SVG slides."""
    slides_js = []
    for s in all_slides:
        is_summary = "true" if s['summary'] else "false"
        slides_js.append(
            f'  {{ category: "{s["category"]}", '
            f'name: "{s["name"]}", '
            f'file: "{s["file"]}", '
            f'summary: {is_summary} }}'
        )
    slides_json = ",\n".join(slides_js)

    html = f'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>sgrk vs Strix vs Spot — Benchmark Results</title>
<style>
  * {{ margin: 0; padding: 0; box-sizing: border-box; }}
  body {{
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
    background: #1a1a2e;
    color: #eee;
    height: 100vh;
    display: flex;
    flex-direction: column;
  }}
  header {{
    padding: 18px 32px;
    background: #16213e;
    display: flex;
    justify-content: space-between;
    align-items: center;
    border-bottom: 2px solid #0f3460;
  }}
  header h1 {{ font-size: 20px; font-weight: 600; }}
  .slide-counter {{ font-size: 14px; color: #8899aa; }}
  .nav-tabs {{
    display: flex;
    gap: 4px;
    padding: 12px 32px;
    background: #16213e;
    border-bottom: 1px solid #0f3460;
    flex-wrap: wrap;
  }}
  .nav-tab {{
    padding: 6px 16px;
    border-radius: 6px;
    cursor: pointer;
    font-size: 13px;
    background: #0f3460;
    color: #8899aa;
    border: none;
    transition: all 0.2s;
  }}
  .nav-tab:hover {{ background: #1a4a8a; color: #fff; }}
  .nav-tab.active {{ background: #e94560; color: #fff; }}
  .nav-tab.is-summary {{ font-weight: 600; }}
  .slide-area {{
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 24px;
    position: relative;
  }}
  .slide-area img {{
    max-width: 90%;
    max-height: 80vh;
    border-radius: 8px;
    box-shadow: 0 8px 32px rgba(0,0,0,0.4);
    background: white;
    padding: 16px;
  }}
  .arrow {{
    position: absolute;
    top: 50%;
    transform: translateY(-50%);
    width: 48px;
    height: 48px;
    border-radius: 50%;
    background: rgba(233,69,96,0.8);
    color: white;
    border: none;
    font-size: 22px;
    cursor: pointer;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: background 0.2s;
  }}
  .arrow:hover {{ background: rgba(233,69,96,1); }}
  .arrow.left {{ left: 16px; }}
  .arrow.right {{ right: 16px; }}
  footer {{
    padding: 10px 32px;
    background: #16213e;
    text-align: center;
    font-size: 12px;
    color: #556;
    border-top: 1px solid #0f3460;
  }}
  .keys {{ color: #667; font-size: 12px; }}
</style>
</head>
<body>
<header>
  <h1>sgrk vs Strix — Benchmark Results</h1>
  <div>
    <span class="slide-counter" id="counter"></span>
    &nbsp;&nbsp;
    <span class="keys">Arrow keys or click to navigate</span>
  </div>
</header>
<div class="nav-tabs" id="tabs"></div>
<div class="slide-area">
  <button class="arrow left" onclick="navigate(-1)">&larr;</button>
  <img id="slide" src="" alt="table">
  <button class="arrow right" onclick="navigate(1)">&rarr;</button>
</div>
<footer>Generated by benchmarks/generate_table_images.py</footer>
<script>
const slides = [
{slides_json}
];
let current = 0;
function showSlide(idx) {{
  current = idx;
  document.getElementById('slide').src = slides[idx].file;
  document.getElementById('counter').textContent = (idx + 1) + ' / ' + slides.length;
  document.querySelectorAll('.nav-tab').forEach(function(tab, i) {{
    tab.classList.toggle('active', i === idx);
  }});
}}
function navigate(dir) {{
  var next = current + dir;
  if (next < 0) next = slides.length - 1;
  if (next >= slides.length) next = 0;
  showSlide(next);
}}
var tabsEl = document.getElementById('tabs');
slides.forEach(function(s, i) {{
  var btn = document.createElement('button');
  btn.className = 'nav-tab' + (s.summary ? ' is-summary' : '');
  btn.textContent = s.category + ': ' + s.name.replace(/_/g, ' ');
  btn.onclick = function() {{ showSlide(i); }};
  tabsEl.appendChild(btn);
}});
document.addEventListener('keydown', function(e) {{
  if (e.key === 'ArrowRight' || e.key === ' ') navigate(1);
  if (e.key === 'ArrowLeft') navigate(-1);
}});
showSlide(0);
</script>
</body>
</html>'''

    out_path = os.path.join(results_base_dir, slideshow_name)
    with open(out_path, 'w') as f:
        f.write(html)
    print(f"  Slideshow: {out_path}")


def main():
    category = sys.argv[1] if len(sys.argv) > 1 else "all"
    slideshow_name = sys.argv[2] if len(sys.argv) > 2 else "slideshow.html"

    if category == "all":
        categories = ["R2R", "R2P", "P2R"]
    else:
        categories = [category]

    # Read timeout from compare_results.sh default (5400)
    timeout = 5400
    results_base_dir = os.path.join(SCRIPT_DIR, "results")
    all_slides = []

    for cat in categories:
        cat_dir = os.path.join(SCRIPT_DIR, cat)
        if not os.path.isdir(cat_dir):
            continue

        results_dir = os.path.join(results_base_dir, cat)
        os.makedirs(results_dir, exist_ok=True)

        family_infos = []
        for family in sorted(os.listdir(cat_dir)):
            family_dir = os.path.join(cat_dir, family)
            if not os.path.isdir(family_dir):
                continue

            result = generate_family_svg(cat, family, family_dir, results_dir, timeout)
            if result:
                for info in result:
                    family_infos.append(info)
                    svg_name = info.get('svg_name', family)
                    print(f"  SVG: {results_dir}/{svg_name}.svg")

        if family_infos:
            generate_summary_svg(cat, family_infos, results_dir, timeout)
            print(f"  SVG summary: {results_dir}/summary.svg")

            # Add summary slide first, then family slides
            all_slides.append({
                'category': cat,
                'name': 'Summary',
                'file': f'{cat}/summary.svg',
                'summary': True,
            })
            for info in family_infos:
                if info.get('is_nk_sub'):
                    svg_name = info['svg_name']
                    slide_name = f"{info['family']} k={info['k_val']}"
                else:
                    svg_name = info['family']
                    slide_name = info['family']
                all_slides.append({
                    'category': cat,
                    'name': slide_name,
                    'file': f'{cat}/{svg_name}.svg',
                    'summary': False,
                })

        print()

    # Generate slideshow with all slides
    if all_slides:
        generate_slideshow(all_slides, results_base_dir, slideshow_name)


if __name__ == '__main__':
    main()
