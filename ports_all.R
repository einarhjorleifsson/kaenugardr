# Consolidate all harbour polygon/point sources into a single reference table.
#
# Inputs:
#   data/ports/ports.gpkg            — Iceland harbours (einar)
#   data/ports/havn_ports.gpkg       — NW European harbour polygons (jeppe - wgsfd2025)
#   data/ports/ports_emodnet.gpkg    — EmodNet harbour points
#   data/ports/ports_osm.gpkg        — OpenStreetMap harbour features
#   data/ports/ports_vmstools.gpkg   — vmstools harbour points
#   data/ports/unlocode.parquet      — UN/LOCODE ports (from unloccode.R)
#
# Output: data/ports/ports_all.gpkg
#   Columns: pid, port, hid, unlocode, source, geom
#   Geometry: native type preserved; downstream user picks the best shape.

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

# Assign pid for a source that has no existing codes:
# UN/LOCODE match first, then local acronym fallback, per country.
build_pid <- function(df, name_col, country_col, unlocode) {
  df <- df |>
    mutate(.rid = row_number(), name_key = norm(.data[[name_col]])) |>
    left_join(
      unlocode |>
        mutate(name_key = norm(name_ascii)) |>
        select(!!country_col := country, location, name_key),
      by = c(country_col, "name_key")
    ) |>
    select(-name_key)

  local_codes <- df |>
    st_drop_geometry() |>
    group_by(.data[[country_col]]) |>
    group_modify(\(grp, key) {
      taken <- grp$location[!is.na(grp$location)]
      unmatched <- is.na(grp$location)
      grp$local <- NA_character_
      grp$local[unmatched] <- assign_codes(norm(grp[[name_col]][unmatched]), taken)
      grp
    }) |>
    ungroup() |>
    select(.rid, local)

  df |>
    left_join(local_codes, by = ".rid") |>
    select(-.rid) |>
    mutate(
      pid      = paste0(.data[[country_col]], "-", coalesce(location, local)),
      unlocode = if_else(!is.na(location), "yes", "no")
    )
}

# Assign country from coordinates via nearest-feature.
# st_make_valid() repairs invalid geometries (e.g. duplicate edges in OSM data)
# before computing centroids.
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

# -- 1. Iceland (ports.gpkg) ---------------------------------------------------
# Code; pid, port, hid, unlocode already present. Just tag source.

src_iceland <- read_sf("ports.gpkg") |>
  mutate(source = "einar") |>
  select(pid, port, hid, unlocode, source, geom)

# -- 2. havn (NW European polygons) -------------------------------------------
# Kode → hid, Landingsplads → port; cast to MULTIPOLYGON for uniform geometry.

src_havn <- read_sf("havnepolygoner3.gpkg") |>
  rename(port = Landingsplads, hid = Kode) |>
  add_country() |>
  build_pid("port", "iso_a2", unlocode) |>
  mutate(source = "jeppe") |>
  st_cast("MULTIPOLYGON") |>
  select(pid, port, hid, unlocode, source, geom)

# -- 3. EmodNet ----------------------------------------------------------------
# port_id is mostly already in UN/LOCODE concatenated format (CCXXX, 5 chars).
# Split into iso_a2 + location; keep `portname` preferring over generic `port`.

src_emodnet <- read_sf("ports_emodnet.gpkg") |>
  mutate(
    iso_a2   = country,
    # treat 5-char port_id starting with a valid 2-letter prefix as UN/LOCODE
    location = if_else(nchar(port_id) == 5 & !str_detect(port_id, "\\d{3}"),
                       str_sub(port_id, 3, 5), NA_character_),
    port     = coalesce(portname, port),
    local    = if_else(is.na(location), norm(port) |> str_sub(1, 3), NA_character_),
    pid      = paste0(iso_a2, "-", coalesce(location, local)),
    hid      = NA_real_,
    unlocode = if_else(!is.na(location), "yes", "no"),
    source   = "emodnet"
  ) |>
  select(pid, port, hid, unlocode, source, geom)

# -- 4. OSM --------------------------------------------------------------------
# Many columns; keep name + geometry only. Mixed geometry types are preserved.
# Assign country from centroid; build pid via UN/LOCODE match + local fallback.

src_osm <- read_sf("ports_osm.gpkg") |>
  select(osm_id, port = name, geom) |>
  filter(!is.na(port)) |>
  add_country() |>
  build_pid("port", "iso_a2", unlocode) |>
  mutate(hid = NA_real_, source = "osm") |>
  select(pid, port, hid, unlocode, source, geom)

# -- 5. vmstools ---------------------------------------------------------------

src_vmstools <- read_sf("ports_vmstools.gpkg") |>
  select(port = harbour, geom) |>
  add_country() |>
  build_pid("port", "iso_a2", unlocode) |>
  mutate(hid = NA_real_, source = "vmstools") |>
  select(pid, port, hid, unlocode, source, geom)

# -- Bind and write ------------------------------------------------------------

ports_all <- bind_rows(
  src_iceland,
  src_havn,
  src_emodnet,
  src_osm,
  src_vmstools
)

# sanity check
ports_all |>
  st_drop_geometry() |>
  count(source, unlocode) |>
  print()

write_sf(ports_all, "ports_all.gpkg")


library(mapview)
m <- mapview(ports_all, zcol = "source")
htmlwidgets::saveWidget(m@map, file = "ports.html", selfcontained = TRUE)
