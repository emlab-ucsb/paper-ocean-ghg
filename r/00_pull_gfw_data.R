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

#This function pulls the necessary GFW data and saves it locally as a CSVs
# This requires special BigQuery permissions to run, so it is not included in the main analysis pipeline

bq_project <- "world-fishing-827" # BQ project where data lives
billing_project <- "emlab-gcp" # emLab's billing project
bq_dataset <- "proj_ocean_ghg" # The dataset name for this project

run_version_ais <- "v20241121" # Define the version of the AIS dataset to pull
run_version_dark <- "v20250228" # Define the version of the dark fleet dataset to pull


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
  "sql/vessel_info_snp_match.sql",
  "vessel_info_snp_match"
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
