# Custom fork of Valhalla Routing Engine

The main change of this fork is that it can handle eco zone tags on edges in the same way as hight, width and weight limitations.

## Setup
To get this running you need a PBF file where roads are alrady tagged with the eco zones.
How to get this is described next.

### Eco zone tagging from PostGIS (pre-tagging ways before building tiles)

If your eco zones exist only as polygons in PostGIS, tag the OSM ways before building Valhalla tiles:

1. ```bash
   sudo apt install osmium-tool
   ```

2. ```bash
   mkdir custom_files
   ```

3. You need a docker container with PostGIS to be running (start the containter from MiMa and make sure the osm data is already imported)

4. Export a tagged PBF (adds `eco_zone=red|yellow|green` to ways intersecting `eco_zones` polygons):

   ```bash
   sudo bash scripts/tag_eco_zones_postgis.sh ../MiMa/backend/data/berlin.osm.pbf custom_files/berlin_eco.osm.pbf postgis
   ```

   This uses:
   - PostGIS container `postgis` (override via third arg)
   - DB `osm` and user `osm` (override via `POSTGIS_DB` / `POSTGIS_USER`)

5. Use the tagged PBF for tile building (remove old pbf file from custom files).


### Build and start this custom Valhalla instance

1. ```bash
   git submodule update --init --recursive third_party/
   ```
2. Raspberry Pi
   ```bash
   docker compose build --build-arg CONCURRENCY=1 valhalla-base
   ```
   PC
   ```bash
   docker compose build valhalla-base
   ```
3. Raspberry Pi
   ```bash
   docker compose build --build-arg CONCURRENCY=1 valhalla
   ```
   PC
   ```bash
   docker compose build valhalla
   ```
4. ```bash
   docker compose up valhalla
   ```


