# Consolidate all harbour polygon/point sources into a single reference table.
#
# Inputs:
#   ports_iceland_faroe.gpkg    — Iceland & Faroe harbours (einar)
#   havnepolygoner3.gpkg        — NW European harbour polygons (jeppe)
#   maksims                     - NW European harbour polygons (maksims)
#   ports_emodnet.gpkg          — EmodNet harbour points
#   ports_osm.gpkg              — OpenStreetMap harbour features
#   ports_vmstools.gpkg         — vmstools harbour points
#   ports_gfw_named_anchorages_v2_pipe_v3_202601.gpkg — GFW named anchorages
#.  ports_giscoR.gpkg           - gisco ports - has a nice PORT_ID system
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

library(emodnet.wfs)
library(giscoR)
library(osmdata)
library(sf)
sf::sf_use_s2(FALSE)
library(tidyverse)
library(rnaturalearth)
library(stringi)
library(igraph)

# -- Shared helpers ------------------------------------------------------------

norm <- function(x) str_remove_all(str_to_upper(stri_trans_general(x, "Latin-ASCII")),
                                   "[^A-Z0-9]")

# Buffer by a true ground distance.
# EPSG:3857 is a metre only at the equator — its scale factor is sec(latitude) —
# so st_buffer(3857_geometry, 500) yields 500*cos(lat) metres on the ground:
# 213 m in Iceland, 246 m at 60-75N, 112 m above 75N. Every buffered source was
# undersized, GFW's 12,831 polygons worst because they are global. Dividing the
# distance by cos(lat) cancels the scale factor exactly at these distances.
buffer_m <- function(x, dist) {
  x   <- st_transform(x, 4326)
  lat <- suppressWarnings(st_coordinates(st_centroid(st_geometry(x))))[, 2]
  x |> st_transform(3857) |> st_buffer(dist / cos(lat * pi / 180)) |> st_transform(4326)
}

# Ordered 3-letter candidates drawn from the whole name. Previously only the
# first 8 characters were used, which made long names collide needlessly.
candidates <- function(x) {
  chars <- str_split_1(x, "")
  if (length(chars) < 3) return(character(0))
  unique(apply(combn(seq_along(chars), 3), 2, \(i) paste(chars[i], collapse = "")))
}

# Deterministic 3-char code from the name itself, used only once the candidate
# list is exhausted. Scans forward from a name-derived seed to the first free
# code, so it depends on the name rather than on arrival order.
B36 <- c(LETTERS, 0:9)
name_seed <- function(x) sum(utf8ToInt(x) * seq_len(nchar(x)))
hash_code <- function(seed, used) {
  for (k in 0:(36^3 - 1)) {
    h  <- (seed + k) %% (36^3)
    cc <- paste0(B36[h %/% 1296 + 1], B36[(h %/% 36) %% 36 + 1], B36[h %% 36 + 1])
    if (!cc %in% used) return(cc)
  }
  stop("36^3 codes exhausted for a single country")
}

# The old fallback was
#   paste0(str_sub(x, 1, 2), sum(used == str_sub(x, 1, 2)))
# `used` holds THREE-character codes and str_sub(x, 1, 2) is TWO, so the
# equality was never TRUE, the counter never left 0, and every name that ran
# out of candidates in a country received one shared code. That is where
# CN-CH0 (275 unrelated anchorages spanning 2,475 km) and US-US0 came from.
assign_codes <- function(names, taken = character(0)) {
  used <- taken
  map_chr(names, \(x) {
    cands  <- candidates(x)
    chosen <- cands[!cands %in% used][1]
    if (is.na(chosen)) chosen <- hash_code(name_seed(x), used)
    used <<- c(used, chosen)
    chosen
  })
}

# Build pid globally: UN/LOCODE match first, then local acronym fallback.
# Local codes are derived from UNIQUE (country, norm_name) pairs so the same
# port name in the same country always gets the same code, across all sources.
# `locode_col`, when given, holds a UN/LOCODE location that the source already
# knows (gisco does). Those rows take it directly instead of being matched by
# name — matching them by name is what produced FR-FRS for Strasbourg's FRSXB.
build_pid <- function(df, name_col, country_col, unlocode, locode_col = NULL) {
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

  if (!is.null(locode_col) && locode_col %in% names(df)) {
    df <- df |> mutate(location = coalesce(.data[[locode_col]], location))
  }

  # One local code per unique unmatched (country, norm_name) — not per row.
  # arrange() is load-bearing: codes are handed out first-come-first-served, so
  # without it the codes depend on the order the sources happen to arrive in.
  # Measured on the unsorted version: re-ordering the same ports changed 35% of
  # Iceland's derived codes, 64% of Norway's and 52% of Britain's. A pid that
  # moves when a source is re-downloaded cannot be a key anything joins on.
  # ONE row per (country, name_key). The join below is on those two columns, so
  # a (country, name_key) appearing here twice — which happens as soon as two
  # sources disagree about a port's locode — silently fans the feature table
  # out. Prefer a row that carries a real locode; the code is only derived for
  # names that have none.
  local_codes <- df |>
    st_drop_geometry() |>
    distinct(.data[[country_col]], name_key, location) |>
    arrange(.data[[country_col]], name_key, is.na(location)) |>
    distinct(.data[[country_col]], name_key, .keep_all = TRUE) |>
    arrange(.data[[country_col]], name_key) |>
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
    left_join(local_codes, by = c(country_col, "name_key"),
              relationship = "many-to-one") |>
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

# -- Raw data (refresh only) ---------------------------------------------------
# These fetch the upstream sources afresh. NOTHING BELOW READS THEM — every
# src_* block reads a cached file from disk — so they are off by default and
# the assembly runs offline from frozen artifacts. Set REFRESH_SOURCES <- TRUE
# to re-pull, then write the results to their cached files with the per-source
# scripts (ports-gfw.R, ports-giscoR.R, ports-osm.R, ports-emodnet.R,
# ports-vmstools.R). Refreshing and assembling are separate jobs on purpose:
# ports are physical infrastructure and do not change every build.

REFRESH_SOURCES <- FALSE

if (REFRESH_SOURCES) {


  ## -- gfw ----------------------------------------------------------------------
  gfw <- read_csv("named_anchorages_v2_pipe_v3_202601.csv")
  gfw_sf <- gfw |>
    st_as_sf(coords = c("lon", "lat"),
             crs = 4326)
  ## -- emodnet ------------------------------------------------------------------
  wfs_ha <- emodnet_init_wfs_client(service = "human_activities")
  emodnet <- emodnet_get_layers(
    wfs    = wfs_ha,
    layers = "portlocations",
    simplify = TRUE
  )
  ## -- gisco --------------------------------------------------------------------
  gisco <- gisco_get_ports()
  ## -- osm ----------------------------------------------------------------------
  # see: ports-osm.R
  ## -- vmstools -----------------------------------------------------------------
  # Download the VMStools .tar.gz file from GitHub
  # url <- "https://github.com/nielshintzen/vmstools/releases/download/0.77/vmstools_0.77.tar.gz"
  # download.file(url, destfile = "vmstools_0.77.tar.gz", mode = "wb")
  # # Install the library from the downloaded .tar.gz file
  # install.packages("vmstools_0.77.tar.gz", repos = NULL, type = "source")
  library(vmstools)
  data("harbours")
  vmstools <-
    harbours |>
    as_tibble() |>
    mutate(harbour = iconv(harbours$harbour, from = "latin1", to = "UTF-8")) |>
    st_as_sf(coords = c("lon", "lat"),
             crs = 4326)








}

# -- Reference data ------------------------------------------------------------

countries <- ne_countries(scale = "large", returnclass = "sf") |>
  select(iso_a2, country = name)

unlocode <- arrow::read_parquet("unlocode.parquet")

# -- Source priority -----------------------------------------------------------
# ... need words here
src_priority <- c(einar = 1L, gisco = 2L, jeppe = 3L, maksims = 4L, emodnet = 5L, osm = 6L,
                  vmstools = 7L, gfw = 8L, marta = 9L)

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

# -- 3. maksims ----------------------------------------------------------------
# Kode → hid; cast to MULTIPOLYGON for uniform geometry type.
src_maksims <- read_sf("data-raw/maksims/harbours.shp") |>
  rename(port = harbour, hid = locode, geom = geometry) |>
  #st_cast("MULTIPOLYGON") |>
  add_country() |>
  mutate(source = "maksims") |>
  select(port, hid, source, iso_a2, geom)

# -- 3. marta -----------------------------------------------------------------
src_marta <- readxl::read_excel("data-raw/marta/landings_portos_Einer.xlsx") |>
  select(port = nome.pt, lon = longdec, lat = latdec) |>
  drop_na(lon, lat) |>
  st_as_sf(coords = c("lon", "lat"),
           crs = 4326) |>
  buffer_m(500) |>
  group_by(port) |>
  summarise(geometry = st_union(geometry), .groups = "drop") |>
  add_country() |>
  mutate(hid = NA_real_, source = "marta") |>
  select(port, hid, source, iso_a2, geometry)


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

src_gfw <- read_sf("ports_gfw_named_anchorages_v2_pipe_v3_202601.gpkg") |>
  # st_crop(bb) |>
  filter(!is.na(label)) |>
  # Exclude offshore mooring/waiting anchorages:
  # keep dock-flagged cells OR non-dock cells within 2 km of shore.
  # This removes outer-channel waiting areas (e.g. Rotterdam ~11–35 km,
  # Gothenburg ~3–8 km) while retaining harbour-proper footprint.
  filter(dock == TRUE) |> #  | (!is.na(distance_from_shore_m) & distance_from_shore_m <= 2000)) |>
  buffer_m(500) |>
  group_by(label, iso3) |>
  summarise(geom = st_union(geom), .groups = "drop") |>
  rename(port = label) |>
  add_country() |>
  mutate(hid = NA_real_, source = "gfw") |>
  select(port, hid, source, iso_a2, geom)


# -- 7. gisco ------------------------------------------------------------------
# PORT_ID is not a name — it is a UN/LOCODE, <ISO2><LOCODE>, for all 2,440
# features, and 92.5% of them verify against unlocode.parquet. Feeding it to
# build_pid as free text derived an acronym FROM THE CODE: FRSXB -> FR-FRS
# instead of FR-SXB, wrong for 2,425 of 2,440. Split it here, and recover the
# real port name from UN/LOCODE, since the gisco file carries no name column.
src_gisco <- read_sf("ports_giscoR.gpkg") |>
  mutate(
    .ok    = str_detect(PORT_ID, "^[A-Z]{2}[A-Z0-9]{3}$"),
    locode = if_else(.ok, str_sub(PORT_ID, 3, 5), NA_character_),
    .iso   = if_else(.ok, str_sub(PORT_ID, 1, 2), NA_character_)
  ) |>
  left_join(
    unlocode |>
      filter(!is.na(country), !is.na(location)) |>
      transmute(.iso = country, locode = location, .nm = name_ascii) |>
      distinct(.iso, locode, .keep_all = TRUE),
    by = c(".iso", "locode"),
    relationship = "many-to-one"          # fail loudly rather than fan out
  ) |>
  add_country() |>
  mutate(
    iso_a2 = coalesce(.iso, iso_a2),          # trust the code's own country
    port   = coalesce(.nm, PORT_ID),
    hid    = NA_real_,
    source = "gisco"
  ) |>
  select(port, hid, source, iso_a2, locode, geom)

# -- Bind → global pid → priority ---------------------------------------------

n_bound <- sum(nrow(src_iceland), nrow(src_havn), nrow(src_maksims), nrow(src_emodnet),
               nrow(src_osm), nrow(src_vmstools), nrow(src_gfw), nrow(src_gisco),
               nrow(src_marta))

ports_all <- bind_rows(
  src_iceland |> mutate(hid = as.character(hid)),
  src_havn |> mutate(hid = as.character(hid)),
  src_maksims |> mutate(hid = as.character(hid)),
  src_emodnet |> mutate(hid = as.character(hid)),
  src_osm |> mutate(hid = as.character(hid)),
  src_vmstools |> mutate(hid = as.character(hid)),
  src_gfw  |> mutate(hid = as.character(hid)),
  src_gisco |> mutate(hid = as.character(hid)),
  src_marta |> mutate(hid = as.character(hid)) |> rename(geom = geometry)
) |>
  build_pid("port", "iso_a2", unlocode, locode_col = "locode") |>
  mutate(priority = src_priority[source]) |>
  select(pid, port, hid, unlocode, source, priority, geom)

# build_pid only looks codes up; it must never add or drop a feature
stopifnot(nrow(ports_all) == n_bound)

# -- Deduplication: one pid per PHYSICAL port ---------------------------------
# `slice_min(priority, by = pid)` cannot do this, because pid is derived from
# each source's own spelling and one port therefore carries several: Ísafjörður
# is IS-ISA (einar/osm/gfw), IS-ISF (jeppe "Isafjord") and IS-IIS (gisco).
# Measured on the pid-grouped recipe, 3,655 of the 19,943 retained features
# still sat within 300 m of another retained feature, 2,027 of them redundant.
# So cluster on GEOMETRY first, then let `priority` choose inside the cluster.
#
# Nothing is dropped here: pid_src keeps each feature's own code and `pid`
# becomes the cluster's canonical one, which is the key downstream joins on.

CLUSTER_TOL <- 300   # metres between centroids

ports_all <- ports_all |> mutate(.rid = row_number())
gp <- st_transform(st_make_valid(st_geometry(ports_all)), "+proj=cea")
ce <- suppressWarnings(st_coordinates(st_centroid(gp)))

# edges: geometries that touch (GEOS uses an index), plus near centroids (grid)
e_int <- st_intersects(gp)
e_int <- do.call(rbind, imap(e_int, \(v, i) if (length(v)) cbind(i, v) else NULL))

cell <- cbind(floor(ce[, 1] / CLUSTER_TOL), floor(ce[, 2] / CLUSTER_TOL))
idx  <- split(seq_len(nrow(ce)), paste(cell[, 1], cell[, 2]))
e_near <- list()
for (dx in -1:1) for (dy in -1:1) {
  nb <- idx[paste(cell[, 1] + dx, cell[, 2] + dy)]
  for (i in which(!map_lgl(nb, is.null))) for (j in nb[[i]]) {
    if (j > i && sqrt(sum((ce[i, ] - ce[j, ])^2)) <= CLUSTER_TOL)
      e_near[[length(e_near) + 1]] <- c(i, j)
  }
}

self <- cbind(seq_len(nrow(ports_all)), seq_len(nrow(ports_all)))   # keep singletons
gr   <- graph_from_edgelist(rbind(e_int, do.call(rbind, e_near), self),
                            directed = FALSE)
ports_all$cluster <- components(gr)$membership[seq_len(nrow(ports_all))]

# canonical member: best priority, then a real UN/LOCODE, then the largest
# footprint, then the code itself so the choice is reproducible
rep_tbl <- ports_all |>
  st_drop_geometry() |>
  mutate(.area = as.numeric(st_area(gp))) |>
  arrange(cluster, priority, unlocode != "yes", desc(.area), pid) |>
  distinct(cluster, .keep_all = TRUE) |>
  transmute(cluster, .pid_canon = pid, .rep = .rid)

# A pid must name exactly ONE port. Two clusters can still win the same code —
# chiefly the ports whose names normalise to empty (non-Latin scripts stripped
# by [^A-Z0-9]), which collapse to one name_key and so to one code no matter
# how the fallback behaves: 21 Greek and 21 Russian ports shared a single code.
# No name-derived scheme can separate them, so the losers are re-coded from
# their LOCATION, which is the one thing that does distinguish them.
clus <- rep_tbl |>
  left_join(tibble(cluster = ports_all$cluster, x = ce[, 1], y = ce[, 2]) |>
              summarise(x = mean(x), y = mean(y), n = n(), .by = cluster),
            by = "cluster") |>
  mutate(.iso = str_sub(.pid_canon, 1, 2)) |>
  arrange(.pid_canon, desc(n), cluster)

# `taken` holds BARE 3-char codes, because hash_code() returns a bare code.
# Comparing a bare code against full "IS-REY" pids is never TRUE — the same
# namespace mistake as the original assign_codes() fallback.
taken <- split(str_sub(clus$.pid_canon, 4), clus$.iso)
clus <- clus |>
  group_by(.pid_canon) |>
  mutate(.dup = row_number() > 1) |>        # first (largest) cluster keeps the code
  ungroup()

for (i in which(clus$.dup)) {
  iso <- clus$.iso[i]
  cc  <- hash_code(round(clus$x[i]) * 7919 + round(clus$y[i]), taken[[iso]])
  taken[[iso]] <- c(taken[[iso]], cc)
  clus$.pid_canon[i] <- paste0(iso, "-", cc)
}

ports_all <- ports_all |>
  rename(pid_src = pid) |>
  left_join(clus |> select(cluster, .pid_canon, .rep), by = "cluster") |>
  mutate(pid = .pid_canon, canonical = .rid == .rep) |>
  select(pid, pid_src, port, hid, unlocode, source, priority, cluster, canonical, geom)

# sanity check
ports_all |>
  st_drop_geometry() |>
  count(source, unlocode) |>
  print()

cat("features            ", nrow(ports_all), "\n")
cat("distinct pid_src    ", n_distinct(ports_all$pid_src), "\n")
cat("distinct pid (ports)", n_distinct(ports_all$pid), "\n")
stopifnot(!any(is.na(ports_all$pid)),
          n_distinct(ports_all$pid) == n_distinct(ports_all$cluster))

bb <- st_bbox(c(xmin = -73, ymin = 32, xmax = 60, ymax = 85), crs = 4326)
#ports_all <- ports_all |>
#  st_make_valid() |>
#  st_crop(bb)

write_sf(ports_all, "ports_all.gpkg", delete_dsn = TRUE)

# one row per physical port — this is what downstream should join on
ports_all |>
  filter(canonical) |>
  select(pid, port, hid, unlocode, source, priority, geom) |>
  write_sf("ports_dedup.gpkg", delete_dsn = TRUE)

library(leaflet)

src_colors <- c(
  einar    = "#E74C3C",   # red
  jeppe    = "#1A6FBF",   # blue
  maksims = "cyan",
  emodnet  = "#27AE60",   # green
  osm      = "#E67E22",   # orange
  vmstools = "#8E44AD",   # purple
  gfw      = "#0097A7",    # teal
  gisco    = "gold",
  marta    = "red"
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
    baseGroups    = c("OpenStreetMap", "CartoDB"),
    overlayGroups = names(src_colors),
    options       = layersControlOptions(collapsed = FALSE)
  ) |>
  addLegend(
    position = "bottomright",
    colors   = unname(src_colors),
    labels   = names(src_colors),
    title    = "Source"
  )

htmlwidgets::saveWidget(m, file = "kaenugardr.html", selfcontained = TRUE)
