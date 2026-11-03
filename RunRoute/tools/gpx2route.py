#!/usr/bin/env python3
"""Convert a GPX file into a route for the RunRoute watch app.

    python3 RunRoute/tools/gpx2route.py my_route.gpx
    python3 RunRoute/tools/gpx2route.py my_route.gpx --install

The route is named after the GPX file's own name. --install copies it straight to
the watch's Routes folder, so plug the watch in first. Every point is kept unless
the route has more than the app can hold; then points are thinned as little as it
takes. --tolerance thins a route on purpose.
"""

import argparse
import math
import os
import re
import struct
import sys
import xml.etree.ElementTree as ET

MAX_POINTS = 4000
MAX_NAME = 39
METRES_PER_DEG_LAT = 111320.0
WATCH_APP = "/Volumes/UNA WATCH/Apps/RunRoute"


def local_tag(element):
    return element.tag.split("}")[-1]


def read_gpx(path):
    root = ET.parse(path).getroot()
    name = next((e.text for e in root.iter() if local_tag(e) == "name" and e.text and e.text.strip()), None)
    for tag in ("trkpt", "rtept"):
        points = [(float(e.get("lat")), float(e.get("lon"))) for e in root.iter() if local_tag(e) == tag]
        if points:
            return name, points
    return name, []


def route_name(gpx_name, path):
    """A name that works as a file name and that the watch's fonts can show."""
    raw = gpx_name or os.path.splitext(os.path.basename(path))[0]
    clean = re.sub(r"[^A-Za-z0-9 _-]", "", raw)
    clean = " ".join(clean.split())[:MAX_NAME].strip()
    return clean or "Route"


def to_metres(points):
    lat0 = points[0][0]
    per_lon = METRES_PER_DEG_LAT * math.cos(math.radians(lat0))
    return [((lon - points[0][1]) * per_lon, (lat - lat0) * METRES_PER_DEG_LAT) for lat, lon in points]


def offset(p, a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    length_sq = dx * dx + dy * dy
    t = 0.0 if length_sq == 0 else max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / length_sq))
    return math.hypot(p[0] - a[0] - dx * t, p[1] - a[1] - dy * t)


def simplify(xy, tolerance):
    """Douglas-Peucker: the indexes of the points to keep."""
    keep = {0, len(xy) - 1}
    stack = [(0, len(xy) - 1)]
    while stack:
        first, last = stack.pop()
        worst, worst_at = -1.0, None
        for i in range(first + 1, last):
            d = offset(xy[i], xy[first], xy[last])
            if d > worst:
                worst, worst_at = d, i
        if worst_at is not None and worst > tolerance:
            keep.add(worst_at)
            stack.append((first, worst_at))
            stack.append((worst_at, last))
    return sorted(keep)


def length_of(xy):
    return sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(xy, xy[1:]))


def install(name, data):
    if not os.path.isdir(WATCH_APP):
        sys.exit(f"{WATCH_APP} not found. Plug in the watch, and install RunRoute on it first.")
    folder = os.path.join(WATCH_APP, "Routes")
    os.makedirs(folder, exist_ok=True)
    target = os.path.join(folder, name + ".bin")
    with open(target, "wb") as out:
        out.write(data)
    # macOS can leave these beside new files on the watch's drive.
    for stray in (os.path.join(folder, "._" + name + ".bin"), os.path.join(WATCH_APP, "._Routes")):
        if os.path.exists(stray):
            os.remove(stray)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("gpx")
    parser.add_argument("--install", action="store_true", help="copy the route to the plugged-in watch")
    parser.add_argument("--out", default=".", help="folder for the route file (default: here)")
    parser.add_argument("--tolerance", type=float, default=0.0, help="metres the line may shift (default: keep all)")
    args = parser.parse_args()

    try:
        gpx_name, points = read_gpx(args.gpx)
    except (OSError, ET.ParseError, TypeError, ValueError) as error:
        sys.exit(f"Could not read {args.gpx}: {error}")
    if len(points) < 2:
        sys.exit(f"{args.gpx} has no route: it needs at least 2 track or route points.")

    xy = to_metres(points)
    tolerance = args.tolerance
    keep = simplify(xy, tolerance) if tolerance > 0 else list(range(len(points)))
    while len(keep) > MAX_POINTS:
        tolerance = tolerance * 1.5 if tolerance > 0 else 1.0
        keep = simplify(xy, tolerance)

    data = b"URTE" + struct.pack("<I", len(keep))
    for i in keep:
        lat, lon = points[i]
        data += struct.pack("<ii", round(lat * 1e7), round(lon * 1e7))

    name = route_name(gpx_name, args.gpx)
    if args.install:
        target = install(name, data)
    else:
        target = os.path.join(args.out, name + ".bin")
        with open(target, "wb") as out:
            out.write(data)

    miles = length_of(xy) / 1609.344
    thinned = f"thinned to {len(keep)} (within {tolerance:.1f} m)" if len(keep) < len(points) else "all kept"
    print(f"{target}: {miles:.2f} mi, {len(points)} points, {thinned}")


if __name__ == "__main__":
    main()
