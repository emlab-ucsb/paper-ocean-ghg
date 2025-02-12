data_directory_base <-  ifelse(Sys.info()["nodename"] == "quebracho" | Sys.info()["nodename"] == "sequoia",
                               "/home/emlab",
                               # Otherwise, set the directory for local machines based on the OS
                               # If using Mac OS, the directory will be automatically set as follows
                               ifelse(Sys.info()["sysname"]=="Darwin",
                                      "/Users/Shared/nextcloud/emLab",
                                      # If using Windows, the directory will be automatically set as follows
                                      ifelse(Sys.info()["sysname"]=="Windows",
                                             "G:/Shared\ drives/nextcloud/emLab",
                                             # If using Linux, will need to manually modify the following directory path based on their user name
                                             # Replace your_username with your local machine user name
                                             "/home/your_username/Nextcloud")))

project_directory <- glue::glue("{data_directory_base}/projects/current-projects/paper-ocean-ghg")

#This function pulls the necessary GFW data and saves it locally as a CSVs
# This requires special BigQuery permissions to run, so it is not included in the main analysis pipeline

bq_project <- "world-fishing-827" # BQ project where data lives
billing_project <- "emlab-gcp" # emLab's billing project
bq_dataset <- "proj_ocean_ghg" # The dataset name for this project

run_version_ais <- "v20241121"# Define the version of the AIS dataset to pull
run_version_dark <- "v20250116" # Define the version of the dark fleet dataset to pull


# Function to download GFW data and save it in repo
download_gfw_data <- function(query_file_name,file_output_name) {
  
  query <- query_file_name |>
    readr::read_file() |>
    stringr::str_glue(bq_project = bq_project,
                      bq_dataset = bq_dataset,
                      run_version_dark = run_version_dark,
                      run_version_ais = run_version_ais) 
  
  bigrquery::bq_project_query(billing_project, query) |>
    bigrquery::bq_table_download(n_max = Inf) |>
    readr::write_csv(glue::glue("{project_directory}/data/processed/{file_output_name}.csv"))
}

# Annual CO2 emissions data for AIS-broadcasting fleet and dark fleet
download_gfw_data("sql/annual_co2_emissions.sql",
                  "annual_co2_emissions")

# Annual AIS-based CO2 emissions, hours, average speed, and main engine power by vessel
download_gfw_data("sql/annual_ais_co2_emissions_by_vessel.sql",
                  "annual_ais_co2_emissions_by_vessel")

# Annual spatial CO2 emissions, for AIS and dark fleets
download_gfw_data("sql/annual_spatial_co2_emissions_ais_dark.sql",
                  "annual_spatial_co2_emissions_ais_dark")

# Annual global emissions and number of unique vessels by receiver type (satellite; dynamic; or terrestrial)
download_gfw_data("sql/annual_global_emissions_by_receiver_type.sql",
                  "annual_global_emissions_by_receiver_type")

# Monthly global emissions and number of unique vessels by receiver type (satellite; dynamic; or terrestrial) and flag
download_gfw_data("sql/annual_global_emissions_by_receiver_type_and_flag.sql",
                  "annual_global_emissions_by_receiver_type_and_flag")

# Annual spatial CO2 emissions, for AIS fleets, with speeds from trip level information (TESTING)
download_gfw_data("sql/annual_ais_co2_emissions_from_trips_dataset.sql",
                  "annual_ais_co2_emissions_from_trips_dataset")

# Annual spatial CO2 emissions vt receiver type  (satellite; dynamic; or terrestrial)
download_gfw_data("sql/annual_spatial_emissions_by_receiver_type.sql",
                  "annual_spatial_emissions_by_receiver_type")

# Monthly extrapolation of AIS activity to dark activity
# Use method we use for extrapolating emissions (by pixel, month, fishing, and vessel size class)
# To also extrapolate hours, kw-hours, and speed
download_gfw_data("sql/monthly_ais_to_dark_activity_extrapolation.sql",
                  "monthly_ais_to_dark_activity_extrapolation")

