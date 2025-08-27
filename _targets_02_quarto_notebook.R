# Load packages required to define the pipeline:
library(targets)
library(tarchetypes) # Load other packages as needed.

# Set the targets pipeline, since this repo has multiple targets pipelines
Sys.setenv(TAR_PROJECT = "02_quarto_notebook")

# Run the R scripts in the R/ folder with your custom functions:
tar_source("r/functions.R")

list(
  # Load all GFW CSVs generated in _targets_01_gfw_data_pull.R ----
  tar_file_read(
    name = n_unique_vessels,
    command = here::here("data/gfw/n_unique_vessels.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = n_ais_messages,
    command = here::here("data/gfw/n_ais_messages.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = annual_emissions_all_pollutants,
    command = here::here("data/gfw/annual_emissions_all_pollutants.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = total_spatial_emissions_by_pollutant,
    command = here::here(
      "data/gfw/total_spatial_emissions_by_pollutant.csv"
    ),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = annual_ais_to_dark_activity_extrapolation,
    command = here::here(
      "data/gfw/annual_ais_to_dark_activity_extrapolation.csv"
    ),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = total_monthly_emissions_by_pollutant,
    command = here::here(
      "data/gfw/total_monthly_emissions_by_pollutant.csv"
    ),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = annual_ais_co2_emissions_by_vessel_type,
    command = here::here(
      "data/gfw/annual_ais_co2_emissions_by_vessel_type.csv"
    ),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = port_visit_co2_emissions_by_country,
    command = here::here(
      "data/gfw/port_visit_co2_emissions_by_country.csv"
    ),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = trip_co2_emissions_by_from_to_countries,
    command = here::here(
      "data/gfw/trip_co2_emissions_by_from_to_countries.csv"
    ),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = annual_non_broadcasting_detections_emissions,
    command = here::here(
      "data/gfw/annual_non_broadcasting_detections_emissions.csv"
    ),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = s1_mean_spatial_knn_ratios,
    command = here::here(
      "data/gfw/s1_mean_spatial_knn_ratios.csv"
    ),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = annual_global_emissions_by_receiver_type,
    command = here::here(
      "data/gfw/annual_global_emissions_by_receiver_type.csv"
    ),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = annual_global_emissions_by_receiver_type_and_flag,
    command = here::here(
      "data/gfw/annual_global_emissions_by_receiver_type_and_flag.csv"
    ),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = annual_spatial_emissions_by_receiver_type,
    command = here::here(
      "data/gfw/annual_spatial_emissions_by_receiver_type.csv"
    ),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = vessel_size_info,
    command = here::here(
      "data/gfw/vessel_size_info.csv"
    ),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = s1_ais_vessel_size_class_comparison,
    command = here::here(
      "data/gfw/s1_ais_vessel_size_class_comparison.csv"
    ),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = registered_validation_data,
    command = here::here(
      "data/registered_validation_data/registered_validation_data.csv"
    ),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = mrv_data_validation,
    command = here::here(
      "data/MRV/mrv_data_validation.csv"
    ),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = trip_emissions_for_mrv_validation,
    command = here::here(
      "data/MRV/trip_emissions_for_mrv_validation.csv"
    ),
    read = readr::read_csv(!!.x)
  ),
  # Load other data ----
  # EDGAR - Emissions Database for Global Atmospheric Research
  # From the European Commission
  # Annual totals by sector and country (1970-2023)
  # Downloaded from here: https://edgar.jrc.ec.europa.eu/dataset_ghg2024#p1
  # For each substance emission time series (1970-2023) by sector and country are provided in an overview table (.xlsx). Emission country totals are expressed in kton substance / year. The IPCC 1996 and 2006 codes are used for specification of the sectors.
  tar_file_read(
    name = annual_edgar_emissions,
    command = here::here(
      "data/IEA_EDGAR_CO2_1970_2023/IEA_EDGAR_CO2_1970_2023.xlsx"
    ),
    read = readxl::read_excel(!!.x, sheet = "IPCC 2006", skip = 9)
  ),
  # Render quarto notebook -----
  tar_quarto(
    name = quarto_notebook,
    path = "qmd/quarto_notebook.qmd",
    quiet = FALSE
  )
)
