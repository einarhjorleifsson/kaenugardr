# kaenugardr — project memory

## Purpose
Consolidates harbour/port data from multiple sources into a single spatial
reference table with consistent identifiers.

## Key files

| File | Description |
|------|-------------|
| `ports_all.R` | Main consolidation script — reads all sources, assigns countries, builds `pid`, writes `ports_all.gpkg` and `ports.html` |
| `unloccode.R` | Reads `UNLOCCODE/csv/*.csv`, filters to sea ports, writes `unlocode.parquet` |
| `ports-kvoti.R` | Pulls Icelandic port list from `mar` DB (`kvoti.stadur`), writes `ports_kvoti.parquet` |
| `ports-iceland-and-faroe.R` | Derives port polygons from STK vessel trails + `ports_kvoti.parquet`, writes `ports_iceland_faroe.gpkg` |
| `ports-emodnet.R` | Fetches from EmodNet WFS (`human_activities/portlocations`), writes `ports_emodnet.gpkg` |
| `ports-osm.R` | Fetches `harbour=*` features from OSM Overpass API (Europe bbox), writes `ports_osm.gpkg` |
| `ports-vmstools.R` | Extracts `harbours` dataset from `vmstools` package, writes `ports_vmstools.gpkg` |
| `havnepolygoner3.gpkg` | NW European harbour polygons — supplied file (WGSFD/Jeppe), no generating script |

## Output schema (`ports_all.gpkg`)

| Column | Type | Description |
|--------|------|-------------|
| `pid` | string | `CC-XXX` — ISO 3166-1 alpha-2 + 3-char location code |
| `port` | string | Port name |
| `hid` | numeric | Source harbour ID (Iceland/Faroe only; `NA` elsewhere) |
| `unlocode` | string | `"yes"` / `"no"` — whether `pid` maps to a UN/LOCODE entry |
| `source` | string | `einar`, `jeppe`, `emodnet`, `osm`, `vmstools` |
| `geom` | geometry | Point or polygon; CRS 4326 |

## Run order

```
unloccode.R                       →  unlocode.parquet
ports-kvoti.R              *      →  ports_kvoti.parquet
ports-iceland-and-faroe.R  *      →  ports_iceland_faroe.gpkg
ports-emodnet.R                   →  ports_emodnet.gpkg
ports-osm.R                       →  ports_osm.gpkg
ports-vmstools.R                  →  ports_vmstools.gpkg
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

### Add GFW anchorage data as a source

Global Fishing Watch publishes a global anchorage dataset (~160,000 points, ~32,000
named ports) derived from AIS vessel-stationary clustering. It is conceptually similar
to the STK-derived Iceland/Faroe layer but uses AIS rather than VMS.

**Caveat:** AIS coverage for small fishing vessels (< 12 m) is very low — less than
1% broadcast AIS — so GFW anchorages would complement rather than replace the
STK-derived polygons. Most useful as cross-validation for larger ports.

**Access via `gfwr` R package** (requires free API token from
https://globalfishingwatch.org/our-apis/tokens):

```r
# Install
install.packages("gfwr", repos = c("https://globalfishingwatch.r-universe.dev",
                                   "https://cran.r-project.org"))
# Add to .Renviron: GFW_TOKEN="your_token_here"

library(gfwr)
library(sf)

bb <- st_bbox(c(xmin = -30, xmax = 0, ymin = 60, ymax = 68), crs = 4326) |>
  st_as_sfc() |>
  st_as_sf()

port_visits <- gfw_event(
  event_type    = "PORT_VISIT",
  start_date    = "2022-01-01",
  end_date      = "2022-12-31",
  region        = bb,
  region_source = "USER_SHAPEFILE",
  confidences   = 4
)

# Extract unique anchorage points
anchorages_gfw <- port_visits |>
  mutate(
    anchorage_id   = map_chr(event_info, "anchorageId", .default = NA),
    anchorage_name = map_chr(event_info, \(x) x$voyage$nextAnchorage$name %||% NA)
  ) |>
  distinct(anchorage_id, anchorage_name, lat, lon) |>
  st_as_sf(coords = c("lon", "lat"), crs = 4326)
```

The full static anchorage database (not just events) can also be downloaded from the
GFW Data Download Portal: https://globalfishingwatch.org/data-download/
