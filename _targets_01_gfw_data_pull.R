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
    "v20260714"
  ),
  # Define the version of the dark fleet dataset to pull
  tar_target(
    name = run_version_dark,
    "paper_v20260714"
  ),
  # Set analysis start year
  tar_target(
    name = analysis_start_year,
    2017
  ),
  # Set analysis end year
  tar_target(
    name = analysis_end_year,
    2025
  ),
  # Number of unique vessels with emissions data during our time period
  tar_file_read(
    name = n_unique_vessels,
    command = file.path("sql", "n_unique_vessels.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = file.path("data", "gfw", "n_unique_vessels.csv"),
    ),
    format = "file"
  ),
  # Number of AIS messages with emissions data during our time period
  tar_file_read(
    name = n_ais_messages,
    command = file.path("sql", "n_ais_messages.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = file.path("data", "gfw", "n_ais_messages.csv"),
    ),
    format = "file"
  ),
  # Summarize number of unique vessels, and total CO2 AIS-based emissions,
  # for vessels: on the IMO registry; on some other registry; and without any registry info
  tar_file_read(
    name = fraction_vessels_emissions_by_registry_info,
    command = file.path("sql", "fraction_vessels_emissions_by_registry_info.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = file.path("data", "gfw", "fraction_vessels_emissions_by_registry_info.csv"),
    ),
    format = "file"
  ),
  # Distribution of ping-level hours values (min, mean, max, median)
  tar_file_read(
    name = ping_level_hours_distribution,
    command = file.path("sql", "ping_level_hours_distribution.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = file.path("data", "gfw", "ping_level_hours_distribution.csv"),
    ),
    format = "file"
  ),
  # Number of S1 detections used during our time period
  tar_file_read(
    name = n_s1_detections,
    command = file.path("sql", "n_s1_detections.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_dark = run_version_dark,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = file.path("data", "gfw", "n_s1_detections.csv"),
    ),
    format = "file"
  ),
  # Number of S1 detections (matched and unmathced), number of S1 scenes, and total S1 area imaged,
  # by month, during our time period
  tar_file_read(
    name = s1_time_series,
    command = file.path("sql", "s1_time_series.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_dark = run_version_dark,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = file.path("data", "gfw", "s1_time_series.csv"),
    ),
    format = "file"
  ),
  # Get distributions of AIS vessels and S1 detections by length size bin and fishing/non-fishing
  tar_file_read(
    name = length_size_bin_distributions,
    command = file.path("sql", "length_size_bin_distributions.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_dark = run_version_dark
        ),
      file_path = file.path("data", "gfw", "length_size_bin_distributions.csv"),
    ),
    format = "file"
  ),
  # Performance estimates for dark fleet models (emissions regression; detections classification; and detections regrions).
  # Includes performance estimates for both inside and outside the S1 footprint
  tar_file(
    name = all_performance_metrics,
    command = download_gfw_data(
      bq_billing_project,
      sql = "SELECT * FROM `world-fishing-827.proj_ocean_ghg.rf_s1_time_gridded_dark_fleet_model_performance_metrics_{run_version_dark}`" |>
        stringr::str_glue(
          run_version_dark = run_version_dark
        ),
      file_path = file.path("data", "gfw", "all_performance_metrics.csv"),
    )
  ),
  # Pull variable importance data for all final model fits
  tar_file(
    name = all_varimp_data,
    command = download_gfw_data(
      bq_billing_project,
      sql = "SELECT * FROM `world-fishing-827.proj_ocean_ghg.rf_s1_time_gridded_dark_fleet_model_all_varimp_data_{run_version_dark}`" |>
        stringr::str_glue(
          run_version_dark = run_version_dark
        ),
      file_path = file.path("data", "gfw", "all_varimp_data.csv"),
    )
  ),
  # Pull ROC and PR curves for classification model performance assessment
  tar_file(
    name = performance_detections_cls_roc_pr_curves,
    command = download_gfw_data(
      bq_billing_project,
      sql = "SELECT * FROM `world-fishing-827.proj_ocean_ghg.rf_s1_time_gridded_dark_fleet_model_performance_detections_cls_roc_pr_curves_{run_version_dark}`" |>
        stringr::str_glue(
          run_version_dark = run_version_dark
        ),
      file_path = file.path("data", "gfw", "performance_detections_cls_roc_pr_curves.csv"),
    )
  ),
  # Pull confusion matrices for classification model performance assessment
  tar_file(
    name = performance_detections_cls_conf_mat,
    command = download_gfw_data(
      bq_billing_project,
      sql = "SELECT * FROM `world-fishing-827.proj_ocean_ghg.rf_s1_time_gridded_dark_fleet_model_performance_detections_cls_conf_mat_{run_version_dark}`" |>
        stringr::str_glue(
          run_version_dark = run_version_dark
        ),
      file_path = file.path("data", "gfw", "performance_detections_cls_conf_mat.csv"),
    )
  ),
  # Monthly summary of Co2 emissions for AIS-broadcasting fleet and non-broadcasting vessels,
  # broken apart by fishing and non-fishing vessels,
  # inside and outside the S1 footprint; and imaged and not imaged in the S1 footprint
  tar_file_read(
    name = monthly_aggregated_time_series,
    command = file.path("sql", "monthly_aggregated_time_series.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_dark = run_version_dark
        ),
      file_path = file.path("data", "gfw", "monthly_aggregated_time_series.csv"),
    ),
    format = "file"
  ),
  # Annual emissions data for AIS-broadcasting fleet and non-broadcasting vessels,
  # broken apart by fishing and non-fishing vessels
  # For all pollutants
  tar_file_read(
    name = annual_emissions_all_pollutants,
    command = file.path("sql", "annual_emissions_all_pollutants.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_dark = run_version_dark,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = file.path("data", "gfw", "annual_emissions_all_pollutants.csv"),
    ),
    format = "file"
  ),
  # Spatial gridded 2017 and 2024 emissions by pollutant
  # Aggregated across AIS-broadcasting and non-broadcasting fleets
  tar_file_read(
    name = total_spatial_emissions_by_pollutant,
    command = file.path("sql", "total_spatial_emissions_by_pollutant.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_dark = run_version_dark,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = file.path("data", "gfw", "total_spatial_emissions_by_pollutant.csv"),
    ),
    format = "file"
  ),
  # Disaggregated CO2 emissions between AIS-broadcasting and non-broadcasting fleets
  tar_file_read(
    name = total_spatial_co2_emissions_by_ocean,
    command = file.path("sql", "total_spatial_co2_emissions_by_ocean.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_dark = run_version_dark,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = file.path("data", "gfw", "total_spatial_co2_emissions_by_ocean.csv"),
    ),
    format = "file"
  ),
  # Disaggregated CO2 emissions between AIS-broadcasting and non-broadcasting fleets
  tar_file_read(
    name = annual_spatial_co2_emissions_ais_dark_by_fleet,
    command = file.path("sql", "annual_spatial_co2_emissions_ais_dark_by_fleet.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_dark = run_version_dark,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = file.path("data", "gfw", "annual_spatial_co2_emissions_ais_dark_by_fleet.csv"),
    ),
    format = "file"
  ),
  # Disaggregated dark CO2 emissions falling within and outside the S1 footprint
  tar_file_read(
    name = total_spatial_co2_emissions_dark_by_footprint,
    command = file.path("sql", "total_spatial_co2_emissions_dark_by_footprint.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_dark = run_version_dark,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = file.path("data", "gfw", "total_spatial_co2_emissions_dark_by_footprint.csv"),
    ),
    format = "file"
  ),
  # Download total monthly non-spatial emissions by pollutant
  tar_file_read(
    name = total_monthly_emissions_by_pollutant,
    command = file.path("sql", "total_monthly_emissions_by_pollutant.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_dark = run_version_dark,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = file.path("data", "gfw", "total_monthly_emissions_by_pollutant.csv")
    ),
    format = "file"
  ),
  # Pixels used for the training/testing split for assessing
  # performance outside the S1 footprint
  tar_file(
    name = pixels_for_offshore_training_testing_split,
    command = download_gfw_data(
      bq_billing_project,
      sql = "SELECT * FROM `world-fishing-827.proj_ocean_ghg.pixels_for_offshore_training_testing_split_{run_version_dark}`" |>
        stringr::str_glue(
          run_version_dark = run_version_dark
        ),
      file_path = file.path("data", "gfw", "pixels_for_offshore_training_testing_split.csv")
    )
  ),
  # For each pixel, count up number of months that are imaged by S1 and not imaged
  tar_file_read(
    name = number_s1_imaged_months_by_pixel,
    command = file.path("sql", "number_s1_imaged_months_by_pixel.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_dark = run_version_dark
        ),
      file_path = file.path("data", "gfw", "number_s1_imaged_months_by_pixel.csv")
    ),
    format = "file"
  ),
  # Get linear regression fit coefficients (from lm)
  # For other gas regressions to convert CO2 emissions to other gases
  tar_file(
    name = lm_other_gases_tidy_fit_stats,
    command = download_gfw_data(
      bq_billing_project,
      sql = "SELECT * FROM `world-fishing-827.proj_ocean_ghg.rf_s1_lm_other_gases_tidy_emissions_rgr_{run_version_dark}`" |>
        stringr::str_glue(
          run_version_dark = run_version_dark
        ),
      file_path = file.path("data", "gfw", "lm_other_gases_tidy_fit_stats.csv")
    )
  ),
  # Total annual port visit CO2 emissions by country and vessel class
  tar_file_read(
    name = port_visit_co2_emissions_by_country,
    command = file.path("sql", "port_visit_co2_emissions_by_country.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = file.path("data", "gfw", "port_visit_co2_emissions_by_country.csv")
    ),
    format = "file"
  ),
  # Total annual trip-level CO2 emissions by from- and to-country and vessel class
  tar_file_read(
    name = trip_co2_emissions_by_from_to_countries,
    command = file.path("sql", "trip_co2_emissions_by_from_to_countries.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = file.path("data", "gfw", "trip_co2_emissions_by_from_to_countries.csv")
    ),
    format = "file"
  ),
  # Annual AIS-broadcasting emissions and unique vessels by receiver type
  tar_file_read(
    name = annual_global_emissions_by_receiver_type,
    command = file.path("sql", "annual_global_emissions_by_receiver_type.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = file.path("data", "gfw", "annual_global_emissions_by_receiver_type.csv")
    ),
    format = "file"
  ),
  # Annual AIS-broadcasting emissions by receiver type and flag
  tar_file_read(
    name = annual_global_emissions_by_receiver_type_and_flag,
    command = file.path("sql", "annual_global_emissions_by_receiver_type_and_flag.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = file.path("data", "gfw", "annual_global_emissions_by_receiver_type_and_flag.csv")
    ),
    format = "file"
  ),
  # Spatial AIS-broadcasting emissions by receiver type for starting and ending years
  tar_file_read(
    name = annual_spatial_emissions_by_receiver_type,
    command = file.path("sql", "annual_spatial_emissions_by_receiver_type.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais,
          analysis_start_year = analysis_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = file.path("data", "gfw", "annual_spatial_emissions_by_receiver_type.csv")
    ),
    format = "file"
  ),
  # Get length and engine power of all vessels
  # For plotting this relationship
  tar_file_read(
    name = vessel_size_info,
    command = file.path("sql", "vessel_size_info.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais
        ),
      file_path = file.path("data", "gfw", "vessel_size_info.csv")
    ),
    format = "file"
  ),
  # Registered data validation
  tar_file_read(
    name = registered_validation_data,
    command = file.path("sql", "registered_data_validation.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais
        ),
      file_path = file.path("data", "registered_validation_data", "registered_validation_data.csv")
    ),
    format = "file"
  ),
  # Trip emissions to validate using MRV data
  tar_file_read(
    name = trip_emissions_for_mrv_validation,
    command = file.path("sql", "trip_emissions_for_mrv_validation.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais
        ),
      file_path = file.path("data", "MRV", "trip_emissions_for_mrv_validation.csv")
    ),
    format = "file"
  ),
  # Annual AIS activity summary by vessel class ----
  # Emissions alongside the activity behind them (distance, time, vessels,
  # pings), so our estimates can be compared with published inventories on
  # activity as well as on emissions.
  #
  # Split by vessel class as well as year, which also makes this the source for
  # the fleet-composition figures. It absorbed the former
  # n_vessels_by_year_and_class extract: that read the same ping table for the
  # class split of the vessel count alone, which meant no extract carried
  # emissions per class on the same scoping as the paper's annual totals.
  # Year-level consumers go through read_annual_ais_activity(), which collapses
  # the class rows back to one row per year.
  #
  # This series starts earlier than analysis_start_year to give the comparison a
  # longer activity baseline. It has its own start year target rather than moving
  # analysis_start_year, because that target feeds 17 other queries and changing
  # it would invalidate and re-run all of them.
  tar_target(
    name = activity_summary_start_year,
    command = 2015
  ),
  tar_file_read(
    name = annual_ais_activity_summary,
    command = file.path("sql", "annual_ais_activity_summary.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais,
          analysis_start_year = activity_summary_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = file.path("data", "gfw", "annual_ais_activity_summary.csv")
    ),
    format = "file"
  ),
  # The same summary read from the daily gridded table instead of the ping table,
  # and split by registry status as well as by vessel class.
  #
  # Same measures as the extract above except n_pings, which the daily table
  # cannot supply: a row there is one ssvid, date and grid cell rather than one
  # AIS message, so COUNT(*) counts cell-days. The other four measures are exact
  # rather than approximate - the daily table is a pre-aggregation of the same
  # ping-level emissions, so summing them reproduces the ping-level totals.
  #
  # Roughly 21x cheaper to scan (5.8 billion rows against 139 billion), which is
  # what makes the registry split affordable to carry alongside the class split.
  #
  # Shares activity_summary_start_year with the extract above so the two cover
  # the same window and can be compared row for row.
  tar_file_read(
    name = annual_ais_activity_summary_cheap,
    command = file.path("sql", "annual_ais_activity_summary_cheap.sql"),
    read = download_gfw_data(
      bq_billing_project,
      sql = readr::read_file(!!.x) |>
        stringr::str_glue(
          run_version_ais = run_version_ais,
          analysis_start_year = activity_summary_start_year,
          analysis_end_year = analysis_end_year
        ),
      file_path = file.path(
        "data",
        "gfw",
        "annual_ais_activity_summary_cheap.csv"
      )
    ),
    format = "file"
  )
)
