# Follow the comments below to fill in this target script.
# Then follow the manual to check and run the pipeline:
#   https://books.ropensci.org/targets/walkthrough.html#inspect-the-pipeline

# Setup ----
# Load packages required to define the pipeline:
library(targets)
library(tarchetypes) # Load other packages as needed.

# First determine if system is quebracho or sequoia, our GRIT servers. If so, set directory appropriately
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

# project_directory <- glue::glue("/Users/Shared/nextcloud/emLab/projects/current-projects/paper-ocean-ghg")

# Set targets store to appropriate GRIT/Nextcloud directory
tar_config_set(project = "base_pipeline",
               script= "_targets.R",
               store = glue::glue("{project_directory}/data/_targets"))

# Set target options:
tar_option_set(
  packages = c("dplyr","tidyr", "bigrquery", "quarto"),
  format = "rds" # default storage format
)
# Run the R scripts in the R/ folder with your custom functions:
tar_source("r/functions.R")
# source("other_functions.R") # Source other scripts as needed.

# Set BigQuery project, billing project, and dataset
bq_dataset <- "proj_ocean_ghg"
bq_project <- "world-fishing-827"
billing_project <- "emlab-gcp"

# Do this to help with BigQuery downloading
options(scipen = 20)

# AIS-based emissions model ----
# List of targets
# This first target renders the quarto project book
# Any time you make changes to anything in the qmd directory (e.g., to methods.qmd)
# this target will re-render the book
list(
  tar_target(
    # Define the version of the AIS dataset to pull
    name = run_version_ais,
    "_v20241121"
  ),
  # Define the version of the dark fleet dataset to pull
  tar_target(
    name = run_version_dark,
    "_v20250116" 
  ),
  tar_target(
    name = run_version_dark_fleet,
    "_v20250228" 
  ),
  # Define monthly_ais_vessels_and_ratios_by_pixel query path
  tar_target(
    name = monthly_ais_vessels_and_ratios_by_pixel_sql_file,
    "sql/monthly_ais_vessels_and_ratios_by_pixel.sql",
    format = "file"
  ),
  # Generate BQ monthly_ais_vessels_and_ratios_by_pixel table
  tar_target(
    name = monthly_ais_vessels_and_ratios_by_pixel_bq,
    run_gfw_query_and_save_table(sql = monthly_ais_vessels_and_ratios_by_pixel_sql_file %>% readr::read_file(),
                                 bq_table_name = glue::glue("monthly_ais_vessels_and_ratios_by_pixel", run_version_dark), 
                                 bq_dataset = bq_dataset,
                                 billing_project = billing_project, 
                                 bq_project = bq_project,
                                 write_disposition = 'WRITE_TRUNCATE',
                                 # Re-run this target if targets below change
                                 monthly_ais_vessels_and_ratios_by_pixel_sql_file)
  ),
  # Pull monthly_ais_vessels_and_ratios_by_pixel data locally
  tar_target(
    name = monthly_ais_vessels_and_ratios_by_pixel,
    pull_gfw_data_locally(billing_project = billing_project,
                          bq_dataset = bq_dataset,
                          bq_table_name = glue::glue("monthly_ais_vessels_and_ratios_by_pixel", run_version_dark),
                          # Re-run this target if targets below change
                          monthly_ais_vessels_and_ratios_by_pixel_bq)
  ),
  # Define monthly_ais_vessels_and_ratios query path
  tar_target(
    name = monthly_ais_vessels_and_ratios_sql_file,
    "sql/monthly_ais_vessels_and_ratios.sql",
    format = "file"
  ),
  # Generate BQ monthly_ais_vessels_and_ratios table
  tar_target(
    name = monthly_ais_vessels_and_ratios_bq,
    run_gfw_query_and_save_table(sql = monthly_ais_vessels_and_ratios_sql_file %>% readr::read_file(),
                                 bq_table_name = glue::glue("monthly_ais_vessels_and_ratios", run_version_dark), 
                                 bq_dataset = bq_dataset,
                                 billing_project = billing_project, 
                                 bq_project = bq_project,
                                 write_disposition = 'WRITE_TRUNCATE',
                                 # Re-run this target if targets below change
                                 monthly_ais_vessels_and_ratios_sql_file)
  ),
  # Pull monthly_ais_vessels_and_ratios data locally
  tar_target(
    name = monthly_ais_vessels_and_ratios,
    pull_gfw_data_locally(billing_project = billing_project,
                          bq_dataset = bq_dataset,
                          bq_table_name = glue::glue("monthly_ais_vessels_and_ratios", run_version_dark),
                          # Re-run this target if targets below change
                          monthly_ais_vessels_and_ratios_bq)
  ),
  tar_target(
    name = s1_knn_ratios_within_footprint,
    pull_gfw_data_locally(billing_project = billing_project,
                          bq_dataset = bq_dataset,
                          bq_table_name = glue::glue("s1_knn_ratios_within_footprint", run_version_dark_fleet)
    )
  ),
  tar_target(
    name = s1_knn_ratios_outside_footprint,
    pull_gfw_data_locally(billing_project = billing_project,
                          bq_dataset = bq_dataset,
                          bq_table_name = glue::glue("s1_knn_ratios_outside_footprint", run_version_dark_fleet)
    )
  ),
  tar_target(
    name = s1_dark_fleet_model_results,
    pull_gfw_data_locally(billing_project = billing_project,
                          bq_dataset = bq_dataset,
                          bq_table_name = glue::glue("s1_time_gridded_dark_fleet_model", run_version_dark_fleet)
    )
  ),
  tar_target(
    name = s1_summarized_dark_fleet_ratios_spatial,
    summarize_dark_fleet_ratios_spatial(s1_dark_fleet_model_results)
  ), 
  tar_target(
    name = s1_summarized_dark_fleet_model_results_emissions_year,
    summarize_dark_fleet_model_results_emissions(s1_dark_fleet_model_results, time_extrapolation  = "YEAR")
  )
  # ,
  # # Make quarto notebook -----
  # tar_quarto(
  #   name = quarto_book,
  #   path = "qmd",
  #   quiet = FALSE
  # )
  

  
)