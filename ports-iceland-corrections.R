# Reviewed corrections to the frozen Iceland/Faroe harbour artifact.
#
# ports-iceland-and-faroe.R is a one-time bootstrap and cannot be re-run: its
# input (data-raw/ais/stk/stk_trail) is not in this repo, and re-deriving the
# polygons from STK would re-close the circle described in that script's header.
# So corrections are applied HERE, to the artifact, declaratively and in the
# open, and this script is re-runnable and idempotent.
#
# Input / output: ports_iceland_faroe.gpkg (edited in place)

library(sf)
library(tidyverse)
sf::sf_use_s2(FALSE)

ports <- read_sf("ports_iceland_faroe.gpkg")
stopifnot(nrow(ports) == 159)

# -- 1. Remove two records that are not harbours -------------------------------
# Hellnar's coordinate pair had been copy-pasted onto the Hellissandur and
# Hnífsdalur rows of ports_add, so all three carried the SAME polygon. One AIS
# ping then matched three harbours and a left join emitted three rows — the
# long-standing "+70 rows" defect (fishydata decision 004).
#
# They are removed rather than re-pointed. Neither is a proper harbour: their
# codes in the landings and logbook databases (41, 71) denote where the fish was
# PROCESSED, not where a vessel berthed. That is also why STK never flagged them
# and why they had to be hand-added. Hnífsdalur's 4,982 logbook arrivals run
# 1975-1993 and then stop — a processing plant's lifetime, not a harbour's.
# Giving them geometry would invent harbours that do not exist; they belong in
# the harbour-code crosswalk typed as landing places.
drop_pid <- c("IS-HLS",   # Hellissandur, hid 41
              "IS-HDL")   # Hnífsdalur,   hid 71

# -- 2. Restore the intended 500 m radius --------------------------------------
# The hand-added ports were buffered in EPSG:3857, whose unit is a metre only at
# the equator (scale factor sec(lat)), so they came out at 500*cos(lat) = 203-224 m.
# EPSG:3057 is metres over Iceland, so the buffer is exact there.
rebuffer_pid <- c("IS-VIK", "IS-HLL", "IS-ALV", "IS-OGV")
BUFFER_M <- 500

ports <- ports |> filter(!pid %in% drop_pid)

fixed <- ports |>
  filter(pid %in% rebuffer_pid) |>
  st_transform(3057) |>
  st_centroid() |>
  st_buffer(BUFFER_M) |>
  st_transform(st_crs(ports))

ports <- bind_rows(ports |> filter(!pid %in% rebuffer_pid), fixed) |> arrange(pid)

# -- Checks --------------------------------------------------------------------
stopifnot(
  nrow(ports) == 157,
  !any(duplicated(st_as_text(st_geometry(ports)))),            # no shared geometry
  all(!drop_pid %in% ports$pid),
  all(abs(sqrt(as.numeric(st_area(st_transform(
    ports |> filter(pid %in% rebuffer_pid), 3057))) / pi) - BUFFER_M) < 1)
)

write_sf(ports, "ports_iceland_faroe.gpkg", delete_dsn = TRUE)
cat("ports_iceland_faroe.gpkg:", nrow(ports), "harbours, no duplicated geometry\n")
