#' GFW Data Extraction Script
#'
#' This script handles the extraction of Global Fishing Watch data from BigQuery
#' and saves it locally as CSV files. This is a standalone script that requires
#' special BigQuery permissions and is not included in the main analysis pipeline
#' due to access and cost considerations.
#'
#' Purpose:
#' - Extract AIS vessel tracking data from GFW BigQuery datasets
#' - Download vessel characteristics and emission factor data
#' - Process and save data locally for use in analysis pipeline
#'
#' Prerequisites:
#' - Access to GFW data in BigQuery (world-fishing-827 project)
#' - emLab billing project permissions
#' - Sufficient BigQuery quota for large data extractions
#'
#' Note: This script is typically run once to extract data, then the analysis
#' pipeline uses the saved CSV files to avoid repeated expensive BigQuery operations.

# Cross-platform directory configuration
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

# BigQuery configuration for GFW data extraction
# This requires special BigQuery permissions to run, so it is not included in the main analysis pipeline

bq_project <- "world-fishing-827" # BQ project where data lives
billing_project <- "emlab-gcp" # emLab's billing project
bq_dataset <- "proj_ocean_ghg" # The dataset name for this project

run_version_ais <- "v20250701" # Define the version of the AIS dataset to pull
run_version_dark <- "v20250701" # Define the version of the dark fleet dataset to pull


# Function to download GFW data and save it in repo
download_gfw_data <- function(query_file_name, file_output_name) {
  query <- query_file_name |>
    readr::read_file() |>
    stringr::str_glue(
      bq_project = bq_project,
      bq_dataset = bq_dataset,
      run_version_dark = run_version_dark,
      run_version_ais = run_version_ais
    )

  bigrquery::bq_project_query(billing_project, query) |>
    bigrquery::bq_table_download(n_max = Inf) |>
    readr::write_csv(glue::glue(
      "{project_directory}/data/processed/{file_output_name}.csv"
    ))
}

# Number of unique AIS messages for which we estimate AIS emissions
# From 2016-2024
download_gfw_data(
  "sql/n_ais_messages.sql",
  "n_ais_messages"
)

# Number of unique vessels for which we estimate AIS emissions
# From 2016-2024
download_gfw_data(
  "sql/n_unique_vessels.sql",
  "n_unique_vessels"
)


# Annual emissions data for AIS-broadcasting fleet and dark fleet,
# broken apart by fishing and non-fishing vessels
# For all pollutants
download_gfw_data(
  "sql/annual_emissions_all_pollutants.sql",
  "annual_emissions_all_pollutants"
)

# Annual AIS-based CO2 emissions, hours, average speed, and main engine power by vessel
download_gfw_data(
  "sql/annual_ais_co2_emissions_by_vessel.sql",
  "annual_ais_co2_emissions_by_vessel"
)

# Annual spatial CO2 emissions, for AIS and dark fleets
download_gfw_data(
  "sql/annual_spatial_co2_emissions_ais_dark.sql",
  "annual_spatial_co2_emissions_ais_dark"
)

# Annual global emissions and number of unique vessels by receiver type (satellite; dynamic; or terrestrial)
download_gfw_data(
  "sql/annual_global_emissions_by_receiver_type.sql",
  "annual_global_emissions_by_receiver_type"
)

# Monthly global emissions and number of unique vessels by receiver type (satellite; dynamic; or terrestrial) and flag
download_gfw_data(
  "sql/annual_global_emissions_by_receiver_type_and_flag.sql",
  "annual_global_emissions_by_receiver_type_and_flag"
)

# Annual spatial CO2 emissions, for AIS fleets, with speeds from trip level information (TESTING)
download_gfw_data(
  "sql/annual_ais_co2_emissions_from_trips_dataset.sql",
  "annual_ais_co2_emissions_from_trips_dataset"
)

# Annual spatial CO2 emissions vt receiver type  (satellite; dynamic; or terrestrial)
download_gfw_data(
  "sql/annual_spatial_emissions_by_receiver_type.sql",
  "annual_spatial_emissions_by_receiver_type"
)

# Annual extrapolation of AIS activity to dark activity
# Use method we use for extrapolating emissions (by pixel, month, fishing, and vessel size class)
# To also extrapolate hours, kw-hours
# Also get average speed, assuming they are same for dark and AIS (by pixel, month, fishing, and vessel size class)
download_gfw_data(
  "sql/annual_ais_to_dark_activity_extrapolation.sql",
  "annual_ais_to_dark_activity_extrapolation"
)


# Download total spatial emissions by pollutant for 2024
download_gfw_data(
  "sql/total_spatial_emissions_by_pollutant_2024.sql",
  "total_spatial_emissions_by_pollutant_2024"
)

# Download total monthly non-spatial emissions by pollutant
download_gfw_data(
  "sql/total_monthly_emissions_by_pollutant.sql",
  "total_monthly_emissions_by_pollutant"
)

# Download KNN testing data
download_gfw_data(
  "sql/knn_performance_testing.sql",
  "knn_performance_testing"
)

run_knn_by_year_sql <- function(
  run_version_dark,
  query_file_name,
  file_output_name
) {
  years <- 2016:2024

  results <- purrr::map_dfr(
    years,
    function(yr) {
      message("Running year: ", yr)
      query <- query_file_name |>
        readr::read_file() |>
        stringr::str_glue(
          bq_project = bq_project,
          bq_dataset = bq_dataset,
          run_version_dark = run_version_dark,
          year = yr
        )

      bigrquery::bq_project_query(billing_project, query) |>
        bigrquery::bq_table_download(n_max = Inf)
    }
  )

  readr::write_csv(
    results,
    glue::glue("{project_directory}/data/processed/{file_output_name}.csv")
  )
}


run_knn_by_year_sql(
  run_version_dark = "v20250701",
  query_file_name = "sql/knn_performance_testing_by_year.sql",
  file_output_name = "knn_neighbors_2016_2024"
)


run_knn_by_year_month_sql <- function(
  run_version_dark,
  query_file_name,
  file_output_name
) {
  years <- 2016:2024
  months <- 1:12

  results <- purrr::cross_df(list(year = years, month = months)) |>
    dplyr::mutate(
      data = purrr::pmap(
        list(year, month),
        function(yr, mo) {
          message("Running year: ", yr, " month: ", mo)
          query <- query_file_name |>
            readr::read_file() |>
            stringr::str_glue(
              bq_project = bq_project,
              bq_dataset = bq_dataset,
              run_version_dark = run_version_dark,
              year = yr,
              month = mo
            )

          bigrquery::bq_project_query(billing_project, query) |>
            bigrquery::bq_table_download(n_max = Inf)
        }
      )
    )

  combined_results <- dplyr::bind_rows(results$data)

  readr::write_csv(
    combined_results,
    glue::glue("{project_directory}/data/processed/{file_output_name}.csv")
  )
}


run_knn_by_year_month_sql(
  run_version_dark = "v20250701",
  query_file_name = "sql/knn_performance_testing_by_month.sql",
  file_output_name = "knn_neighbors_by_month_2016_2024"
)


# Download S&P consumption data for valiadtion
pull_gfw_data_locally(
  bq_table_name = "snp_fuel_consumption_v20250404",
  bq_dataset,
  billing_project
) |>
  readr::write_csv(glue::glue(
    "{project_directory}/data/processed/snp_fuel_consumption_v20250404.csv"
  ))


download_gfw_data(
  "sql/vessel_info_snp_match.sql", # using vessel_info_v20241121
  "vessel_info_snp_match"
)

download_gfw_data(
  "sql/vessel_info_snp_match.sql", # using vessel_info_rf_experimental_v20250516
  "vessel_info_snp_match_updated_metadata"
)

download_gfw_data(
  "sql/vessel_info_snp_match_extended.sql",
  "vessel_info_snp_match_extended"
)


# Download MRV EU validation data
pull_gfw_data_locally(
  bq_table_name = "eu_validation_data_v20241121",
  bq_dataset,
  billing_project
) |>
  readr::write_csv(glue::glue(
    "{project_directory}/data/processed/eu_validation_data_v20241121.csv"
  ))

pull_gfw_data_locally(
  bq_table_name = "eu_validation_trip_v20241121",
  bq_dataset,
  billing_project
) |>
  readr::write_csv(glue::glue(
    "{project_directory}/data/processed/eu_validation_trip_v20241121.csv"
  ))

pull_gfw_data_locally(
  bq_table_name = "eu_validation_port_v20241121",
  bq_dataset,
  billing_project
) |>
  readr::write_csv(glue::glue(
    "{project_directory}/data/processed/eu_validation_port_v20241121.csv"
  ))


# Download trip emissions estimates to replicate ICCT validation
download_gfw_data(
  "sql/annual_trip_emissions_estimates_for_validation.sql",
  "annual_trip_emissions_estimates_for_validation"
)


# Testing the new model (v07012025) vs the old model (v11212024)

download_gfw_data(
  "sql/new_model_comparison_all_pollutants.sql",
  "new_model_comparison_all_pollutants"
)

download_gfw_data(
  "sql/new_model_comparison_voyages.sql",
  "new_model_comparison_voyages"
)

download_gfw_data(
  "sql/new_model_comparison_port_visits.sql",
  "new_model_comparison_port_visits"
)

download_gfw_data(
  "sql/new_model_comparison_ct_schema.sql",
  "new_model_comparison_ct_schema"
)


download_gfw_data(
  "sql/new_monthly_data.sql",
  "new_monthly_data"
)

download_gfw_data(
  "sql/old_monthly_data.sql",
  "old_monthly_data"
)
