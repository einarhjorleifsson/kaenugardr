# kaenugardr

Consolidates harbour/port data from multiple sources into a single spatial reference table (`ports_all.gpkg`) with consistent identifiers.

------------------------------------------------------------------------

## Output schema

`ports_all.gpkg` — one feature per port, geometry type preserved from source.

| Column | Type | Description |
|----|----|----|
| `pid` | string | Primary identifier: `CC-XXX` (ISO 3166-1 alpha-2 + 3-char code) |
| `port` | string | Port name |
| `hid` | numeric | Source-specific harbour ID (Iceland/Faroe only; `NA` elsewhere) |
| `unlocode` | string | `"yes"` if `pid` maps to a UN/LOCODE entry, `"no"` otherwise |
| `source` | string | Origin: `einar`, `jeppe`, `emodnet`, `osm`, `vmstools` |
| `geom` | geometry | Point or polygon; CRS 4326 |

------------------------------------------------------------------------

## Pipeline

Scripts must be run in order. Steps 1–3 depend on non-public data sources (internal databases or supplied files) and cannot be reproduced externally.

```         
unloccode.R                      →  unlocode.parquet
ports-kvoti.R             *      →  ports_kvoti.parquet
ports-iceland-and-faroe.R *      →  ports_iceland_faroe.gpkg
ports-emodnet.R                  →  ports_emodnet.gpkg
ports-osm.R                      →  ports_osm.gpkg
ports-vmstools.R                 →  ports_vmstools.gpkg
havnepolygoner3.gpkg      *      (supplied — WGSFD/Jeppe)
                                          ↓
                          ports_all.R  →  ports_all.gpkg
```

`*` = depends on a non-public data source; not reproducible externally.

### Step-by-step

| Script | Source | Notes |
|----|----|----|
| `unloccode.R` | `UNLOCCODE/csv/*.csv` | Reads the UN/LOCODE release CSVs; filters to sea ports (function code `1`); parses DDMM coordinates to decimal degrees. |
| `ports-kvoti.R` | `mar` DB — `kvoti.stadur` | Official Icelandic port list with numeric harbour IDs (`stad_nr`). Requires internal database access. |
| `ports-iceland-and-faroe.R` | `mar` DB — STK vessel trail data + `ports_kvoti.parquet` | Derives port polygons from vessel mooring clusters; merges with a manually curated Faroe Islands table. Writes `ports_iceland_faroe.gpkg`. Requires internal database access. |
| `ports-emodnet.R` | EmodNet WFS (`human_activities/portlocations`) | Public API; reproducible. |
| `ports-osm.R` | OpenStreetMap Overpass API | Fetches all `harbour=*` features in a European bounding box (≈ 50°W–45°E, 34–72°N); reproducible but slow. |
| `ports-vmstools.R` | `vmstools` R package `harbours` dataset | Reproducible once the package is installed (see below). |
| `ports_all.R` | All `.gpkg` files above + `unlocode.parquet` | Assigns country codes via nearest-feature lookup; matches UN/LOCODE by normalised name; generates local 3-char fallback codes for unmatched ports; writes `ports_all.gpkg`. |

### `pid` construction

For sources without pre-assigned codes, `ports_all.R`:

1.  Normalises port names to uppercase ASCII, strips non-alphanumerics.
2.  Joins against UN/LOCODE by `(country, normalised_name)`.
3.  For unmatched ports, generates a 3-character code as the lexicographically first combination of 3 characters from the first 8 of the normalised name that is not already in use within that country.
4.  Assembles `pid` as `CC-XXX`.

------------------------------------------------------------------------

## Dependencies

``` r
# CRAN
install.packages(c("sf", "tidyverse", "rnaturalearth", "arrow",
                   "stringi", "osmdata", "emodnet.wfs", "nanoparquet"))

# vmstools (GitHub/manual install)
# https://github.com/nielshintzen/vmstools
install.packages("vmstools_0.77.tar.gz", repos = NULL, type = "source")

# mar (internal — Icelandic Marine Research Institute)
# Not publicly available; steps using it cannot be reproduced externally.
```

------------------------------------------------------------------------

## Large files (Git LFS)

All `*.gpkg` files are tracked with Git LFS. Run `git lfs pull` after cloning to materialise them locally.

------------------------------------------------------------------------

## Interactive map (ports.html)

`ports.html` is a self-contained Mapview widget colouring ports by source. It is excluded from the repository (`.gitignore`) because of its size (\~3 MB).

### Viewing the latest map

The map is published as a GitHub Page from the `gh-pages` branch:
[`https://einarhjorleifsson.github.io/kaenugardr/`](https://einarhjorleifsson.github.io/kaenugardr/)

### Updating the map

After regenerating `ports.html` locally (last step of `ports_all.R`):

``` bash
# From repo root — run once to set up the orphan branch:
git checkout --orphan gh-pages
git rm -rf .
cp ports.html index.html
git add index.html
git commit -m "Deploy ports map"
git push origin gh-pages
git checkout main
```

For subsequent updates (the branch already exists):

``` bash
git checkout gh-pages
cp /path/to/ports.html index.html
git add index.html
git commit -m "Update ports map"
git push origin gh-pages
git checkout main
```

Then enable GitHub Pages in the repository settings: **Settings → Pages → Source → Deploy from branch → `gh-pages` / `/ (root)`**.
