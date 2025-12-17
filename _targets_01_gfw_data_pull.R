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
    "v20251216"
  ),
  # Set analysis start year
  tar_target(
    name = analysis_start_year,
    2017
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
      sql = "SELECT * FROM ",
      file_path = here::here("data/gfw/n_ais_messages.csv"),
    ),
    format = "file"
  ),
  # Number of S1 detections used during our time period
  tar_file_read(
    name = n_s1_detections,
    "sql/n_s1_detections.sql",
    download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_dark = run_version_dark,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = here::here("data/gfw/n_s1_detections.csv"),
    ),
    format = "file"
  ),
  # Performance estimates for dark fleet models (emissions regression; detections classification; and detections regrions).
  # Includes performance estimates for both inside and outside the S1 footprint
  tar_file(
    name = all_performance_metrics,
    download_gfw_data(
      bq_billing_project,
      sql = "SELECT * FROM `world-fishing-827.proj_ocean_ghg.rf_s1_time_gridded_dark_fleet_model_performance_metrics_{run_version_dark}`" |>
        stringr::str_glue(
          run_version_dark = run_version_dark
        ),
      file_path = here::here("data/gfw/all_performance_metrics.csv"),
    )
  ),
  # Monthly summary of Co2 emissions for AIS-broadcasting fleet and non-broadcasting vessels,
  # broken apart by fishing and non-fishing vessels,
  # inside and outside the S1 footprint; and imaged and not imaged in the S1 footprint
  tar_file_read(
    name = monthly_aggregated_time_series,
    "sql/monthly_aggregated_time_series.sql",
    download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_dark = run_version_dark
        ),
      file_path = here::here("data/gfw/monthly_aggregated_time_series.csv"),
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
  # Spatial gridded 2016 and 2024 emissions by pollutant
  # Aggregated across AIS-broadcasting and non-broadcasting fleets
  tar_file_read(
    name = total_spatial_emissions_by_pollutant,
    "sql/total_spatial_emissions_by_pollutant.sql",
    download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_dark = run_version_dark,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = here::here(
        "data/gfw/total_spatial_emissions_by_pollutant.csv"
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
          run_version_dark = run_version_dark,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
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
  # Total 2024 port visit CO2 emissions by country
  tar_file_read(
    name = port_visit_co2_emissions_by_country,
    "sql/port_visit_co2_emissions_by_country.sql",
    download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais,
          analysis_start_year = 2024,
          analysis_end_year = 2024
        ),
      file_path = here::here(
        "data/gfw/port_visit_co2_emissions_by_country.csv"
      )
    ),
    format = "file"
  ),
  # Total 2024 trip-level CO2 emissions by from- and to-country
  tar_file_read(
    name = trip_co2_emissions_by_from_to_countries,
    "sql/trip_co2_emissions_by_from_to_countries.sql",
    download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais,
          analysis_start_year = 2024,
          analysis_end_year = 2024
        ),
      file_path = here::here(
        "data/gfw/trip_co2_emissions_by_from_to_countries.csv"
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
  ),
  # Annual AIS-broadcasting emissions and unique vessels by receiver type
  tar_file_read(
    name = annual_global_emissions_by_receiver_type,
    "sql/annual_global_emissions_by_receiver_type.sql",
    download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = here::here(
        "data/gfw/annual_global_emissions_by_receiver_type.csv"
      )
    ),
    format = "file"
  ),
  # Annual AIS-broadcasting emissions by receiver type and flag
  tar_file_read(
    name = annual_global_emissions_by_receiver_type_and_flag,
    "sql/annual_global_emissions_by_receiver_type_and_flag.sql",
    download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = here::here(
        "data/gfw/annual_global_emissions_by_receiver_type_and_flag.csv"
      )
    ),
    format = "file"
  ),
  # Spatial AIS-broadcasting emissions by receiver type for starting and ending years
  tar_file_read(
    name = annual_spatial_emissions_by_receiver_type,
    "sql/annual_spatial_emissions_by_receiver_type.sql",
    download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = here::here(
        "data/gfw/annual_spatial_emissions_by_receiver_type.csv"
      )
    ),
    format = "file"
  ),
  # Get length and engine power of all vessels
  # For plotting this relationship
  tar_file_read(
    name = vessel_size_info,
    "sql/vessel_size_info.sql",
    download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais
        ),
      file_path = here::here(
        "data/gfw/vessel_size_info.csv"
      )
    ),
    format = "file"
  ),
  # Compare vessel size class distributions of S1 data and AIS data
  # For each of unmatched S1 detections and AIS vessels, each vessel type (fishing and non-fishing), and each size class
  # Calculate the minimum, maximum, standard devation, and average length
  tar_file_read(
    name = s1_ais_vessel_size_class_comparison,
    "sql/s1_ais_vessel_size_class_comparison.sql",
    download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          # Update this to run_version_dark once s1_ratios_sf has made new tables
          run_version_dark = "v20251005"
        ),
      file_path = here::here(
        "data/gfw/s1_ais_vessel_size_class_comparison.csv"
      )
    ),
    format = "file"
  ),
  # Registered data validation
  tar_file_read(
    name = registered_validation_data,
    "sql/registered_data_validation.sql",
    download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_dark = run_version_dark
        ),
      file_path = here::here(
        "data/registered_validation_data/registered_validation_data.csv"
      )
    ),
    format = "file"
  ),
  # MRV data validation
  tar_target(
    name = mrv_data_validation,
    combine_EU_data(here::here("data/MRV/mrv_data_validation.csv")),
  ),
  # Trip emissions to validate using MRV data
  tar_file_read(
    name = trip_emissions_for_mrv_validation,
    "sql/trip_emissions_for_mrv_validation.sql",
    download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais
        ),
      file_path = here::here(
        "data/MRV/trip_emissions_for_mrv_validation.csv"
      )
    ),
    format = "file"
  )
)
