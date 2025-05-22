library(dplyr)
library(tidyr)
library(tidyverse)
library(ggplot2)
library(purrr)
library(yardstick)


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

eu_validation_data <- read.csv(glue::glue("{project_directory}/data/processed/eu_validation_data_v20241121.csv"))
eu_validation_port <- read.csv(glue::glue("{project_directory}/data/processed/eu_validation_port_v20241121.csv"))
eu_validation_trip <- read.csv(glue::glue("{project_directory}/data/processed/eu_validation_trip_v20241121.csv"))
                      


repeated_imo <- eu_validation_trip %>%
  distinct(imo_number, ssvid) %>%                   
  count(imo_number) %>%                             
  filter(n > 2) |>
  pull(imo_number)

# eu_validation_trip |> filter(imo_number == 9904510) |> distinct(imo_number, ssvid)
# eu_validation_data |> filter(imo_number == 9904510)

# Performance assessment ----

# Prepare the dataset with both the trip and portof our emissions estimates.

trip_emissions <- eu_validation_trip %>% 
  filter(!imo_number %in% repeated_imo) %>%
  # filter(total_time_spent_at_sea_hours > 0) %>% 
  group_by(imo_number, year) %>% 
  summarise(total_time_spent_at_sea_hours = sum(total_time_spent_at_sea_hours, rm.na = TRUE),
            total_emissions_co2_mt = sum(total_emissions_co2_mt, rm.na = TRUE)) %>% 
  ungroup()

port_emissions <- eu_validation_port %>% 
  filter(!imo_number %in% repeated_imo) %>%
  group_by(imo_number, year) %>% 
  summarise(total_emissions_co2_mt = sum(total_emissions_co2_mt, rm.na = TRUE)) %>% 
  ungroup()

emissions_to_validate <- left_join(port_emissions, trip_emissions,  
                                   by = c("imo_number", "year"), 
                                   suffix = c( "_port", "_trip")) %>% 
  mutate(total_emissions_co2_mt_trip_port = total_emissions_co2_mt_trip + total_emissions_co2_mt_port)


# Differentiate navigation emissions from berth emisisons in the MRV EU dataset.

eu_validation_data_updated <- eu_validation_data %>% 
  filter(!imo_number %in% repeated_imo) %>%
  # filter(total_time_spent_at_sea_hours > 0) %>% 
  mutate(co2_emissions_from_navigation = co2_emissions_from_all_voyages_between_ports_under_a_ms_jurisdiction_m_tonnes +
           co2_emissions_from_all_voyages_which_departed_from_ports_under_a_ms_jurisdiction_m_tonnes +
           co2_emissions_from_all_voyages_to_ports_under_a_ms_jurisdiction_m_tonnes)


# Combine both datasets by vessel and year.

merged_df <- merge(eu_validation_data_updated, emissions_to_validate,
                   by.x = c("imo_number", "reporting_period"),
                   by.y = c("imo_number", "year"),
                   suffixes = c("_eu", "_gfw"))

merged_df$diff <- abs(merged_df$total_time_spent_at_sea_hours_eu - 
                        merged_df$total_time_spent_at_sea_hours_gfw)
merged_df$max <- pmax(merged_df$total_time_spent_at_sea_hours_eu, 
                      merged_df$total_time_spent_at_sea_hours_gfw)


# Function to assess R2 over a range of thresholds

rsq_with_threshold <- function(data, threshold, truth, estimate) {
  
  if (threshold != 0) {
    filtered_df <- data %>%
      filter(diff / max < threshold)
  } else {
    filtered_df <- data
  }
  
  rsq_result <- rsq(
    filtered_df,
    truth = {{ truth }},
    estimate = {{ estimate }}
  )
  
  rsq_trad_result <- rsq_trad(
    filtered_df,
    truth = {{ truth }},
    estimate = {{ estimate }}
  )
  
  num_vessels <- filtered_df %>%
    distinct(imo_number) %>%
    nrow()
  
  tibble(
    threshold = threshold,
    rsq = rsq_result$.estimate,
    rsq_trad = rsq_trad_result$.estimate,
    vessels_included = num_vessels
  )
}

# Assessing overall performance
thresholds <- seq(0.01, 1, 0.01)

results <- map_dfr(thresholds, ~rsq_with_threshold(
  merged_df,
  threshold = .x,
  truth = co2_emissions_from_navigation,
  estimate = total_emissions_co2_mt_trip
)) %>%
  mutate(rsq_trad = if_else(rsq_trad <= 0, 0, rsq_trad))

best <- results %>% dplyr::filter(rsq_trad == max(rsq_trad))


p1 <- ggplot(results, aes(x = threshold, y = rsq_trad)) +
  geom_line() +
  geom_point() +
  labs(x = "Threshold", y = "traditional R²") +
  theme_minimal() +
  annotate(
    "text",
    x = 0.9,
    y = 0.4,
    label = paste0(
      "max trad R2 = ", round(best$rsq_trad, 3), 
      "\nR2= ", round(best$rsq, 3), 
      "\nvessels = ", best$vessels_included
    )
  ) +
  expand_limits(y = best$rsq_trad + 0.05) 


# p2 <- ggplot(results, aes(x = threshold, y = vessels_included)) +
#   geom_line() +
#   geom_point() +
#   labs(x = "Threshold", y = "Number of Vessels") +
#   theme_minimal()

# gridExtra::grid.arrange(p1, p2, ncol = 1)
p1

filtered_merged_df <- merged_df %>% 
  filter(diff / max < 0.01)

ggplot(filtered_merged_df, aes(x = co2_emissions_from_navigation, y = total_emissions_co2_mt_trip)) +
  geom_point() +
  geom_smooth(method = "lm", se = TRUE) +
  labs(x = "EU data CO2 (mt)",
       y = "Our CO2 estimates (mt)") +
  theme_minimal()

# Assessing performance by vessel type

results_by_ship_type <- merged_df %>%
  group_by(ship_type) %>%
  group_modify(~ {
    total_vessels <- n_distinct(.x$imo_number)
    
    map_dfr(thresholds, function(thresh) {
      rsq_with_threshold(
        data = .x,
        threshold = thresh,
        truth = co2_emissions_from_navigation,
        estimate = total_emissions_co2_mt_trip
      ) %>%
        mutate(total_vessels = total_vessels)
    })
  }) %>%
  ungroup()

results_by_ship_type %>%
  group_by(ship_type) %>%
  slice_max(order_by = rsq_trad, n = 1, with_ties = FALSE) %>%
  ungroup() %>%
  arrange(desc(rsq_trad)) #|> 
  # rename(n = vessels_included) |> 
  # dplyr::select(ship_type, rsq, rsq_trad, n)


## Fixed thresshold of 5%

multi_metric <- yardstick::metric_set(
  yardstick::rsq,
  yardstick::rsq_trad
)

single_threshold <- 0.05

filtered_df <- merged_df %>%
  filter(diff / max < single_threshold)

filtered_df %>%
  group_by(ship_type) %>%
    multi_metric(
    truth = co2_emissions_from_navigation,
    estimate = total_emissions_co2_mt_trip
  ) %>%
  left_join(
    filtered_df %>%
      group_by(ship_type) %>%
      summarise(n = n(), .groups = "drop"),
    by = "ship_type"
  ) |> 
  pivot_wider(
    id_cols = c(ship_type, .estimator, n),
    names_from = .metric,
    values_from = .estimate
  ) |> 
  dplyr::select(ship_type, n, rsq, rsq_trad) |> 
  mutate(threshold = single_threshold) |> 
  arrange(desc(rsq_trad)) |>
  kableExtra::kable()



# Replicating IMO validation ----

trip_emissions <- eu_validation_trip %>% 
  filter(!imo_number %in% repeated_imo) %>%
  filter(year == 2018) %>% 
  group_by(imo_number, year) %>% 
  summarise(total_time_spent_at_sea_hours = sum(total_time_spent_at_sea_hours, rm.na = TRUE),
            total_emissions_co2_mt = sum(total_emissions_co2_mt, rm.na = TRUE)) %>% 
  ungroup()


port_emissions <- eu_validation_port %>% 
  filter(!imo_number %in% repeated_imo) %>%
  filter(year == 2018) %>% 
  group_by(imo_number, year) %>% 
  summarise(total_emissions_co2_mt = sum(total_emissions_co2_mt, rm.na = TRUE)) %>% 
  ungroup()

emissions_to_validate <- left_join(port_emissions, trip_emissions,  
                                   by = c("imo_number", "year"), 
                                   suffix = c( "_port", "_trip")) %>% 
  mutate(total_emissions_co2_mt_trip_port = total_emissions_co2_mt_trip + total_emissions_co2_mt_port)


eu_validation_data_updated <- eu_validation_data %>% 
  filter(!imo_number %in% repeated_imo) %>%
  # filter(total_time_spent_at_sea_hours > 0) %>% 
  mutate(co2_emissions_from_navigation = co2_emissions_from_all_voyages_between_ports_under_a_ms_jurisdiction_m_tonnes +
           co2_emissions_from_all_voyages_which_departed_from_ports_under_a_ms_jurisdiction_m_tonnes +
           co2_emissions_from_all_voyages_to_ports_under_a_ms_jurisdiction_m_tonnes)



merged_df <- merge(eu_validation_data_updated, emissions_to_validate,
                   by.x = c("imo_number", "reporting_period"),
                   by.y = c("imo_number", "year"),
                   suffixes = c("_eu", "_gfw"))


merged_df <- merged_df %>%
  mutate(
    co2_error_percent = 100 * (total_emissions_co2_mt_trip - co2_emissions_from_navigation) / co2_emissions_from_navigation
  )

ggplot(merged_df, aes(x = ship_type, y = co2_error_percent)) +
  geom_boxplot(outlier.shape = NA, fill = "steelblue", alpha = 0.7, outliers = FALSE) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "red") +
  labs(
    x = NULL,
    y = "Error (%)",
    title = "Variability CO2 emissions error by ship type"
  ) +
  theme_minimal(base_size = 13) +
  theme(
    axis.text.x = element_text(angle = 45, hjust = 1),
    strip.text = element_text(face = "bold")
  )

# Assessing variability of the ratio of CO2/hours at sea ----

merged_df_ratio <- merged_df %>% 
  mutate(gfw_ratio = total_emissions_co2_mt_trip/total_time_spent_at_sea_hours_gfw,
         eu_ratio = co2_emissions_from_navigation/total_time_spent_at_sea_hours_eu)


merged_df_ratio <- merged_df_ratio %>%
  mutate(
    co2_error_percent = 100 * (gfw_ratio - eu_ratio) / eu_ratio
  )

ggplot(merged_df_ratio, aes(x = ship_type, y = co2_error_percent)) +
  geom_boxplot(outlier.shape = NA, fill = "steelblue", alpha = 0.7, outliers = FALSE) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "red") +
  labs(
    x = NULL,
    y = "Error (%)",
    title = "Variability of the ratio between CO2 emissions and time at sea error by ship type"
  ) +
  theme_minimal(base_size = 13) +
  theme(
    axis.text.x = element_text(angle = 45, hjust = 1),
    strip.text = element_text(face = "bold")
  )

rsq_trad(merged_df_ratio,
          truth = eu_ratio,
          estimate = gfw_ratio)










