# Load packages required to define the pipeline:
library(targets)
library(tarchetypes) # Load other packages as needed.

# Set the targets pipeline, since this repo has multiple targets pipelines
Sys.setenv(TAR_PROJECT = "01_gfw_data_pull")

# Run the R scripts in the R/ folder with your custom functions:
tar_source("r/functions.R")

# Do this to help with BigQuery downloading
options(scipen = 20)

# AIS-based emissions model ----
list(
  # Set BigQuery billing project
  tar_target(
    name = bq_billing_project,
    "emlab-gcp"
  ),
  tar_target(
    # Define the version of the AIS dataset to pull
    name = run_version_ais,
    "v20250701"
  ),
  # Define the version of the dark fleet dataset to pull
  tar_target(
    name = run_version_dark,
    "v20250228"
  ),
  # Set analysis start year
  tar_target(
    name = analysis_start_year,
    2016
  ),
  # Set analysis end year
  tar_target(
    name = analysis_end_year,
    2024
  ),
  # Number of unique vessels with emissions data during our time period
  tar_file_read(
    name = n_unique_vessels,
    "sql/n_unique_vessels.sql",
    download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = here::here("data/gfw/n_unique_vessels.csv"),
    ),
    format = "file"
  ),
  # Number of AIS messages with emissions data during our time period
  tar_file_read(
    name = n_ais_messages,
    "sql/n_ais_messages.sql",
    download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = here::here("data/gfw/n_ais_messages.csv"),
    ),
    format = "file"
  ),
  # Annual emissions data for AIS-broadcasting fleet and non-broadcasting vessels,
  # broken apart by fishing and non-fishing vessels
  # For all pollutants
  tar_file_read(
    name = annual_emissions_all_pollutants,
    "sql/annual_emissions_all_pollutants.sql",
    download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_dark = run_version_dark,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = here::here("data/gfw/annual_emissions_all_pollutants.csv"),
    ),
    format = "file"
  ),
  # Spatial gridded 2024 emissions by pollutant
  # Aggregated across AIS-broadcasting and non-broadcasting fleets
  tar_file_read(
    name = total_spatial_emissions_by_pollutant_2024,
    "sql/total_spatial_emissions_by_pollutant_2024.sql",
    download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_dark = run_version_dark,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = here::here(
        "data/gfw/total_spatial_emissions_by_pollutant_2024.csv"
      ),
    ),
    format = "file"
  ),
  # Annual extrapolation of AIS activity to dark activity
  # Use method we use for extrapolating emissions (by pixel, month, fishing, and vessel size class)
  # To also extrapolate hours, kw-hours
  # Also get average speed, assuming they are same for dark and AIS (by pixel, month, fishing, and vessel size class)
  tar_file_read(
    name = annual_ais_to_dark_activity_extrapolation,
    "sql/annual_ais_to_dark_activity_extrapolation.sql",
    download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais,
          run_version_dark = run_version_dark
        ),
      file_path = here::here(
        "data/gfw/annual_ais_to_dark_activity_extrapolation.csv"
      )
    ),
    format = "file"
  ),
  # Download total monthly non-spatial emissions by pollutant
  tar_file_read(
    name = total_monthly_emissions_by_pollutant,
    "sql/total_monthly_emissions_by_pollutant.sql",
    download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_dark = run_version_dark
        ),
      file_path = here::here(
        "data/gfw/total_monthly_emissions_by_pollutant.csv"
      )
    ),
    format = "file"
  ),
  # Annual AIS-broadcasting CO2 emissions by vessel type
  tar_file_read(
    name = annual_ais_co2_emissions_by_vessel_type,
    "sql/annual_ais_co2_emissions_by_vessel_type.sql",
    download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = here::here(
        "data/gfw/annual_ais_co2_emissions_by_vessel_type.csv"
      )
    ),
    format = "file"
  ),
  # Annual non-broadcastin emissions and detections
  # By vessel type
  tar_file_read(
    name = annual_non_broadcasting_detections_emissions,
    "sql/annual_non_broadcasting_detections_emissions.sql",
    download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_dark = run_version_dark,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = here::here(
        "data/gfw/annual_non_broadcasting_detections_emissions.csv"
      )
    ),
    format = "file"
  ),
  # Average KNN ratios by pixel, within and outside the footprint
  # Averaged across all years of data
  # By vessel type
  tar_file_read(
    name = s1_mean_spatial_knn_ratios,
    "sql/s1_mean_spatial_knn_ratios.sql",
    download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_dark = run_version_dark,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = here::here(
        "data/gfw/s1_mean_spatial_knn_ratios.csv"
      )
    ),
    format = "file"
  )
  # # Define monthly_ais_vessels_and_ratios_by_pixel query path
  # tar_target(
  #   name = monthly_ais_vessels_and_ratios_by_pixel_sql_file,
  #   "sql/monthly_ais_vessels_and_ratios_by_pixel.sql",
  #   format = "file"
  # ),
  # # Generate BQ monthly_ais_vessels_and_ratios_by_pixel table
  # tar_target(
  #   name = monthly_ais_vessels_and_ratios_by_pixel_bq,
  #   run_gfw_query_and_save_table(
  #     sql = monthly_ais_vessels_and_ratios_by_pixel_sql_file %>%
  #       readr::read_file(),
  #     bq_table_name = glue::glue(
  #       "monthly_ais_vessels_and_ratios_by_pixel",
  #       run_version_dark
  #     ),
  #     bq_dataset = bq_dataset,
  #     billing_project = billing_project,
  #     bq_project = bq_project,
  #     write_disposition = 'WRITE_TRUNCATE',
  #     # Re-run this target if targets below change
  #     monthly_ais_vessels_and_ratios_by_pixel_sql_file
  #   )
  # ),
  # # Pull monthly_ais_vessels_and_ratios_by_pixel data locally
  # tar_target(
  #   name = monthly_ais_vessels_and_ratios_by_pixel,
  #   pull_gfw_data_locally(
  #     billing_project = billing_project,
  #     bq_dataset = bq_dataset,
  #     bq_table_name = glue::glue(
  #       "monthly_ais_vessels_and_ratios_by_pixel",
  #       run_version_dark
  #     ),
  #     # Re-run this target if targets below change
  #     monthly_ais_vessels_and_ratios_by_pixel_bq
  #   )
  # ),
  # # Define monthly_ais_vessels_and_ratios query path
  # tar_target(
  #   name = monthly_ais_vessels_and_ratios_sql_file,
  #   "sql/monthly_ais_vessels_and_ratios.sql",
  #   format = "file"
  # ),
  # # Generate BQ monthly_ais_vessels_and_ratios table
  # tar_target(
  #   name = monthly_ais_vessels_and_ratios_bq,
  #   run_gfw_query_and_save_table(
  #     sql = monthly_ais_vessels_and_ratios_sql_file %>% readr::read_file(),
  #     bq_table_name = glue::glue(
  #       "monthly_ais_vessels_and_ratios",
  #       run_version_dark
  #     ),
  #     bq_dataset = bq_dataset,
  #     billing_project = billing_project,
  #     bq_project = bq_project,
  #     write_disposition = 'WRITE_TRUNCATE',
  #     # Re-run this target if targets below change
  #     monthly_ais_vessels_and_ratios_sql_file
  #   )
  # ),
  # # Pull monthly_ais_vessels_and_ratios data locally
  # tar_target(
  #   name = monthly_ais_vessels_and_ratios,
  #   pull_gfw_data_locally(
  #     billing_project = billing_project,
  #     bq_dataset = bq_dataset,
  #     bq_table_name = glue::glue(
  #       "monthly_ais_vessels_and_ratios",
  #       run_version_dark
  #     ),
  #     # Re-run this target if targets below change
  #     monthly_ais_vessels_and_ratios_bq
  #   )
  # ),
  # tar_target(
  #   name = s1_knn_ratios_within_footprint,
  #   pull_gfw_data_locally(
  #     billing_project = billing_project,
  #     bq_dataset = bq_dataset,
  #     bq_table_name = glue::glue(
  #       "s1_knn_ratios_within_footprint",
  #       run_version_dark_fleet
  #     )
  #   )
  # ),
  # tar_target(
  #   name = s1_knn_ratios_outside_footprint,
  #   pull_gfw_data_locally(
  #     billing_project = billing_project,
  #     bq_dataset = bq_dataset,
  #     bq_table_name = glue::glue(
  #       "s1_knn_ratios_outside_footprint",
  #       run_version_dark_fleet
  #     )
  #   )
  # ),
  # tar_target(
  #   name = s1_dark_fleet_model_results,
  #   pull_gfw_data_locally(
  #     billing_project = billing_project,
  #     bq_dataset = bq_dataset,
  #     bq_table_name = glue::glue(
  #       "s1_time_gridded_dark_fleet_model",
  #       run_version_dark_fleet
  #     )
  #   )
  # ),
  # tar_target(
  #   name = s1_summarized_dark_fleet_ratios_spatial,
  #   summarize_dark_fleet_ratios_spatial(s1_dark_fleet_model_results)
  # ),
  # tar_target(
  #   name = s1_summarized_dark_fleet_model_results_emissions_year,
  #   summarize_dark_fleet_model_results_emissions(
  #     s1_dark_fleet_model_results,
  #     time_extrapolation = "YEAR"
  #   )
  # )
  # ,
  # # Make quarto notebook -----
  # tar_quarto(
  #   name = quarto_book,
  #   path = "qmd",
  #   quiet = FALSE
  # )
)
