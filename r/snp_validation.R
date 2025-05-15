
library(tidyverse)
library(bigrquery)
library(yardstick)

# S&P validation

source("r/functions.R")

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

vessel_info_snp_match <- read.csv(glue::glue("{project_directory}/data/processed/vessel_info_snp_match.csv"))
snp_fuel_consumption <- read.csv(glue::glue("{project_directory}/data/processed/snp_fuel_consumption_v20250404.csv"))

# Data exploration and filtering ----

## Consumption values 
ggplot(snp_fuel_consumption, aes(y = consumption_value_1)) +
  geom_boxplot(fill = "lightblue", color = "darkblue") +
  labs(
    title = "All consumption values",
    y = "Consumption Value"
  ) +
  theme_minimal()

## Speed values 
ggplot(snp_fuel_consumption|> filter(consumption_speed_1 < 300), aes(x = consumption_speed_1)) +
  geom_histogram(
    bins = 30,              
    fill = "#2c3e50",       
    color = "white",       
    alpha = 0.8             
  ) +
  labs(
    title = "Histogram of Consumption Speed",
    x = "Consumption Speed",
    y = "Frequency"
  ) +
  theme_minimal()

ggplot(snp_fuel_consumption |> filter(consumption_speed_1 < 300), aes(y = consumption_speed_1)) +
  geom_boxplot(fill = "lightblue", color = "darkblue") +
  labs(
    title = "Speeds < 300 knots",
    y = "Consumption Speed"
  ) +
  theme_minimal()

# Match vessel_info_snp_match to snp_fuel_consumption -----

# Identify the duplicated imo_ais values
repeated_imo_ais <- vessel_info_snp_match %>%
  count(imo_ais) %>%
  filter(n > 1) %>%
  pull(imo_ais)

# Match selection using MMSI and vessel name
filtered_repeated <- vessel_info_snp_match %>%
  filter(imo_ais %in% repeated_imo_ais) %>%
  inner_join(snp_fuel_consumption, by = c("imo_ais" = "imo")) %>%
  filter(
    ssvid == mmsi |
    ship_name_registry == ship_name | 
    ship_name_ais == ship_name
  )

# Generate final dataset of matches
vessel_info_final <- vessel_info_snp_match %>%
  filter(!imo_ais %in% repeated_imo_ais) |> 
  bind_rows(filtered_repeated) |> 
  dplyr::select(names(vessel_info_snp_match)) |> 
  inner_join(snp_fuel_consumption, by = c("imo_ais" = "imo"))

## Limit selection to direct IMO matches
# vessel_info_final <- vessel_info_snp_match %>%
#   filter(!imo_ais %in% repeated_imo_ais) |> 
#   inner_join(snp_fuel_consumption, by = c("imo_ais" = "imo"))


# Define main engine model ----

hull_fouling_correction_factor <- 1.07
draft_correction_factor <- 0.85
## weather factor is dependant on distance from shore
## Since we don't have such information we'll set this factor to 1.1
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
vessel_info_energy_use <- vessel_info_final |>
  mutate(
    main_engine_energy_use_kwh = calculate_main_engine_energy_use_kwh(
      vessel_class,
      FALSE,
      on_fishing_list_best,
      24,
      main_engine_power_kw,
      consumption_speed_1,
      design_speed_knots,
      hull_fouling_correction_factor,
      weather_correction_factor,
      draft_correction_factor
    )
  )


# Alternative dataset generated directly within BQ using vessel_info_snp_match_extended.sql
vessel_info_snp_match_extended <- read.csv(glue::glue("{project_directory}/data/processed/vessel_info_snp_match_extended.csv"))
vessel_info_energy_use <- vessel_info_snp_match_extended

## Filtering data between Q1 and Q3. OPTIONAL if we want to remove outliers
q1 <- quantile(snp_fuel_consumption$consumption_speed_1, 0.25)
q3 <- quantile(snp_fuel_consumption$consumption_speed_1, 0.75)

vessel_info_energy_use <- vessel_info_energy_use %>%
  filter(consumption_speed_1 >= q1 & consumption_speed_1 <= q3)

## Convert to CO2 emissions
## Main engine pollutant emission factors are derived from Appendix E in Olmer et al. (2017).
co2_ef <- 629.83333 # g pollutant / kwh
## To convert from fuel to CO2, I use 3.12 which is an approximation between heavy fuel oil (HFO) of 3.114 and marine diesel (MDO) 3.206 which is from table 27 of the 4th IMO study.
co2_fuel_factor <- 3.12 # tonnes pollutant/tonne fuel
co2_fuel_factor <- 3.114 # tonnes pollutant/tonne fuel

vessel_info_emissions <- vessel_info_energy_use |>
  mutate(
    co2_emissions_tonnes_estimate = (main_engine_energy_use_kwh * co2_ef) / 1e6,
    co2_emissions_tonnes_snp = consumption_value_1 * co2_fuel_factor
  ) 




# Validation ----

multi_metric <- yardstick::metric_set(
  yardstick::rmse,
  yardstick::rsq,
  yardstick::rsq_trad,
  yardstick::mae,
)

vessel_info_emissions %>%
  group_by(vessel_class) %>%
  yardstick::rsq(
    truth = co2_emissions_tonnes_snp,
    estimate = co2_emissions_tonnes_estimate
  ) %>%
  left_join(
    vessel_info_emissions %>%
      group_by(vessel_class) %>%
      summarise(n = n(), .groups = "drop"),
    by = "vessel_class"
  ) |>
  arrange(desc(.estimate ))|> 
  kableExtra::kable()

  vessel_info_emissions %>%
    multi_metric(
      truth = co2_emissions_tonnes_snp,     
      estimate = co2_emissions_tonnes_estimate  
    ) |> kableExtra::kable()

ggplot(vessel_info_emissions, aes(x = co2_emissions_tonnes_estimate, y = co2_emissions_tonnes_snp)) +
  geom_point(size = 3, alpha = 0.3, stroke = 0) +
  geom_smooth(method = "lm", linewidth=0.5, color= "red", linetype = "solid", se = FALSE) +  
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = "grey") +  
  coord_fixed(ratio = 1, clip = "on") +  
  labs(
    x = "Simulated CO2 Emissions (Tonnes)",
    y = "Observed CO2 Emissions (Tonnes)"
  ) +
  scale_x_continuous(limits = c(0, 600)) +
  scale_y_continuous(limits = c(0, 600)) +
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


ggplot(vessel_info_emissions, aes(x = co2_emissions_tonnes_estimate, y = co2_emissions_tonnes_snp)) +
  geom_point(size = 3, alpha = 0.3, stroke = 0) +
  geom_smooth(method = "lm", linewidth=0.5, color= "red", linetype = "solid", se = FALSE) +  
  geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = "grey") +  
  coord_fixed(ratio = 1, clip = "on") +  
  labs(
    x = "AIS-model CO2 Emissions (Tonnes)",
    y = "S&P derived CO2 Emissions (Tonnes)"
  ) +
  scale_x_continuous(limits = c(0, 600)) +
  scale_y_continuous(limits = c(0, 600)) +
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


# Calculating Percentage Difference
vessel_info_emissions <- vessel_info_emissions %>%
  mutate(percentage_difference = ((co2_emissions_tonnes_estimate - co2_emissions_tonnes_snp) / co2_emissions_tonnes_snp) * 100)

ggplot(vessel_info_emissions, aes(x = factor(1), y = percentage_difference)) +
  geom_boxplot(outlier.size = 0.7) +
  labs(
    y = "Difference %",
    x = ""
  ) +
  theme_minimal() +
  theme(
    axis.title.x = element_text(size = 12),
    axis.text.x = element_text(size = 10)
  )




