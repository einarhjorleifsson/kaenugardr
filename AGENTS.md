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
