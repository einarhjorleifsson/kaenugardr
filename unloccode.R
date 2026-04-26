# UN/LOCODE -----------------------------------------------------------------------
# Sources:
#   https://en.wikipedia.org/wiki/UN/LOCODE
#   https://unece.org/cefact/codesfortrade/codes_index.html
#   https://opensource.unicc.org/un/unece/uncefact/vocab-locode/-/jobs/artifacts/2025-1/download?job=package-release
#
# Column names are not in the CSVs but are revealed by the XML export (not include):
#   change_indicator, country, location, name, name_ascii, subdivision,
#   function_code, status, date, iata, coordinates, remarks
#
# Function code: 8-character string, each position is the digit/letter if the
# function is present, or "-" if absent:
#   1  Port / harbour capable of receiving sea-going vessels
#   2  Rail terminal
#   3  Road terminal
#   4  Airport
#   5  Postal exchange office
#   6  Inland clearance depot (ICD) / dry port
#   7  Fixed transport functions (e.g. oil pipeline terminal)
#   B  Border crossing function
library(tidyverse)

unlocode_cols <- c("change_indicator", "country", "location", "name",
                   "name_ascii", "subdivision", "function_code", "status",
                   "date", "iata", "coordinates", "remarks")

# Helper: decode function_code into a human-readable comma-separated string
decode_function <- function(code) {
  labels <- c(
    "1" = "port",
    "2" = "rail",
    "3" = "road",
    "4" = "airport",
    "5" = "postal",
    "6" = "icd",
    "7" = "pipeline",
    "B" = "border"
  )
  map_chr(code, \(x) {
    if (is.na(x)) return(NA_character_)
    chars <- str_split_1(x, "")
    active <- chars[chars != "-"]
    paste(labels[active], collapse = ", ")
  })
}

# Helper: parse "4230N 00131E" → decimal degrees
# Format: DDMMH DDDMMH  (lat 4 chars + hemi, space, lon 5 chars + hemi)
parse_coordinates <- function(coord) {
  lat <- str_match(coord, "^(\\d{2})(\\d{2})([NS])")[, 2:4, drop = FALSE]
  lon <- str_match(coord, "([0-9]{3})(\\d{2})([EW])$")[, 2:4, drop = FALSE]
  lat_dd <- (as.numeric(lat[, 1]) + as.numeric(lat[, 2]) / 60) *
              if_else(lat[, 3] == "S", -1, 1)
  lon_dd <- (as.numeric(lon[, 1]) + as.numeric(lon[, 2]) / 60) *
              if_else(lon[, 3] == "W", -1, 1)
  list(lat = lat_dd, lon = lon_dd)
}

unlocode <-
  list.files("UNLOCCODE/csv", pattern = "\\.csv$", full.names = TRUE) |>
  purrr::map(\(f) readr::read_csv(f, col_names = unlocode_cols,
                                  col_types = readr::cols(.default = "c"),
                                  show_col_types = FALSE)) |>
  dplyr::bind_rows() |>
  # drop country-header rows (no location code)
  dplyr::filter(!is.na(location), location != "") |>
  # keep sea ports (function_code position 1 == "1")
  dplyr::filter(stringr::str_sub(function_code, 1, 1) == "1") |>
  dplyr::mutate(
    function_desc = decode_function(function_code),
    .after = function_code
  ) |>
  dplyr::mutate(
    lat = parse_coordinates(coordinates)$lat,
    lon = parse_coordinates(coordinates)$lon,
    .after = coordinates
  )

unlocode |> arrow::write_parquet("unlocode.parquet")
