# kaenugardr — project memory

## Purpose
Consolidates harbour/port data from multiple sources into a single spatial
reference table with consistent identifiers.

## Key files

| File | Description |
|------|-------------|
| `ports_all.R` | Main consolidation script — reads all sources, assigns countries, builds unified `pid`, writes `ports_all.gpkg` and `ports.html` |
| `unloccode.R` | Reads `UNLOCCODE/csv/*.csv`, filters to sea ports, writes `unlocode.parquet` |
| `ports-kvoti.R` | Pulls Icelandic port list from `mar` DB (`kvoti.stadur`), writes `ports_kvoti.parquet` |
| `ports-iceland-and-faroe.R` | Derives port polygons from STK vessel trails + `ports_kvoti.parquet`, writes `ports_iceland_faroe.gpkg` |
| `ports-emodnet.R` | Fetches from EmodNet WFS (`human_activities/portlocations`), writes `ports_emodnet.gpkg` |
| `ports-osm.R` | Fetches `harbour=*` features from OSM Overpass API (Europe bbox), writes `ports_osm.gpkg` |
| `ports-vmstools.R` | Extracts `harbours` dataset from `vmstools` package, writes `ports_vmstools.gpkg` |
| `havnepolygoner3.gpkg` | NW European harbour polygons — supplied file (WGSFD/Jeppe), no generating script |
| `ports-gfw.R` | Reads GFW named anchorages CSV, writes `ports_gfw_named_anchorages_v2_pipe_v3_202601.gpkg` |

## Output schema (`ports_all.gpkg`)

| Column | Type | Description |
|--------|------|-------------|
| `pid` | string | `CC-XXX` — ISO 3166-1 alpha-2 + 3-char location code |
| `port` | string | Port name |
| `hid` | numeric | Source harbour ID (Iceland/Faroe only; `NA` elsewhere) |
| `unlocode` | string | `"yes"` / `"no"` — whether `pid` maps to a UN/LOCODE entry |
| `source` | string | `einar`, `jeppe`, `emodnet`, `osm`, `vmstools`, `gfw` |
| `priority` | integer | Source reliability rank (see below); use for deduplication |
| `geom` | geometry | Point or polygon; CRS 4326 |

### pid assignment

`pid` is assigned **globally** across all sources in a single pass after
`bind_rows`. The same `(country, normalised name)` always maps to the same
code regardless of which source it appears in.

- UN/LOCODE match attempted first (normalised name join).
- Local 3-char acronym fallback assigned from unique `(country, norm_name)`
  pairs, so the same port name in the same country gets the same fallback
  code even if it appears in multiple sources.

### Source priority

| Priority | Source | Notes |
|----------|--------|-------|
| 1 | `einar` | STK/VMS-derived polygons (Iceland & Faroe) — most authoritative for the region |
| 2 | `jeppe` | WGSFD NW European harbour polygons |
| 3 | `emodnet` | EmodNet WFS port locations |
| 4 | `osm` | OpenStreetMap `harbour=*` features |
| 5 | `vmstools` | `vmstools` R package harbour dataset |
| 6 | `gfw` | GFW named anchorages (AIS-derived; low coverage for vessels < 12 m) |

Priority 3–6 order is provisional and subject to revision.

All source rows are retained in `ports_all.gpkg`. To get one row per port
(highest-priority source wins):

```r
ports_all |> slice_min(priority, by = pid, with_ties = FALSE)
```

### GFW geometry

GFW data arrives as s2 cell centroids (~0.5 km). In `ports_all.R` these are
converted to polygons: each point is buffered 500 m (matching s2 cell size),
then buffered polygons sharing the same `(label, iso3)` group are unioned →
one polygon per named port. Single-point ports become circles; clusters
merge into the harbour footprint.

## Run order

```
unloccode.R                       →  unlocode.parquet
ports-kvoti.R              *      →  ports_kvoti.parquet
ports-iceland-and-faroe.R  *      →  ports_iceland_faroe.gpkg
ports-emodnet.R                   →  ports_emodnet.gpkg
ports-osm.R                       →  ports_osm.gpkg
ports-vmstools.R                  →  ports_vmstools.gpkg
ports-gfw.R                       →  ports_gfw_named_anchorages_v2_pipe_v3_202601.gpkg
                                           ↓
                           ports_all.R  →  ports_all.gpkg + ports.html
```

`*` requires access to the internal `mar` database (Icelandic Marine Research Institute).

## Git / LFS

- All `*.gpkg` files tracked with Git LFS.
- `*.html`, `*.parquet`, `*.Rproj` are in `.gitignore`.

## Interactive map (ports.html)

- Generated at the end of `ports_all.R` via `mapview`, saved with `htmlwidgets::saveWidget`.
- Not committed to `main`; published to GitHub Pages from the `gh-pages` branch (`docs/index.html`).
- Live at: https://einarhjorleifsson.github.io/kaenugardr/
- To update after regenerating `ports.html`:

```bash
git checkout gh-pages
cp ports.html docs/index.html
git add docs/index.html
git commit -m "Update ports map"
git push origin gh-pages
git checkout main
```

## Potential tasks / future work

### Revisit priority order for sources 3–6

The current ordering (`emodnet=3`, `osm=4`, `vmstools=5`, `gfw=6`) is
provisional. Compare coverage and positional accuracy before finalising.

### Spatial deduplication

The current `pid` harmonisation is name-based. Two ports with different names
but overlapping geometries (e.g. "PORT OF HAMBURG" vs "HAMBURG") will get
different `pid`s. A spatial deduplication pass (e.g. centroid-within-polygon
or nearest-neighbour with distance threshold) could catch these cases.

### GFW anchorage data via API

The static GFW anchorage CSV was downloaded from the GFW Data Download Portal
(https://globalfishingwatch.org/data-download/). Port visit events can also be
queried live via the `gfwr` R package (requires free API token from
https://globalfishingwatch.org/our-apis/tokens):

```r
install.packages("gfwr", repos = c("https://globalfishingwatch.r-universe.dev",
                                   "https://cran.r-project.org"))
# Add to .Renviron: GFW_TOKEN="your_token_here"

library(gfwr); library(sf)
bb <- st_bbox(c(xmin = -30, xmax = 0, ymin = 60, ymax = 68), crs = 4326) |>
  st_as_sfc() |> st_as_sf()
port_visits <- gfw_event(event_type = "PORT_VISIT",
                         start_date = "2022-01-01", end_date = "2022-12-31",
                         region = bb, region_source = "USER_SHAPEFILE",
                         confidences = 4)
```
