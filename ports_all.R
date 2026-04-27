# Consolidate all harbour polygon/point sources into a single reference table.
#
# Inputs:
#   ports_iceland_faroe.gpkg    — Iceland & Faroe harbours (einar)
#   havnepolygoner3.gpkg        — NW European harbour polygons (jeppe)
#   ports_emodnet.gpkg          — EmodNet harbour points
#   ports_osm.gpkg              — OpenStreetMap harbour features
#   ports_vmstools.gpkg         — vmstools harbour points
#   ports_gfw_named_anchorages_v2_pipe_v3_202601.gpkg — GFW named anchorages
#   unlocode.parquet            — UN/LOCODE reference (from unloccode.R)
#
# Output: ports_all.gpkg
#   Columns: pid, port, hid, unlocode, source, priority, geom
#
# pid is assigned GLOBALLY across all sources: the same (country, normalised
# name) always maps to the same code regardless of which source it appears in.
#
# `priority` encodes source reliability:  einar=1, jeppe=2, ...; downstream
# users can deduplicate by taking the best row per pid:
#   ports_all |> slice_min(priority, by = pid, with_ties = FALSE)

library(sf)
library(tidyverse)
library(rnaturalearth)
library(stringi)

# -- Shared helpers ------------------------------------------------------------

norm <- function(x) str_remove_all(str_to_upper(stri_trans_general(x, "Latin-ASCII")),
                                   "[^A-Z0-9]")

candidates <- function(x) {
  chars <- str_split_1(x, "")[seq_len(min(nchar(x), 8))]
  n <- length(chars)
  if (n < 3) return(str_pad(paste(chars, collapse = ""), 3, "right", "X"))
  apply(combn(n, 3), 2, \(i) paste(chars[i], collapse = ""))
}

assign_codes <- function(names, taken = character(0)) {
  used <- taken
  map_chr(names, \(x) {
    cands <- candidates(x)
    chosen <- cands[!cands %in% used][1]
    if (is.na(chosen)) chosen <- paste0(str_sub(x, 1, 2), sum(used == str_sub(x, 1, 2)))
    used <<- c(used, chosen)
    chosen
  })
}

# Build pid globally: UN/LOCODE match first, then local acronym fallback.
# Local codes are derived from UNIQUE (country, norm_name) pairs so the same
# port name in the same country always gets the same code, across all sources.
build_pid <- function(df, name_col, country_col, unlocode) {
  df <- df |>
    mutate(.rid = row_number(), name_key = norm(.data[[name_col]])) |>
    left_join(
      unlocode |>
        mutate(name_key = norm(name_ascii)) |>
        select(!!country_col := country, location, name_key),
      by = c(country_col, "name_key"),
      relationship = "many-to-many"
    ) |>
    # retain first UN/LOCODE match if multiple entries share the same norm name
    slice(1, .by = .rid)

  # One local code per unique unmatched (country, norm_name) — not per row
  local_codes <- df |>
    st_drop_geometry() |>
    distinct(.data[[country_col]], name_key, location) |>
    group_by(.data[[country_col]]) |>
    group_modify(\(grp, key) {
      taken     <- grp$location[!is.na(grp$location)]
      unmatched <- is.na(grp$location)
      grp$local <- NA_character_
      grp$local[unmatched] <- assign_codes(grp$name_key[unmatched], taken)
      grp
    }) |>
    ungroup() |>
    select(all_of(country_col), name_key, local)

  df |>
    left_join(local_codes, by = c(country_col, "name_key")) |>
    select(-name_key, -.rid) |>
    mutate(
      pid      = paste0(.data[[country_col]], "-", coalesce(location, local)),
      unlocode = if_else(!is.na(location), "yes", "no")
    ) |>
    select(-location)
}

# Assign ISO alpha-2 country code from geometry centroid (nearest-feature).
# st_make_valid() repairs bad geometries before centroid computation.
add_country <- function(sf_obj) {
  pts <- sf_obj |> st_make_valid() |> st_centroid()
  sf_obj |>
    mutate(
      idx     = st_nearest_feature(pts, countries),
      iso_a2  = countries$iso_a2[idx],
      country = countries$country[idx]
    ) |>
    select(-idx) |>
    mutate(iso_a2 = case_when(
      iso_a2 != "-99" ~ iso_a2,
      country == "Norway" ~ "NO",
      country == "France" ~ "FR",
      .default = iso_a2
    ))
}

# -- Reference data ------------------------------------------------------------

countries <- ne_countries(scale = "medium", returnclass = "sf") |>
  select(iso_a2, country = name)

unlocode <- arrow::read_parquet("unlocode.parquet")

# -- Source priority -----------------------------------------------------------
# einar=1, jeppe=2 are fixed; order among 3–6 TBD.
src_priority <- c(einar = 1L, jeppe = 2L, emodnet = 3L, osm = 4L,
                  vmstools = 5L, gfw = 6L)

# -- 1. einar (Iceland & Faroe) ------------------------------------------------
src_iceland <- read_sf("ports_iceland_faroe.gpkg") |>
  add_country() |>
  mutate(source = "einar") |>
  select(port, hid, source, iso_a2, geom)

# -- 2. jeppe (NW European polygons) ------------------------------------------
# Kode → hid; cast to MULTIPOLYGON for uniform geometry type.
src_havn <- read_sf("havnepolygoner3.gpkg") |>
  rename(port = Landingsplads, hid = Kode) |>
  st_cast("MULTIPOLYGON") |>
  add_country() |>
  mutate(source = "jeppe") |>
  select(port, hid, source, iso_a2, geom)

# -- 3. EmodNet ----------------------------------------------------------------
# Prefer portname over generic port column.
src_emodnet <- read_sf("ports_emodnet.gpkg") |>
  mutate(port = coalesce(portname, port), hid = NA_real_, source = "emodnet") |>
  add_country() |>
  select(port, hid, source, iso_a2, geom)

# -- 4. OSM --------------------------------------------------------------------
src_osm <- read_sf("ports_osm.gpkg") |>
  select(port = name, geom) |>
  filter(!is.na(port)) |>
  add_country() |>
  mutate(hid = NA_real_, source = "osm") |>
  select(port, hid, source, iso_a2, geom)

# -- 5. vmstools ---------------------------------------------------------------
src_vmstools <- read_sf("ports_vmstools.gpkg") |>
  select(port = harbour, geom) |>
  add_country() |>
  mutate(hid = NA_real_, source = "vmstools") |>
  select(port, hid, source, iso_a2, geom)

# -- 6. GFW (Global Fishing Watch named anchorages) ----------------------------
# Buffer each s2 point by 500 m then union within (label, iso3) → one polygon
# per named port. AIS coverage for vessels < 12 m is < 1%.
bb <- st_bbox(c(xmin = -70, ymin = 30, xmax = 55, ymax = 85), crs = 4326)
src_gfw <- read_sf("ports_gfw_named_anchorages_v2_pipe_v3_202601.gpkg") |>
  st_crop(bb) |>
  filter(!is.na(label)) |>
  # Exclude offshore mooring/waiting anchorages:
  # keep dock-flagged cells OR non-dock cells within 2 km of shore.
  # This removes outer-channel waiting areas (e.g. Rotterdam ~11–35 km,
  # Gothenburg ~3–8 km) while retaining harbour-proper footprint.
  filter(dock | (!is.na(distance_from_shore_m) & distance_from_shore_m <= 2000)) |>
  st_transform(3857) |>
  st_buffer(500) |>
  group_by(label, iso3) |>
  summarise(geom = st_union(geom), .groups = "drop") |>
  st_transform(4326) |>
  rename(port = label) |>
  add_country() |>
  mutate(hid = NA_real_, source = "gfw") |>
  select(port, hid, source, iso_a2, geom)

# -- Bind → global pid → priority ---------------------------------------------

ports_all <- bind_rows(
  src_iceland,
  src_havn,
  src_emodnet,
  src_osm,
  src_vmstools,
  src_gfw
) |>
  build_pid("port", "iso_a2", unlocode) |>
  mutate(priority = src_priority[source]) |>
  select(pid, port, hid, unlocode, source, priority, geom)

# sanity check
ports_all |>
  st_drop_geometry() |>
  count(source, unlocode) |>
  print()

write_sf(ports_all, "ports_all.gpkg")

library(leaflet)

src_colors <- c(
  einar    = "#E74C3C",   # red
  jeppe    = "#1A6FBF",   # blue
  emodnet  = "#27AE60",   # green
  osm      = "#E67E22",   # orange
  vmstools = "#8E44AD",   # purple
  gfw      = "#0097A7"    # teal
)

# Inline-styled popup table (no external CSS required in self-contained widget)
make_popup <- function(df) {
  cols <- c("pid", "port", "hid", "unlocode", "source", "priority")
  df   <- df |> st_drop_geometry() |> select(all_of(cols))
  pmap_chr(df, function(...) {
    vals <- list(...)
    rows <- map2_chr(names(vals), vals, \(k, v)
      paste0(
        '<tr>',
        '<td style="padding:3px 10px 3px 2px;color:#666;text-align:right;',
        'white-space:nowrap;font-size:12px;font-family:sans-serif">', k, '</td>',
        '<td style="padding:3px 2px 3px 4px;font-weight:600;font-size:12px;',
        'font-family:sans-serif">',
        if (is.na(v)) '<span style="color:#bbb">NA</span>' else htmltools::htmlEscape(as.character(v)),
        '</td></tr>'
      )
    )
    paste0(
      '<div style="overflow:auto;max-width:280px">',
      '<table style="border-collapse:collapse;border-spacing:0">',
      paste(rows, collapse = ""),
      '</table></div>'
    )
  })
}

m <- leaflet() |>
  addProviderTiles("CartoDB.Positron", group = "CartoDB") |>
  addTiles(group = "OpenStreetMap")

for (src in names(src_colors)) {
  dat <- ports_all |> filter(source == src)
  if (nrow(dat) == 0) next
  col  <- src_colors[[src]]                         # [[ ]] → plain string, not named vector
  pts  <- dat |> filter(st_dimension(geom) == 0)
  poly <- dat |> filter(st_dimension(geom) >  0)

  if (nrow(pts) > 0)
    m <- m |> addCircleMarkers(
      data        = pts,
      radius      = 5, weight = 1,
      color       = col, fillColor = col, fillOpacity = 0.7,
      popup       = make_popup(pts),
      group       = src
    )

  if (nrow(poly) > 0)
    m <- m |> addPolygons(
      data        = poly,
      weight      = 1.5,
      color       = col, fillColor = col, fillOpacity = 0.35,
      popup       = make_popup(poly),
      group       = src
    )
}

m <- m |>
  addLayersControl(
    baseGroups    = c("CartoDB", "OpenStreetMap"),
    overlayGroups = names(src_colors),
    options       = layersControlOptions(collapsed = FALSE)
  ) |>
  addLegend(
    position = "bottomright",
    colors   = unname(src_colors),
    labels   = names(src_colors),
    title    = "Source"
  )

htmlwidgets::saveWidget(m, file = "ports.html", selfcontained = TRUE)
