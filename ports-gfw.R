# https://globalfishingwatch.org/data-download/datasets/public-anchorages%3Av20200316
library(tidyverse)
library(sf)
gfw <- read_csv("named_anchorages_v2_pipe_v3_202601.csv")
gfw_sf <- gfw |>
  st_as_sf(coords = c("lon", "lat"),
           crs = 4326)
gfw_sf |> write_sf("ports_gfw_named_anchorages_v2_pipe_v3_202601.gpkg")

