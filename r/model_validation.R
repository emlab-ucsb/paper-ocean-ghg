# Model validation

# Setup ----
library(tidyverse)
library(RColorBrewer)
library(bigrquery)

source("r/functions.R")

bq_dataset <- "proj_ocean_ghg"
bq_project <- "world-fishing-827"
billing_project <- "emlab-gcp"

data_directory_base <- ifelse(
  Sys.info()["nodename"] == "quebracho" | Sys.info()["nodename"] == "sequoia",
  "/home/emlab",
  # Otherwise, set the directory for local machines based on the OS
  # If using Mac OS, the directory will be automatically set as follows
  ifelse(
    Sys.info()["sysname"] == "Darwin",
    "/Users/Shared/nextcloud/emLab",
    # If using Windows, the directory will be automatically set as follows
    ifelse(
      Sys.info()["sysname"] == "Windows",
      "G:/Shared\ drives/nextcloud/emLab",
      # If using Linux, will need to manually modify the following directory path based on their user name
      # Replace your_username with your local machine user name
      "/home/your_username/Nextcloud"
    )
  )
)

project_directory <- glue::glue(
  "{data_directory_base}/projects/current-projects/paper-ocean-ghg"
)

# Registered data validation ----

## Pull and read data ----

# Pull latest registered fuel consumption data from BQ

# Pull dataset as it is:
# pull_gfw_data_locally(
#   bq_table_name = "snp_fuel_consumption_v20250607",
#   bq_dataset,
#   billing_project
# ) |>
#   readr::write_csv(glue::glue(
#     "{project_directory}/data/raw/registered_fuel_consumption_v20250607.csv"
#   ))

# Pull dataset and normalize IMO and ship name:
query <- "
SELECT
  *,
  `world-fishing-827.udfs.normalize_imo`(CAST(imo AS STRING)) AS imo_normalized,
  `world-fishing-827.udfs.normalize_shipname`(ship_name) AS ship_name_normalized
FROM
  `world-fishing-827.proj_ocean_ghg.snp_fuel_consumption_v20250607`
"

# run_custom_bq_query(
#   query = query,
#   billing_project = billing_project
# ) |>
#   readr::write_csv(glue::glue(
#     "{project_directory}/data/raw/registered_fuel_consumption_v20250607.csv"
#   ))

registered_fuel_consumption <- readr::read_csv(glue::glue(
  "{project_directory}/data/raw/registered_fuel_consumption_v20250607.csv"
))

registered_fuel_consumption_renamed <- registered_fuel_consumption |>
  rename_with(~ paste0(., "_registered"), .cols = -imo_normalized)

# Pull latest vessel info data from BQ

# Pull dataset as it is:
# pull_gfw_data_locally(
#   bq_table_name = "vessel_info_v20250701",
#   bq_dataset,
#   billing_project
# ) |>
#   readr::write_csv(glue::glue(
#     "{project_directory}/data/raw/vessel_info_v20250701.csv"
#   ))

# Pull dataset and normalize IMO and ship name:
query <- "
SELECT
  *,
  `world-fishing-827.udfs.normalize_imo`(CAST(imo_registry AS STRING)) AS imo_registry_normalized,
  `world-fishing-827.udfs.normalize_imo`(CAST(imo_ais AS STRING)) AS imo_ais_normalized,
  `world-fishing-827.udfs.normalize_shipname`(ship_name_registry) AS ship_name_registry_normalized,
  `world-fishing-827.udfs.normalize_shipname`(ship_name_ais) AS ship_name_ais_normalized

FROM
  `world-fishing-827.proj_ocean_ghg.vessel_info_v20250701`
"

# run_custom_bq_query(
#   query = query,
#   billing_project = billing_project
# ) |>
#   readr::write_csv(glue::glue(
#     "{project_directory}/data/raw/vessel_info_v20250701.csv"
#   ))

vessel_info <- readr::read_csv(glue::glue(
  "{project_directory}/data/raw/vessel_info_v20250701.csv"
))


## Match vessel info with registered data ----

# Matching priority order:
#   1. Matches by IMO, MMSI, and Name (all three)
#   2. Matches by IMO and MMSI
#   3. Matches by IMO and Name
#   4. Matches by MMSI and Name
#   5. Matches by IMO only
#   6. Matches by MMSI only
#   7. Matches by Name only

# 1. Match on all three keys
match_all <- vessel_info |>
  inner_join(
    registered_fuel_consumption_renamed,
    by = c(
      "imo_ais_normalized" = "imo_normalized",
      "ssvid" = "mmsi_registered",
      "ship_name_ais_normalized" = "ship_name_registered"
    )
  ) |>
  mutate(match_type = "imo_mmsi_name")

# Remove matched from pool
remaining <- vessel_info |>
  anti_join(match_all, by = "ssvid")

# 2. Match on IMO + MMSI
match_imo_mmsi <- vessel_info |>
  inner_join(
    registered_fuel_consumption_renamed,
    by = c("imo_ais_normalized" = "imo_normalized", "ssvid" = "mmsi_registered")
  ) |>
  mutate(match_type = "imo_mmsi")

remaining <- remaining |> anti_join(match_imo_mmsi, by = "ssvid")

# 3. Match on IMO + Name
# match_imo_name <- remaining |>
#   inner_join(
#     registered_fuel_consumption_renamed,
#     by = c(
#       "imo_ais_normalized" = "imo_normalized",
#       "ship_name_ais_normalized" = "ship_name_registered"
#     )
#   ) |>
#   mutate(match_type = "imo_name")

# remaining <- remaining |> anti_join(match_imo_name, by = "ssvid")

# 4. Match on MMSI + Name
match_mmsi_name <- remaining |>
  inner_join(
    registered_fuel_consumption_renamed,
    by = c(
      "ssvid" = "mmsi_registered",
      "ship_name_ais_normalized" = "ship_name_registered"
    )
  ) |>
  mutate(match_type = "mmsi_name")

remaining <- remaining |> anti_join(match_mmsi_name, by = "ssvid")

# # 5. Match on IMO only (non-repeated)
# repeated_imo_ais <- vessel_info |>
#   count(imo_ais_normalized) |>
#   filter(n > 1) |>
#   pull(imo_ais_normalized)

# match_imo <- remaining |>
#   filter(!imo_ais_normalized %in% repeated_imo_ais) |>
#   inner_join(
#     registered_fuel_consumption_renamed,
#     by = c("imo_ais_normalized" = "imo_normalized")
#   ) |>
#   mutate(match_type = "imo")

# remaining <- remaining |> anti_join(match_imo, by = "ssvid")

# # 6. Match on MMSI only
# match_mmsi <- remaining |>
#   inner_join(
#     registered_fuel_consumption_renamed,
#     by = c("ssvid" = "mmsi_registered")
#   ) |>
#   mutate(match_type = "mmsi")

# remaining <- remaining |> anti_join(match_mmsi, by = "ssvid")

# # 7. Match on Name only (non-repeated)
# repeated_names <- vessel_info |>
#   count(ship_name_ais_normalized) |>
#   filter(n > 1) |>
#   pull(ship_name_ais_normalized)

# repeated_names_registered <- registered_fuel_consumption_renamed |>
#   count(ship_name_registered) |>
#   filter(n > 1) |>
#   pull(ship_name_registered)

# match_name <- remaining |>
#   filter(
#     !ship_name_ais_normalized %in% c(repeated_names, repeated_names_registered)
#   ) |>
#   inner_join(
#     registered_fuel_consumption_renamed,
#     by = c("ship_name_ais_normalized" = "ship_name_registered")
#   ) |>
#   mutate(match_type = "name")

# Final combined matched table
vessel_info_combined <- bind_rows(
  # match_all,
  match_imo_mmsi,
  # match_imo_name,
  # match_mmsi_name,
  # match_imo,
  # match_mmsi,
  # match_name
)

## Define main engine model ----
# We could alternatively do this within BQ using vessel_info_snp_match_extended.sql,
# results have been checked to be the same.

hull_fouling_correction_factor <- 1.07
draft_correction_factor <- 0.85

## Weather factor is dependant on distance from shore
## Since we don't have such information we'll set this factor for offshore navigation
assign_weather_correction <- function(distance_from_shore_m) {
  ifelse(distance_from_shore_m > 5 * 1852, 1.15, 1.1)
}
weather_correction_factor <- assign_weather_correction(10000)

calculate_main_engine_energy_use_kwh <- function(
  vessel_class,
  fishing,
  on_fishing_list_best,
  hours = 24,
  main_engine_power_kw,
  speed_knots,
  design_speed_knots,
  hull_fouling_correction_factor,
  weather_correction_factor,
  draft_correction_factor
) {
  power_factor <- ifelse(
    vessel_class %in% c("trawlers", "dredge_fishing") & fishing,
    0.75,
    ifelse(
      on_fishing_list_best,
      pmax(
        pmin(
          (pmin(speed_knots / design_speed_knots, 1))^3 *
            hull_fouling_correction_factor *
            weather_correction_factor *
            draft_correction_factor,
          0.9
        ),
        0.2
      ),
      pmin(
        (pmin(speed_knots / design_speed_knots, 1))^3 *
          hull_fouling_correction_factor *
          weather_correction_factor *
          draft_correction_factor,
        0.98
      )
    )
  )

  return(hours * power_factor * main_engine_power_kw)
}


## Calculate energy use ----
## Apply function to each row
vessel_info_energy_use <- vessel_info_combined |>
  mutate(
    # Original:
    main_engine_energy_use_original = calculate_main_engine_energy_use_kwh(
      vessel_class,
      FALSE,
      on_fishing_list_best,
      24,
      imo_table_81_avg_main_engine_power_kw, # Using previous power estimates from IMO report table # Use main_engine_power_kw_old when testing vessel_info_v20241121
      consumption_speed_1_registered,
      imo_table_81_avg_design_speed_knots, # Using previous speed estimates from IMO report table # Use design_speed_knots_old when testing vessel_info_v20241121
      hull_fouling_correction_factor,
      weather_correction_factor,
      draft_correction_factor
    ),
    # RF engine power:
    main_engine_energy_use_rf_kw = calculate_main_engine_energy_use_kwh(
      vessel_class,
      FALSE,
      on_fishing_list_best,
      24,
      main_engine_power_kw, # Using new power estimates from RF model
      consumption_speed_1_registered,
      imo_table_81_avg_design_speed_knots, # Using previous speed estimates from IMO report table # Use design_speed_knots_old when testing vessel_info_v20241121
      hull_fouling_correction_factor,
      weather_correction_factor,
      draft_correction_factor
    ),
    # RF design speed:
    main_engine_energy_use_rf_kn = calculate_main_engine_energy_use_kwh(
      vessel_class,
      FALSE,
      on_fishing_list_best,
      24,
      imo_table_81_avg_main_engine_power_kw, # Using previous power estimates from IMO report table # Use main_engine_power_kw_old when testing vessel_info_v20241121
      consumption_speed_1_registered,
      design_speed_knots, # Using new speed estimates from RF model
      hull_fouling_correction_factor,
      weather_correction_factor,
      draft_correction_factor
    ),
    # RF engine power and design speed:
    main_engine_energy_use_rf_kw_kn = calculate_main_engine_energy_use_kwh(
      vessel_class,
      FALSE,
      on_fishing_list_best,
      24,
      main_engine_power_kw, # Using new power estimates from RF model
      consumption_speed_1_registered,
      design_speed_knots, # Using new speed estimates from RF model
      hull_fouling_correction_factor,
      weather_correction_factor,
      draft_correction_factor
    ),
    # Registered estimates:
    main_engine_energy_use_registered = calculate_main_engine_energy_use_kwh(
      vessel_class,
      FALSE,
      on_fishing_list_best,
      24,
      engine_power_registered,
      consumption_speed_1_registered,
      max_speed_registered,
      hull_fouling_correction_factor,
      weather_correction_factor,
      draft_correction_factor
    )
  )

## Calculate emissions ----
co2_ef <- 629.83333 # g pollutant / kwh
co2_fuel_factor <- 3.12 # tonnes pollutant/tonne fuel

vessel_info_emissions <- vessel_info_energy_use |>
  mutate(
    co2_emissions_tonnes_estimate_original = (main_engine_energy_use_original *
      co2_ef) /
      1e6,
    co2_emissions_tonnes_estimate_rf_kw = (main_engine_energy_use_rf_kw *
      co2_ef) /
      1e6,
    co2_emissions_tonnes_estimate_rf_kn = (main_engine_energy_use_rf_kn *
      co2_ef) /
      1e6,
    co2_emissions_tonnes_estimate_rf_kw_kn = (main_engine_energy_use_rf_kw_kn *
      co2_ef) /
      1e6,
    co2_emissions_tonnes_estimate_registered = (main_engine_energy_use_registered *
      co2_ef) /
      1e6,
    co2_emissions_tonnes_registered = consumption_value_1_registered *
      co2_fuel_factor
  )

## Assess model performance ----
multi_metric <- yardstick::metric_set(
  yardstick::rsq,
  yardstick::rsq_trad
)

bind_rows(
  vessel_info_emissions |>
    multi_metric(
      truth = co2_emissions_tonnes_registered,
      estimate = co2_emissions_tonnes_estimate_original
    ) |>
    mutate(metadata = "Original"),

  vessel_info_emissions |>
    multi_metric(
      truth = co2_emissions_tonnes_registered,
      estimate = co2_emissions_tonnes_estimate_rf_kn
    ) |>
    mutate(metadata = "RF design speed"),

  vessel_info_emissions |>
    multi_metric(
      truth = co2_emissions_tonnes_registered,
      estimate = co2_emissions_tonnes_estimate_rf_kw
    ) |>
    mutate(metadata = "RF engine power"),

  vessel_info_emissions |>
    multi_metric(
      truth = co2_emissions_tonnes_registered,
      estimate = co2_emissions_tonnes_estimate_rf_kw_kn
    ) |>
    mutate(metadata = "RF engine power and design speed"),

  vessel_info_emissions |>
    multi_metric(
      truth = co2_emissions_tonnes_registered,
      estimate = co2_emissions_tonnes_estimate_registered
    ) |>
    mutate(metadata = "Registered data")
) |>
  select(metadata, .metric, .estimate) |>
  pivot_wider(names_from = .metric, values_from = .estimate) |>
  kableExtra::kable(digits = 3)


# Plot
# Define model order
model_levels <- c(
  "IMO report lookup table",
  "RF engine power",
  "RF design speed",
  "New engine power and\n design speed data",
  "Registered data"
)

# Reshape and apply factor levels
vessel_long <- vessel_info_emissions |>
  dplyr::select(
    co2_emissions_tonnes_registered,
    # match_type,
    `IMO report lookup table` = co2_emissions_tonnes_estimate_original,
    `RF design speed` = co2_emissions_tonnes_estimate_rf_kn,
    `RF engine power` = co2_emissions_tonnes_estimate_rf_kw,
    `RF engine power and design speed` = co2_emissions_tonnes_estimate_rf_kw_kn,
    `Registered data` = co2_emissions_tonnes_estimate_registered
  ) |>
  pivot_longer(
    cols = -c(
      co2_emissions_tonnes_registered,
      # match_type
    ),
    names_to = "Model",
    values_to = "Estimate"
  ) |>
  mutate(
    Model = recode(
      Model,
      "RF engine power and design speed" = "New engine power and\n design speed data"
    )
  ) |>
  mutate(Model = factor(Model, levels = model_levels))

r2_labels <- vessel_long |>
  group_by(
    # match_type,
    Model
  ) |>
  yardstick::rsq_trad(
    truth = co2_emissions_tonnes_registered,
    estimate = Estimate
  ) |>
  mutate(label = paste0("R² = ", round(.estimate, 2))) |>
  select(
    Model,
    # match_type,
    label
  )

#Create figures
ggplot(
  vessel_long, #|> filter(Model == "RF engine power\nand design speed"),
  aes(
    x = Estimate,
    y = co2_emissions_tonnes_registered,
    # color = match_type
  )
) +
  geom_point(
    size = 0.5,
    alpha = 0.2,
    color = "#104E8B"
  ) +
  geom_smooth(
    method = "lm",
    linewidth = 0.5,
    color = "red",
    linetype = "solid",
    se = FALSE
  ) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = "grey60") +
  geom_text(
    data = r2_labels, #|> filter(Model == "RF engine power\nand design speed"),
    aes(label = label),
    x = 500,
    y = 50,
    inherit.aes = FALSE,
    size = 3,
    fontface = "bold"
  ) +
  coord_fixed(ratio = 1, clip = "on") +
  facet_wrap(~Model, nrow = 2, scales = "fixed") +
  labs(
    x = "Simulated CO₂ Emissions (mt)",
    y = "Registered CO₂ Emissions (mt)"
  ) +
  scale_x_continuous(limits = c(0, 600)) +
  scale_y_continuous(limits = c(0, 600)) +
  theme_minimal() +
  theme(
    strip.text = element_text(size = 11, face = "bold"),
    axis.text.x = element_text(angle = 45, hjust = 1, size = 7),
    axis.text.y = element_text(size = 7),
    axis.title = element_text(size = 10),
    panel.grid.major = element_blank(),
    panel.grid.minor = element_blank(),
    axis.line = element_line(color = "black"),
    axis.ticks = element_line(color = "black"),
    axis.ticks.length = unit(0.25, "cm"),
    panel.spacing = unit(1.5, "lines"),
    strip.placement = "outside"
  )

### Performance by vessel class ----

# Reshape long, keeping vessel_class
vessel_long_by_class <- vessel_info_emissions |>
  dplyr::select(
    vessel_class,
    co2_emissions_tonnes_registered,
    `IMO report lookup table` = co2_emissions_tonnes_estimate_original,
    `RF engine power and design speed` = co2_emissions_tonnes_estimate_rf_kw_kn,
    `Registered data` = co2_emissions_tonnes_estimate_registered
  ) |>
  tidyr::pivot_longer(
    cols = -c(vessel_class, co2_emissions_tonnes_registered),
    names_to = "Model",
    values_to = "Estimate"
  ) |>
  dplyr::mutate(
    Model = dplyr::recode(
      Model,
      "RF engine power and design speed" = "New engine power and\n design speed data"
    ),
    Model = factor(Model, levels = model_levels)
  )

perf_by_class <- vessel_long_by_class |>
  dplyr::group_by(vessel_class, Model) |>
  dplyr::summarise(
    n = dplyr::n(),
    rsq_trad = yardstick::rsq_trad_vec(
      truth = co2_emissions_tonnes_registered,
      estimate = Estimate
    ),
    rsq = yardstick::rsq_vec(
      truth = co2_emissions_tonnes_registered,
      estimate = Estimate
    ),
    .groups = "drop"
  ) |>
  filter(n > 2) |>
  dplyr::arrange(dplyr::desc(n))

## Registered data paper figure ----

registered_data_performance <- ggplot(
  vessel_long |> filter(!Model %in% c("RF design speed", "RF engine power")),
  aes(
    x = Estimate,
    y = co2_emissions_tonnes_registered,
    # color = match_type
  )
) +
  geom_bin2d(
    bins = 30,
    aes(
      fill = after_stat(count),
      alpha = after_stat(ifelse(count < 3, 0, 1)) # Full transparency for counts < 3
    )
  ) +
  scale_fill_gradientn(
    colours = colorRampPalette(brewer.pal(9, "Blues"))(256),
    trans = "log10",
    name = "Count",
    guide = guide_colorbar(
      ticks.linewidth = 0.3,
      frame.colour = "black"
    )
  ) +
  geom_smooth(
    method = "lm",
    linewidth = 0.5,
    color = "red",
    linetype = "solid",
    se = FALSE
  ) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = "grey60") +
  geom_text(
    data = r2_labels |>
      filter(!Model %in% c("RF design speed", "RF engine power")),
    aes(label = label),
    x = 500,
    y = 50,
    inherit.aes = FALSE,
    size = 3,
    fontface = "bold"
  ) +
  coord_fixed(ratio = 1, clip = "on") +
  facet_wrap(~Model, nrow = 1, scales = "fixed") +
  labs(
    x = "Simulated CO₂ Emissions (mt)",
    y = "Registered CO₂ Emissions (mt)"
  ) +
  scale_x_continuous(limits = c(0, 600)) +
  scale_y_continuous(limits = c(0, 600)) +
  theme_minimal() +
  theme(
    strip.text = element_text(size = 11, face = "bold"),
    axis.text.x = element_text(angle = 45, hjust = 1, size = 7),
    axis.text.y = element_text(size = 7),
    axis.title = element_text(size = 10),
    panel.grid.major = element_blank(),
    panel.grid.minor = element_blank(),
    axis.line = element_line(color = "black"),
    axis.ticks = element_line(color = "black"),
    axis.ticks.length = unit(0.25, "cm"),
    panel.spacing = unit(1.5, "lines"),
    strip.placement = "outside",
    legend.position = "none", # Remove legend
  )

ggsave(
  filename = "figures/fig-registered-data-performance.jpg",
  plot = registered_data_performance,
  width = 8,
  height = 5,
  dpi = 300
)

# MRV data validation ----

## Pull and read data ----

# Get MRV data already processed and available in GFW BQ

# pull_gfw_data_locally(
#   bq_table_name = "eu_validation_data_v20250701",
#   bq_dataset,
#   billing_project
# ) |>
#   readr::write_csv(glue::glue(
#     "data/MRV/eu_validation_data_v20250701.csv"
#   ))

eu_validation_data <- readr::read_csv(glue::glue(
  "data/MRV/eu_validation_data_v20250701.csv"
))

# Pull trip and port visit emissions from latest model version
# Data is aggregated by year and ssvid to validate against MRV data

# pull_gfw_data_locally(
#   bq_table_name = "eu_validation_trip_v20250701",
#   bq_dataset,
#   billing_project
# ) |>
#   readr::write_csv(glue::glue(
#     "data/MRV/eu_validation_trip_v20250701.csv"
#   ))

eu_validation_trip <- readr::read_csv(glue::glue(
  "data/MRV/eu_validation_trip_v20250701.csv"
))

# pull_gfw_data_locally(
#   bq_table_name = "eu_validation_port_v20250701",
#   bq_dataset,
#   billing_project
# ) |>
#   readr::write_csv(glue::glue(
#     "data/MRV/eu_validation_port_v20250701.csv"
#   ))

# eu_validation_port <- readr::read_csv(glue::glue(
#   "data/MRV/eu_validation_port_v20250701.csv"
# ))

## Emissions validation ----
validation_performance_metrics <- yardstick::metric_set(
  yardstick::rsq,
  yardstick::rsq_trad
)

# EU dataset
eu_validation_data_updated <- eu_validation_data |>
  filter(total_time_spent_at_sea_hours != 0) |>
  mutate(
    co2_trip_emissions_eu = co2_emissions_from_all_voyages_between_ports_under_a_ms_jurisdiction_m_tonnes +
      co2_emissions_from_all_voyages_which_departed_from_ports_under_a_ms_jurisdiction_m_tonnes +
      co2_emissions_from_all_voyages_to_ports_under_a_ms_jurisdiction_m_tonnes
  ) |>
  rename(
    total_time_spent_at_sea_hours_eu = total_time_spent_at_sea_hours
  )
# Emission results by trip
eu_validation_trip_updated <- eu_validation_trip |>
  filter(total_time_spent_at_sea_hours != 0) |>
  rename(
    co2_trip_emissions_gfw = total_emissions_co2_mt,
    total_time_spent_at_sea_hours_gfw = total_time_spent_at_sea_hours
  )

find_duplicates <- function(data, key_columns) {
  duplicate_indices <- duplicated(data[key_columns]) |
    duplicated(data[key_columns], fromLast = TRUE)
  duplicates <- data[duplicate_indices, ]
  return(duplicates)
}

aggregate_duplicates <- function(data, group_by_cols, sum_cols, concat_cols) {
  aggregated_data <- data |>
    group_by(across(all_of(group_by_cols))) |>
    summarise(
      across(all_of(sum_cols), sum, .names = "{.col}"),
      across(
        all_of(concat_cols),
        ~ paste(unique(.x), collapse = "-"),
        .names = "{.col}"
      ),
      .groups = 'drop'
    )

  return(aggregated_data)
}

group_by_columns <- c("imo_number", "year")
sum_columns <- c(
  "total_time_spent_at_sea_hours_gfw",
  "total_distance_nm",
  "co2_trip_emissions_gfw"
)

concat_columns <- c("ssvid")

eu_validation_trip_updated <- aggregate_duplicates(
  eu_validation_trip_updated,
  group_by_columns,
  sum_columns,
  concat_columns
)

# Data selection and filtering
merged_df <- merge(
  eu_validation_data_updated,
  eu_validation_trip_updated,
  by.x = c("imo_number", "reporting_period"),
  by.y = c("imo_number", "year")
)

merged_df$diff <- abs(
  merged_df$total_time_spent_at_sea_hours_eu -
    merged_df$total_time_spent_at_sea_hours_gfw
)
merged_df$max <- pmax(
  merged_df$total_time_spent_at_sea_hours_eu,
  merged_df$total_time_spent_at_sea_hours_gfw
)

# Function to filter data and calculate performance metrics based on a threshold
calculate_metrics <- function(threshold, merged_df) {
  filtered_hours_df <- subset(merged_df, diff / max < threshold)
  filtered_df <- filtered_hours_df |>
    select(co2_trip_emissions_eu, co2_trip_emissions_gfw)

  # Calculate performance metrics
  comparison_results <- filtered_df |>
    pivot_longer(
      -co2_trip_emissions_eu,
      names_to = "model",
      values_to = "estimate"
    ) |>
    group_by(model) |>
    validation_performance_metrics(
      truth = co2_trip_emissions_eu,
      estimate = estimate
    ) |>
    dplyr::select(-.estimator) |>
    pivot_wider(names_from = .metric, values_from = .estimate)

  # Return results with added threshold information
  comparison_results <- comparison_results |>
    mutate(threshold = threshold, n_observations = nrow(filtered_df))

  return(comparison_results)
}

# Range of thresholds to test
thresholds <- seq(0.05, 0.4, 0.05)
# Apply calculate_metrics function over range of thresholds
performance_results <- map_df(thresholds, ~ calculate_metrics(.x, merged_df))

best_performance <- performance_results %>%
  filter(rsq_trad == max(rsq_trad))

# Select data with threshold of 0.15 the one showing best performance
filtered_hours_df <- subset(merged_df, diff / max < best_performance$threshold)
filtered_df <- filtered_hours_df |>
  select(co2_trip_emissions_eu, co2_trip_emissions_gfw)


knitr::kable(performance_results[, -1], digits = 3)

mrv_performance <- ggplot(
  filtered_df,
  aes(
    x = co2_trip_emissions_gfw,
    y = co2_trip_emissions_eu
  )
) +
  geom_point(
    size = 1.5,
    alpha = 0.5,
    color = "#104E8B"
  ) +
  geom_smooth(
    method = "lm",
    linewidth = 0.5,
    color = "red",
    linetype = "solid",
    se = FALSE
  ) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = "grey60") +
  annotate(
    geom = "text",
    label = paste0("R² = ", format(best_performance$rsq_trad, digits = 3)),
    x = 130000,
    y = 10000,
    size = 3,
    fontface = "bold"
  ) +
  coord_fixed(ratio = 1, clip = "on") +
  scale_x_continuous(limits = c(0, max(filtered_df))) +
  scale_y_continuous(limits = c(0, max(filtered_df))) +
  labs(
    x = "GFW CO2 emissions (mt)",
    y = "MRV CO2 emissions (mt)"
  ) +
  theme_minimal() +
  theme(
    strip.text = element_text(size = 11, face = "bold"),
    axis.text.x = element_text(angle = 45, hjust = 1, size = 7),
    axis.text.y = element_text(size = 7),
    axis.title = element_text(size = 10),
    panel.grid.major = element_blank(),
    panel.grid.minor = element_blank(),
    axis.line = element_line(color = "black"),
    axis.ticks = element_line(color = "black"),
    axis.ticks.length = unit(0.25, "cm"),
    panel.spacing = unit(1.5, "lines"),
    strip.placement = "outside"
  )

ggsave(
  filename = "figures/fig-mrv-performance.jpg",
  plot = mrv_performance,
  width = 8,
  height = 5,
  dpi = 300
)

## Intensity validation ----

merged_df_ratio <- merged_df |>
  mutate(
    gfw_ratio = co2_trip_emissions_gfw / total_time_spent_at_sea_hours_gfw,
    eu_ratio = co2_trip_emissions_eu / total_time_spent_at_sea_hours_eu
  ) |>
  group_by(ship_type) |>
  mutate(
    vessels_per_type = n_distinct(ssvid) # or imo_number if you want per IMO
  ) |>
  ungroup() |>
  filter(vessels_per_type > 1)

merged_df_ratio <- merged_df_ratio |>
  mutate(
    co2_error_percent = 100 * (gfw_ratio - eu_ratio) / eu_ratio,
    ship_type = case_when(
      ship_type == "Passenger ship (Cruise Passenger ship)" ~ "Passenger ship",
      ship_type == "Container/ro-ro cargo ship" ~ "Ro-ro cargo ship",
      TRUE ~ ship_type
    )
  )

percent_error_boxplot <- ggplot(
  merged_df_ratio,
  aes(
    x = forcats::fct_reorder(ship_type, vessels_per_type, .desc = TRUE),
    y = co2_error_percent
  )
) +
  geom_boxplot(
    outlier.shape = NA,
    fill = "steelblue",
    alpha = 0.7,
    linewidth = 0.3,
    outliers = FALSE
  ) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "red") +
  labs(
    x = NULL,
    y = "Relative error in CO2 emissions\nper hour at sea (%)"
  ) +
  theme_minimal(base_size = 13) +
  theme(
    axis.text.x = element_text(angle = 45, hjust = 1, size = 9),
    axis.title.y = element_text(size = 10),
    strip.text = element_text(face = "bold")
  )

# Caption: Variability of the ratio between CO2 emissions and time at sea error by ship type
ggsave(
  filename = "figures/fig-mrv-percent-error.jpg",
  plot = percent_error_boxplot,
  width = 8,
  height = 5,
  dpi = 300
)


## Replicating ICCT validation
# EU-MRV emissions

mrv_validation_data <- eu_validation_data |>
  dplyr::select(
    imo_number,
    eu_vessel_class = ship_type,
    year = reporting_period,
    annual_average_co2_emissions_per_distance_kg_co2_n_mile
  ) |>
  mutate(
    annual_average_co2_emissions_per_distance_kg_co2_n_mile = as.numeric(
      annual_average_co2_emissions_per_distance_kg_co2_n_mile
    )
  )

# Our trip emissions
repeated_imo <- eu_validation_trip |>
  distinct(imo_number, year, ssvid) |>
  count(imo_number, year) |>
  filter(n > 1) |>
  pull(imo_number)

gfw_validation_data <- eu_validation_trip |>
  filter(!imo_number %in% repeated_imo) |>
  group_by(imo_number, ssvid, year, tonnage_gt, vessel_class) |>
  summarise(
    total_time_spent_at_sea_hours = sum(
      total_time_spent_at_sea_hours,
      rm.na = TRUE
    ),
    total_emissions_co2_mt = sum(total_emissions_co2_mt, rm.na = TRUE),
    total_distance_nm = sum(total_distance_nm, rm.na = TRUE)
  ) |>
  ungroup() |>
  rename(gfw_vessel_class = vessel_class)

# Calculating emission intensity
emission_intensities <- gfw_validation_data |>
  inner_join(mrv_validation_data, by = c("year", "imo_number")) |>
  # filter(tonnage_gt < quantile(tonnage_gt, 0.75),
  #        tonnage_gt > quantile(tonnage_gt, 0.25)) |>
  mutate(
    eu_intensity = (annual_average_co2_emissions_per_distance_kg_co2_n_mile *
      1e3) *
      (1 / tonnage_gt),
    gfw_intensity = (total_emissions_co2_mt * 1e6) /
      (total_distance_nm * tonnage_gt),
    gfw_emissions_distance = total_emissions_co2_mt * 1000 / total_distance_nm,
    eu_emissions_distance = annual_average_co2_emissions_per_distance_kg_co2_n_mile
  ) |>
  dplyr::select(
    imo_number,
    gfw_vessel_class,
    eu_vessel_class,
    year,
    eu_intensity,
    gfw_intensity,
    eu_emissions_distance,
    gfw_emissions_distance
  )


performance_by_class <- emission_intensities |>
  filter(year == 2022) |>
  group_by(eu_vessel_class) |>
  summarise(
    n = n(),
    rsq_trad = yardstick::rsq_trad_vec(
      truth = eu_intensity,
      estimate = gfw_intensity
    ),
    rsq = yardstick::rsq_vec(
      truth = eu_intensity,
      estimate = gfw_intensity
    ),
    .groups = "drop"
  ) |>
  arrange(desc(n))

performance_by_class |>
  kableExtra::kable()


ggplot(
  emission_intensities |>
    filter(eu_vessel_class == "Container ship"),
  aes(x = gfw_intensity, y = eu_intensity)
) +
  geom_point(size = 1.5, alpha = 0.3, stroke = 0) +
  geom_smooth(
    method = "lm",
    linewidth = 0.5,
    color = "red",
    linetype = "solid",
    se = FALSE
  ) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = "grey") +
  coord_fixed(ratio = 1, clip = "on") +
  labs(
    x = "CO2Intensity (GFW)",
    y = "CO2 Intensity (MRV)"
  ) +
  scale_x_continuous(limits = c(0, 80)) +
  scale_y_continuous(limits = c(0, 80)) +
  theme_minimal() +
  theme(
    panel.grid.major = element_blank(),
    panel.grid.minor = element_blank(),
    axis.line = element_line(color = "black"),
    axis.ticks = element_line(color = "black"),
    axis.ticks.length = unit(0.25, "cm"),
    legend.position = "right",
    axis.text.x = element_text(angle = 45, hjust = 1, vjust = 1, size = 7),
    aspect.ratio = 1
  )


# TESTING ----

registered_data_emissions_old <- readr::read_csv(glue::glue(
  "{project_directory}/data/processed/registered_data_emissions_old.csv"
))

registered_data_emissions <- readr::read_csv(glue::glue(
  "{project_directory}/data/processed/registered_data_emissions.csv"
))


## Calculate energy use ----
## Apply function to each row
vessel_info_energy_use <- registered_data_emissions_old |>
  mutate(
    # Original:
    main_engine_energy_use_original = calculate_main_engine_energy_use_kwh(
      vessel_class,
      FALSE,
      on_fishing_list_best,
      24,
      imo_table_81_avg_main_engine_power_kw, # Using previous power estimates from IMO report table # Use main_engine_power_kw_old when testing vessel_info_v20241121
      consumption_speed_1,
      imo_table_81_avg_design_speed_knots, # Using previous speed estimates from IMO report table # Use design_speed_knots_old when testing vessel_info_v20241121
      hull_fouling_correction_factor,
      weather_correction_factor,
      draft_correction_factor
    ),
    # RF engine power and design speed:
    main_engine_energy_use_rf_kw_kn = calculate_main_engine_energy_use_kwh(
      vessel_class,
      FALSE,
      on_fishing_list_best,
      24,
      main_engine_power_kw, # Using new power estimates from RF model
      consumption_speed_1,
      design_speed_knots, # Using new speed estimates from RF model
      hull_fouling_correction_factor,
      weather_correction_factor,
      draft_correction_factor
    ),
    # Registered estimates:
    main_engine_energy_use = calculate_main_engine_energy_use_kwh(
      vessel_class,
      FALSE,
      on_fishing_list_best,
      24,
      engine_power,
      consumption_speed_1,
      max_speed,
      hull_fouling_correction_factor,
      weather_correction_factor,
      draft_correction_factor
    )
  )


## Calculate emissions ----
co2_ef <- 629.83333 # g pollutant / kwh
co2_fuel_factor <- 3.12 # tonnes pollutant/tonne fuel

vessel_info_emissions <- vessel_info_energy_use |>
  mutate(
    co2_emissions_tonnes_estimate_imo = (main_engine_energy_use_original *
      co2_ef) /
      1e6,
    co2_emissions_tonnes_estimate_rf = (main_engine_energy_use_rf_kw_kn *
      co2_ef) /
      1e6,
    co2_emissions_tonnes_estimate_registered = (main_engine_energy_use *
      co2_ef) /
      1e6,
    co2_emissions_tonnes = consumption_value_1 *
      co2_fuel_factor
  )

vessel_info_emissions <- registered_data_emissions |>
  mutate(
    co2_emissions_tonnes_estimate_imo = (main_engine_energy_use_kwh_imo *
      co2_ef) /
      1e6,
    co2_emissions_tonnes_estimate_rf = (main_engine_energy_use_kwh_rf *
      co2_ef) /
      1e6,
    co2_emissions_tonnes_estimate_registered = (main_engine_energy_use_kwh_registered *
      co2_ef) /
      1e6,
    co2_emissions_tonnes = consumption_value_1 *
      co2_fuel_factor
  )

vessel_info_emissions <- registered_data_emissions_old |>
  mutate(
    co2_emissions_tonnes_estimate_imo = (main_engine_energy_use_kwh_imo *
      co2_ef) /
      1e6,
    co2_emissions_tonnes_estimate_rf = (main_engine_energy_use_kwh_rf *
      co2_ef) /
      1e6,
    co2_emissions_tonnes_estimate_registered = (main_engine_energy_use_kwh_registered *
      co2_ef) /
      1e6,
    co2_emissions_tonnes = consumption_value_1 *
      co2_fuel_factor
  )

## Assess model performance ----
multi_metric <- yardstick::metric_set(
  yardstick::rsq,
  yardstick::rsq_trad
)

bind_rows(
  vessel_info_emissions |>
    multi_metric(
      truth = co2_emissions_tonnes,
      estimate = co2_emissions_tonnes_estimate_imo
    ) |>
    mutate(metadata = "Original"),

  vessel_info_emissions |>
    multi_metric(
      truth = co2_emissions_tonnes,
      estimate = co2_emissions_tonnes_estimate_rf
    ) |>
    mutate(metadata = "RF engine power and design speed"),

  vessel_info_emissions |>
    multi_metric(
      truth = co2_emissions_tonnes,
      estimate = co2_emissions_tonnes_estimate_registered
    ) |>
    mutate(metadata = "Registered data")
) |>
  select(metadata, .metric, .estimate) |>
  pivot_wider(names_from = .metric, values_from = .estimate) |>
  kableExtra::kable(digits = 3)


bind_rows(
  registered_data_emissions |>
    multi_metric(
      truth = co2_emissions_tonnes_registered,
      estimate = co2_emissions_tonnes_estimate_imo
    ) |>
    mutate(metadata = "Original"),

  registered_data_emissions |>
    multi_metric(
      truth = co2_emissions_tonnes_registered,
      estimate = co2_emissions_tonnes_estimate_rf
    ) |>
    mutate(metadata = "RF engine power and design speed"),

  registered_data_emissions |>
    multi_metric(
      truth = co2_emissions_tonnes_registered,
      estimate = co2_emissions_tonnes_estimate_registered
    ) |>
    mutate(metadata = "Registered data")
) |>
  select(metadata, .metric, .estimate) |>
  pivot_wider(names_from = .metric, values_from = .estimate) |>
  kableExtra::kable(digits = 3)
