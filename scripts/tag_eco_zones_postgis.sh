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

osmium getid -r -i "${ID_FILE}" -f osm -o "${EXTRACTED_OSM}" "${INPUT_PBF}"

python3 - "$MAPPING_TSV" "$EXTRACTED_OSM" "$CHANGE_OSC" <<'PY'
import csv
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

mapping_path = Path(sys.argv[1])
extracted_path = Path(sys.argv[2])
out_path = Path(sys.argv[3])

zone_map = {}
with mapping_path.open(newline="") as f:
    for row in csv.reader(f, delimiter="|"):
        if len(row) != 2:
            continue
        osm_id, zone_type = row
        if zone_type:
            zone_map[osm_id] = zone_type

tree = ET.parse(extracted_path)
root = tree.getroot()

osc = ET.Element("osmChange", version="0.6", generator="eco_zone_tagger")
modify = ET.SubElement(osc, "modify")

for way in root.findall("way"):
    way_id = way.get("id")
    if way_id not in zone_map:
        continue

    for tag in list(way.findall("tag")):
        if tag.get("k") == "eco_zone":
            way.remove(tag)

    ET.SubElement(way, "tag", k="eco_zone", v=zone_map[way_id])
    modify.append(way)

ET.ElementTree(osc).write(out_path, encoding="utf-8", xml_declaration=True)
PY

osmium apply-changes -o "${OUTPUT_PBF}" "${INPUT_PBF}" "${CHANGE_OSC}"

echo "Tagged PBF written to: ${OUTPUT_PBF}"