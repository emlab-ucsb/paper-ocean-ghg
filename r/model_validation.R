# Model validation

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

# Load functions to access BQ data
source("r/functions.R")

library(RColorBrewer)
library(tidyverse)
library(bigrquery)

## Registered data ----

# Pull latest registered fuel consumption data from BQ
# pull_gfw_data_locally(
#   bq_table_name = "snp_fuel_consumption_v20250607",
#   bq_dataset,
#   billing_project
# ) |>
#   readr::write_csv(glue::glue(
#     "{project_directory}/data/raw/registered_fuel_consumption_v20250607.csv"
#   ))

registered_fuel_consumption <- readr::read_csv(glue::glue(
  "{project_directory}/data/raw/registered_fuel_consumption_v20250607.csv"
))

# Pull latest vessel info data from BQ
# pull_gfw_data_locally(
#   bq_table_name = "vessel_info_v20250701",
#   bq_dataset,
#   billing_project
# ) |>
#   readr::write_csv(glue::glue(
#     "{project_directory}/data/raw/vessel_info_v20250701.csv"
#   ))

vessel_info <- readr::read_csv(glue::glue(
  "{project_directory}/data/raw/vessel_info_v20250701.csv"
))

# Pull previous vessel info data from BQ
# pull_gfw_data_locally(
#   bq_table_name = "vessel_info_v20241121",
#   bq_dataset,
#   billing_project
# ) |>
#   readr::write_csv(glue::glue(
#     "{project_directory}/data/raw/vessel_info_v20241121.csv"
#   ))

vessel_info_v20241121 <- readr::read_csv(glue::glue(
  "{project_directory}/data/raw/vessel_info_v20241121.csv"
))


ssvid_v20241121 <- vessel_info_v20241121 |> pull(ssvid) |> unique()

# Combine in a single dataset

registered_fuel_consumption_renamed <- registered_fuel_consumption |>
  rename_with(~ paste0(., "_registered"), .cols = -imo)


## Select vessels and metadata from previous vessel_info table ----
# vessel_info_v20241121_renamed <- vessel_info_v20241121 |>
#   dplyr::select(ssvid, main_engine_power_kw, design_speed_knots) |>
#   rename_with(~ paste0(., "_old"), .cols = -ssvid)

# vessel_info_updated <- vessel_info |>
#   inner_join(vessel_info_v20241121_renamed, by = "ssvid")

# vessel_info_combined <- vessel_info_updated |>
#   filter(!imo_ais %in% repeated_imo_ais) |>
#   inner_join(registered_fuel_consumption_renamed, by = c("imo_ais" = "imo"))

## Select vessels from new vessel_info table that do not have repeated imo ids ----
# Some imo ids are repeted for different vessels (i.e., more than one imo for a single ssvid)
# repeated_imo_ais <- vessel_info |>
#   count(imo_ais) |>
#   filter(n > 1) |>
#   pull(imo_ais)

# # This limits selection to non duplicated IMO matches (8160 out of 21491 available vessels in the registered metadata)
# vessel_info_combined <- vessel_info |>
#   # filter(ssvid %in% ssvid_v20241121) |> # Limit selection to ssvids from previous vessel_info table to check previous performance assessment
#   filter(!imo_ais %in% repeated_imo_ais) |>
#   inner_join(registered_fuel_consumption_renamed, by = c("imo_ais" = "imo"))

## Select vessels from new vessel_info table using imo and mmsi ----
# Match selection using MMSI and vessel name
filtered_repeated <- vessel_info %>%
  # filter(ssvid %in% ssvid_v20241121) |> # Limit selection to ssvids from previous vessel_info table to check previous performance assessment
  filter(imo_ais %in% repeated_imo_ais) %>%
  inner_join(registered_fuel_consumption_renamed, by = c("imo_ais" = "imo")) %>%
  filter(
    ssvid == mmsi_registered |
      ship_name_registry == ship_name_registered |
      ship_name_ais == ship_name_registered
  )

# # Generate final dataset of matches
vessel_info_combined <- vessel_info %>%
  filter(!imo_ais %in% repeated_imo_ais) |>
  bind_rows(filtered_repeated) |>
  dplyr::select(names(vessel_info)) |>
  inner_join(registered_fuel_consumption_renamed, by = c("imo_ais" = "imo"))

# Define main engine model ----
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
  "Original IMO data",
  "RF engine power",
  "RF design speed",
  "RF engine power\nand design speed",
  "Registered data"
)

# Reshape and apply factor levels
vessel_long <- vessel_info_emissions |>
  select(
    co2_emissions_tonnes_registered,
    `Original IMO data` = co2_emissions_tonnes_estimate_original,
    `RF design speed` = co2_emissions_tonnes_estimate_rf_kn,
    `RF engine power` = co2_emissions_tonnes_estimate_rf_kw,
    `RF engine power and design speed` = co2_emissions_tonnes_estimate_rf_kw_kn,
    `Registered data` = co2_emissions_tonnes_estimate_registered
  ) |>
  pivot_longer(
    cols = -co2_emissions_tonnes_registered,
    names_to = "Model",
    values_to = "Estimate"
  ) |>
  mutate(
    Model = recode(
      Model,
      "RF engine power and design speed" = "RF engine power\nand design speed"
    )
  ) |>
  mutate(Model = factor(Model, levels = model_levels))

r2_labels <- vessel_long |>
  group_by(Model) |>
  yardstick::rsq_trad(
    truth = co2_emissions_tonnes_registered,
    estimate = Estimate
  ) |>
  mutate(label = paste0("R² = ", round(.estimate, 2))) |>
  select(Model, label)

ggplot(vessel_long, aes(x = Estimate, y = co2_emissions_tonnes_registered)) +
  geom_point(size = 0.5, alpha = 0.2, color = "#104E8B") +
  geom_smooth(
    method = "lm",
    linewidth = 0.5,
    color = "red",
    linetype = "solid",
    se = FALSE
  ) +
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = "grey60") +
  geom_text(
    data = r2_labels,
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
    x = "Simulated CO₂ Emissions for 24h (Tonnes)",
    y = "Registered Emissions (Tonnes)"
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


# Rule of three compliant
ggplot(
  vessel_long |> filter(Model == "RF engine power\nand design speed"),
  aes(x = Estimate, y = co2_emissions_tonnes_registered)
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
    data = r2_labels |> filter(Model == "RF engine power\nand design speed"),
    aes(label = label),
    x = 500,
    y = 50,
    inherit.aes = FALSE,
    size = 3,
    fontface = "bold"
  ) +
  coord_fixed(ratio = 1, clip = "on") +
  labs(
    x = "Simulated CO₂ Emissions for 24h (Tonnes)",
    y = "Registered Emissions (Tonnes)"
  ) +
  scale_x_continuous(limits = c(0, 600)) +
  scale_y_continuous(limits = c(0, 600)) +
  theme_minimal() +
  theme(
    panel.grid.major = element_blank(), # Remove major grid lines
    panel.grid.minor = element_blank(), # Remove minor grid lines
    axis.line = element_line(color = "black"), # Add contour (axis lines)
    axis.ticks = element_line(color = "black"), # Add axis ticks
    axis.ticks.length = unit(0.25, "cm"), # Adjust tick length
    legend.position = "none", # Remove legend
    axis.text.x = element_text(angle = 45, hjust = 1, vjust = 1, size = 7), # Rotate x-axis tick labels
    aspect.ratio = 1 # Enforce square aspect in layout regardless of device
  )
