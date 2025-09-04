#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Sock Ordering App - Availability Writer (manual, reliable)
----------------------------------------------------------
This version does NOT scrape. It writes availability from built-in overrides for ALL styles.
Optionally, it merges data/overrides.json on top so you can tweak without code changes.

Order of precedence (highest last):
  1) Start with everything True for sizes listed in data/catalog.json
  2) Apply BUILTIN_OVERRIDES below (covers all styles)
  3) If data/overrides.json exists, apply those on top (final say)

Outputs: data/availability.json
"""

import json
import os
import datetime
from typing import Dict, List

# --------------------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------------------
REPO_ROOT    = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG_PATH = os.path.join(REPO_ROOT, "data", "catalog.json")
OUT_PATH     = os.path.join(REPO_ROOT, "data", "availability.json")
OVR_PATH     = os.path.join(REPO_ROOT, "data", "overrides.json")

# --------------------------------------------------------------------------------------
# Built-in overrides for ALL styles
# Edit these here, or add/modify data/overrides.json to override without touching code.
# --------------------------------------------------------------------------------------
BUILTIN_OVERRIDES: Dict[str, Dict[str, bool]] = {
    # Per your note: Sapphire is out of Toddler, Small, Medium.
    "sapphire": {
        "I": True, "T": False, "S": False, "M": False, "L": True, "XL": True, "XXL": True
    },

    # You didn’t flag these as out-of-stock, so default them all to True
    "bliss":     {"I": True, "T": True, "S": True, "M": True, "L": True, "XL": True, "XXL": True},
    "onyx":      {"I": True, "T": True, "S": True, "M": True, "L": True, "XL": True, "XXL": True},
    "leopard":   {"I": True, "T": True, "S": True, "M": True, "L": True, "XL": True, "XXL": True},
    "tiger":     {"I": True, "T": True, "S": True, "M": True, "L": True, "XL": True, "XXL": True},
    "blueblack": {"I": True, "T": True, "S": True, "M": True, "L": True, "XL": True, "XXL": True},

    # Styles with limited size sets in your catalog
    "skyblue":   {"T": True, "S": True},
    "purple":    {"M": True},

    # Party bag
    "partybag":  {"ONESIZE": True},
}

# --------------------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------------------
def load_json(path: str):
    with open(path, "r") as f:
        return json.load(f)

def merge_overrides(base: Dict[str, Dict[str, bool]], extra: Dict[str, Dict[str, bool]]) -> None:
    """
    In-place merge: base[style][size] = extra value when provided.
    """
    for style_id, size_map in extra.items():
        if style_id not in base:
            base[style_id] = {}
        for sz, val in size_map.items():
            base[style_id][sz] = bool(val)

# --------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------
def main():
    # Load catalog to know which styles and sizes exist in the app
    catalog = load_json(CATALOG_PATH)
    styles = catalog.get("styles", [])

    # Start: everything True for sizes present in catalog
    availability: Dict[str, Dict[str, bool]] = {}
    for st in styles:
        style_id = st["id"]
        szs: List[str] = st.get("sizes", [])
        availability[style_id] = {s: True for s in szs}

    # Apply built-in overrides for ALL styles (your ground truth today)
    merge_overrides(availability, BUILTIN_OVERRIDES)

    # If data/overrides.json exists, apply that on top (easy tweaks via GitHub UI)
    if os.path.exists(OVR_PATH):
        try:
            with open(OVR_PATH, "r") as f:
                file_overrides = json.load(f)
            merge_overrides(availability, file_overrides)
        except Exception:
            # If the overrides.json is malformed, ignore it silently
            pass

    out = {
        "updatedAt": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "styles": availability
    }

    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    with open(OUT_PATH, "w") as f:
        json.dump(out, f, indent=2)

    print("Wrote", OUT_PATH)

if __name__ == "__main__":
    main()
