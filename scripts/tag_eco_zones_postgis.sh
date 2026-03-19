#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <input.osm.pbf> <output.osm.pbf> [postgis_container]"
  exit 1
fi

INPUT_PBF="$1"
OUTPUT_PBF="$2"
POSTGIS_CONTAINER="${3:-postgis}"

DB_NAME="${POSTGIS_DB:-osm}"
DB_USER="${POSTGIS_USER:-osm}"

if [[ ! -f "$INPUT_PBF" ]]; then
  echo "Input PBF not found: $INPUT_PBF"
  exit 1
fi

if ! command -v osmium >/dev/null 2>&1; then
  echo "osmium-tool not found. Install osmium-tool or run inside a container that has it."
  exit 1
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

SQL="
WITH joined AS (
  SELECT
    r.osm_id,
    MAX(
      CASE ez.zone_type
        WHEN 'red' THEN 1
        WHEN 'yellow' THEN 2
        WHEN 'green' THEN 3
        ELSE 0
      END
    ) AS zone_rank
  FROM osm_roads r
  JOIN eco_zones ez
    ON ST_Intersects(r.geom, ez.way)
  WHERE r.osm_id > 0
    AND r.highway IS NOT NULL
  GROUP BY r.osm_id
)
SELECT
  osm_id,
  CASE zone_rank
    WHEN 1 THEN 'red'
    WHEN 2 THEN 'yellow'
    WHEN 3 THEN 'green'
    ELSE NULL
  END AS zone_type
FROM joined
WHERE zone_rank > 0;
"

MAPPING_TSV="${TMP_DIR}/eco_zone_mapping.tsv"
ID_FILE="${TMP_DIR}/eco_zone_way.ids"
EXTRACTED_OSM="${TMP_DIR}/eco_zone_ways.osm"
CHANGE_OSC="${TMP_DIR}/eco_zone_changes.osc"

docker exec -i "${POSTGIS_CONTAINER}" \
  psql -U "${DB_USER}" -d "${DB_NAME}" -Atc "${SQL}" > "${MAPPING_TSV}"

if [[ ! -s "${MAPPING_TSV}" ]]; then
  echo "No eco zone intersections found. Output will be identical to input."
  cp "${INPUT_PBF}" "${OUTPUT_PBF}"
  exit 0
fi

awk -F'|' '{print "w"$1}' "${MAPPING_TSV}" > "${ID_FILE}"
TOTAL_WAYS="$(wc -l < "${ID_FILE}" | tr -d '[:space:]')"

osmium getid -r -i "${ID_FILE}" -f osm -o "${EXTRACTED_OSM}" "${INPUT_PBF}"

python3 - "$MAPPING_TSV" "$EXTRACTED_OSM" "$CHANGE_OSC" "$TOTAL_WAYS" <<'PY'
import csv
import sqlite3
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

mapping_path = Path(sys.argv[1])
extracted_path = Path(sys.argv[2])
out_path = Path(sys.argv[3])
total_ways = int(sys.argv[4]) if len(sys.argv) > 4 else 0
db_path = out_path.with_suffix(".sqlite")

def print_progress(processed: int, total: int, label: str) -> None:
    if total <= 0:
        return
    width = 30
    ratio = min(1.0, processed / total)
    filled = int(width * ratio)
    bar = "#" * filled + "-" * (width - filled)
    pct = ratio * 100.0
    sys.stderr.write(f"\r{label}: [{bar}] {pct:6.2f}% ({processed}/{total})")
    sys.stderr.flush()

# Store the mapping on disk to avoid keeping millions of entries in RAM.
conn = sqlite3.connect(db_path)
try:
    conn.execute("PRAGMA synchronous=OFF")
    conn.execute("PRAGMA journal_mode=OFF")
    conn.execute("CREATE TABLE zone_map (osm_id TEXT PRIMARY KEY, zone_type TEXT NOT NULL)")

    with mapping_path.open(newline="") as f:
        rows = []
        loaded_rows = 0
        for row in csv.reader(f, delimiter="|"):
            if len(row) != 2:
                continue
            osm_id, zone_type = row
            if not zone_type:
                continue
            rows.append((osm_id, zone_type))
            loaded_rows += 1
            if loaded_rows % 100000 == 0:
                sys.stderr.write(f"\rLoading mapping rows: {loaded_rows}")
                sys.stderr.flush()
            if len(rows) >= 10000:
                conn.executemany("INSERT OR REPLACE INTO zone_map VALUES (?, ?)", rows)
                rows.clear()
        if rows:
            conn.executemany("INSERT OR REPLACE INTO zone_map VALUES (?, ?)", rows)
    conn.commit()
    sys.stderr.write(f"\rLoading mapping rows: {loaded_rows}\n")

    with out_path.open("w", encoding="utf-8") as out:
        out.write('<?xml version="1.0" encoding="UTF-8"?>\n')
        out.write('<osmChange version="0.6" generator="eco_zone_tagger">\n')
        out.write("  <modify>\n")

        # Stream parse large OSM XML instead of building one big ElementTree.
        processed_ways = 0
        for event, way in ET.iterparse(extracted_path, events=("end",)):
            if way.tag != "way":
                continue
            processed_ways += 1
            if (
                processed_ways == 1
                or processed_ways % 10000 == 0
                or processed_ways == total_ways
            ):
                print_progress(processed_ways, total_ways, "Tagging ways")

            way_id = way.get("id")
            row = conn.execute(
                "SELECT zone_type FROM zone_map WHERE osm_id = ?",
                (way_id,),
            ).fetchone()
            if not row:
                way.clear()
                continue

            zone_type = row[0]
            for tag in list(way.findall("tag")):
                if tag.get("k") == "eco_zone":
                    way.remove(tag)
            ET.SubElement(way, "tag", k="eco_zone", v=zone_type)

            out.write("    ")
            out.write(ET.tostring(way, encoding="unicode"))
            out.write("\n")
            way.clear()

        if total_ways > 0:
            print_progress(total_ways, total_ways, "Tagging ways")
            sys.stderr.write("\n")

        out.write("  </modify>\n")
        out.write("</osmChange>\n")
finally:
    conn.close()
    db_path.unlink(missing_ok=True)
PY

osmium apply-changes -o "${OUTPUT_PBF}" "${INPUT_PBF}" "${CHANGE_OSC}"

echo "Tagged PBF written to: ${OUTPUT_PBF}"
