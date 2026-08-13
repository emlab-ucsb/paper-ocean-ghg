# Builds data/inventories/inventory_intensity_all_models.csv
#
# CO2 intensity per vessel for every inventory in the comparison, as one number
# per model rather than a time series. This is the table behind the intensity
# sentence in the inventory-comparison section, and the companion to
# figures/inventory_intensity_all_models.png.
#
# Run from the project root:  Rscript r/build_inventory_intensity_all_models.R
#
# ------------------------------------------------------------------------------
# Why the rows are built three different ways
#
# The models differ in what fleet count they publish, so a single rule would
# either drop models or compare mismatched spans:
#
#   * Single-total models (STEAM, SEIM, MariTEAM) publish one fleet figure and
#     no per-year series, so the transcribed workbook total is used as-is.
#
#   * Per-year models (ICCT, IMO, OECD) publish a count for each year. Here the
#     mean is taken over the years where BOTH a count and emissions exist,
#     rather than over the workbook's full span. This matters: IMO's vessel
#     count runs 2012-2018 while its emissions cover 2015-2018 only, and the
#     three extra years are its smallest fleets, so averaging over the whole
#     count span inflates the intensity (IMO reads 5.50 kt/vessel on the
#     workbook span against 4.92 on matched years).
#
#   * GFW rows are computed from our own activity summary, on the same
#     mean-per-year basis.
#
# Two supplementary rows make specific comparisons possible:
#
#   * "ICCT (distance-reporting classes)" restricts ICCT to the classes that
#     report distance. ICCT's Unknown class reports CO2 but no distance, so it
#     belongs to neither the numerator nor the denominator of a per-distance
#     intensity; without this restriction the kg/nm comparison against GFW is
#     not like for like.
#
#   * "GFW (AIS, any registry)" restricts our fleet to registry-matched vessels,
#     which is the closest analogue to the registry-anchored fleets the other
#     inventories model, and is the fair row to read against them.
#
# ------------------------------------------------------------------------------
# Inputs
#   data/inventories/all_inventory_data.csv        emissions per model and year
#   data/inventories/inventory_vessel_counts.csv   per-year counts (ICCT/IMO/OECD)
#   data/inventories/icct_gfw_ais_comparison.csv   ICCT distance-reporting subset
#   data/gfw/annual_ais_activity_summary_cheap.csv our own activity, by registry
#
# Fleet totals for the single-total models are transcribed from the
# "Number of vessels" row of Table 2 in comparions_model_table.xlsx; they are
# reported figures from each publication, not values we derive.

suppressMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
})

emissions <- read_csv(
  file.path("data", "inventories", "all_inventory_data.csv"),
  show_col_types = FALSE
)

icct_comparison <- read_csv(
  file.path("data", "inventories", "icct_gfw_ais_comparison.csv"),
  show_col_types = FALSE
)

vessel_counts <- read_csv(
  file.path("data", "inventories", "inventory_vessel_counts.csv"),
  show_col_types = FALSE
) |>
  pivot_longer(-year, names_to = "data_source", values_to = "vessels") |>
  filter(!is.na(vessels))

# ---- models publishing a per-year count: mean over matched years -------------

matched_rows <- c("ICCT", "IMO", "OECD") |>
  lapply(function(source_name) {
    d <- inner_join(
      emissions |> filter(data_source == source_name),
      vessel_counts |> filter(data_source == source_name),
      by = c("data_source", "year")
    )
    tibble(
      data_source = source_name,
      n_total     = round(mean(d$vessels)),
      count_basis = "mean per year (matched)",
      year_from   = min(d$year),
      year_to     = max(d$year),
      kg_nm       = NA_real_,
      mean_mt     = mean(d$emissions_co2_mt)
    )
  }) |>
  bind_rows()

# ---- ICCT restricted to its distance-reporting classes -----------------------

icct_distance_row <- tibble(
  data_source = "ICCT (distance-reporting classes)",
  n_total     = round(mean(icct_comparison$icct_n_vessels_with_distance)),
  count_basis = "mean per year (matched)",
  year_from   = min(icct_comparison$year),
  year_to     = max(icct_comparison$year),
  kg_nm       = round(mean(icct_comparison$icct_intensity_kg_nm), 1),
  mean_mt     = mean(icct_comparison$icct_co2_mt_with_distance)
)

# ---- our own fleet, whole and registry-matched -------------------------------

# n_unique_vessels is counted within each (class, registry, length bin) group,
# so summing it over a year can double-count a vessel whose class changed
# mid-year. Length is a per-vessel attribute, so the length dimension added to
# this extract introduces no further duplication.
activity <- read_csv(
  file.path("data", "gfw", "annual_ais_activity_summary_cheap.csv"),
  show_col_types = FALSE
) |>
  mutate(year = as.integer(year))

gfw_row <- function(d, label) {
  tibble(
    data_source = label,
    n_total     = round(mean(d$vessels)),
    count_basis = "mean per year (matched)",
    year_from   = min(d$year),
    year_to     = max(d$year),
    kg_nm       = round(mean(d$emissions_mt) * 1000 / mean(d$distance_nm), 1),
    mean_mt     = mean(d$emissions_mt)
  )
}

gfw_all <- activity |>
  group_by(year) |>
  summarise(
    emissions_mt = sum(emissions_co2_mt),
    vessels      = sum(n_unique_vessels),
    distance_nm  = sum(distance_travelled_nm),
    .groups = "drop"
  )

gfw_registered <- activity |>
  filter(registry_type != "no_registry") |>
  group_by(year) |>
  summarise(
    emissions_mt = sum(emissions_co2_mt),
    vessels      = sum(n_unique_vessels),
    distance_nm  = sum(distance_travelled_nm),
    .groups = "drop"
  )

# ---- models publishing a single fleet total ----------------------------------

single_total_rows <- tribble(
  ~data_source,             ~n_total, ~count_basis,     ~year_from, ~year_to, ~kg_nm,
  "CAMS-GLOB-SHIP (STEAM)",  376219L, "2015 only",           2015L,   2015L, NA_real_,
  "SEIM",                    109300L, "reported total",      2016L,   2021L, NA_real_,
  "MariTEAM",                 45891L, "2017 only",           2017L,   2017L, NA_real_
) |>
  rowwise() |>
  mutate(
    mean_mt = mean(
      emissions$emissions_co2_mt[
        emissions$data_source == data_source &
          emissions$year >= year_from &
          emissions$year <= year_to
      ]
    )
  ) |>
  ungroup()

# ---- assemble ----------------------------------------------------------------

intensity_table <- bind_rows(
  single_total_rows,
  matched_rows,
  icct_distance_row,
  gfw_row(gfw_all,        "GFW (AIS)"),
  gfw_row(gfw_registered, "GFW (AIS, any registry)")
) |>
  mutate(
    period                  = paste0(year_from, "-", year_to),
    intensity_kt_per_vessel = round(mean_mt / 1e3 / n_total, 2),
    intensity_kg_per_nm     = kg_nm,
    mean_mt                 = round(mean_mt / 1e6, 1)
  ) |>
  select(
    data_source, period, count_basis, n_total, mean_mt,
    intensity_kt_per_vessel, intensity_kg_per_nm
  ) |>
  arrange(desc(intensity_kt_per_vessel))

print(as.data.frame(intensity_table), row.names = FALSE)

out_path <- file.path("data", "inventories", "inventory_intensity_all_models.csv")
write_csv(intensity_table, out_path)
cat("\nwrote:", out_path, "\n")

# Workbook total against the matched-year mean, for the models where they differ
cat("\n--- workbook total vs matched-year mean ---\n")
workbook <- c(ICCT = 252490, IMO = 188046, OECD = 115817)
for (s in names(workbook)) {
  m <- matched_rows$n_total[matched_rows$data_source == s]
  cat(sprintf(
    "%-5s workbook %7d  matched %7d  (%+.1f%%)\n",
    s, workbook[[s]], m, 100 * (m / workbook[[s]] - 1)
  ))
}
