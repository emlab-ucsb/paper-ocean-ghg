# Load packages required to define the pipeline:
library(targets)
library(tarchetypes) # Load other packages as needed.
library(quarto) # tar_quarto() renders through this, so declare it for renv

# Set the targets pipeline, since this repo has multiple targets pipelines
Sys.setenv(TAR_PROJECT = "02_quarto_notebook")

# Run the R scripts in the R/ folder with your custom functions:
tar_source("r/functions.R")

list(
  # Load all GFW CSVs generated in _targets_01_gfw_data_pull.R ----
  tar_file_read(
    name = n_unique_vessels,
    command = file.path("data", "gfw", "n_unique_vessels.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = n_ais_messages,
    command = file.path("data", "gfw", "n_ais_messages.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = fraction_vessels_emissions_by_registry_info,
    command = file.path("data", "gfw", "fraction_vessels_emissions_by_registry_info.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = ping_level_hours_distribution,
    command = file.path("data", "gfw", "ping_level_hours_distribution.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = n_s1_detections,
    command = file.path("data", "gfw", "n_s1_detections.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = s1_time_series,
    command = file.path("data", "gfw", "s1_time_series.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = length_size_bin_distributions,
    command = file.path("data", "gfw", "length_size_bin_distributions.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = all_performance_metrics,
    command = file.path("data", "gfw", "all_performance_metrics.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = all_varimp_data,
    command = file.path("data", "gfw", "all_varimp_data.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = performance_detections_cls_roc_pr_curves,
    command = file.path("data", "gfw", "performance_detections_cls_roc_pr_curves.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = performance_detections_cls_conf_mat,
    command = file.path("data", "gfw", "performance_detections_cls_conf_mat.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = monthly_aggregated_time_series,
    command = file.path("data", "gfw", "monthly_aggregated_time_series.csv"),
    read = readr::read_csv(!!.x)
  ),

  tar_file_read(
    name = annual_emissions_all_pollutants,
    command = file.path("data", "gfw", "annual_emissions_all_pollutants.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = total_spatial_emissions_by_pollutant,
    command = file.path("data", "gfw", "total_spatial_emissions_by_pollutant.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = total_spatial_co2_emissions_by_ocean,
    command = file.path("data", "gfw", "total_spatial_co2_emissions_by_ocean.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = total_monthly_emissions_by_pollutant,
    command = file.path("data", "gfw", "total_monthly_emissions_by_pollutant.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = number_s1_imaged_months_by_pixel,
    command = file.path("data", "gfw", "number_s1_imaged_months_by_pixel.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = lm_other_gases_tidy_fit_stats,
    command = file.path("data", "gfw", "lm_other_gases_tidy_fit_stats.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = port_visit_co2_emissions_by_country,
    command = file.path("data", "gfw", "port_visit_co2_emissions_by_country.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = trip_co2_emissions_by_from_to_countries,
    command = file.path("data", "gfw", "trip_co2_emissions_by_from_to_countries.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = annual_global_emissions_by_receiver_type,
    command = file.path("data", "gfw", "annual_global_emissions_by_receiver_type.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = annual_global_emissions_by_receiver_type_and_flag,
    command = file.path("data", "gfw", "annual_global_emissions_by_receiver_type_and_flag.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = annual_spatial_emissions_by_receiver_type,
    command = file.path("data", "gfw", "annual_spatial_emissions_by_receiver_type.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = annual_spatial_co2_emissions_ais_dark_by_fleet,
    command = file.path("data", "gfw", "annual_spatial_co2_emissions_ais_dark_by_fleet.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = annual_spatial_co2_emissions_by_vessel_class_family,
    command = file.path("data", "gfw", "annual_spatial_co2_emissions_by_vessel_class_family.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = annual_co2_emissions_by_vessel_class,
    command = file.path("data", "gfw", "annual_co2_emissions_by_vessel_class.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = total_spatial_co2_emissions_dark_by_footprint,
    command = file.path("data", "gfw", "total_spatial_co2_emissions_dark_by_footprint.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = vessel_size_info,
    command = file.path("data", "gfw", "vessel_size_info.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = registered_validation_data,
    command = file.path("data", "registered_validation_data", "registered_validation_data.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_target(
    name = mrv_raw_files,
    command = list.files(file.path("data", "MRV", "raw"), full.names = TRUE),
    format = "file"
  ),
  tar_target(
    name = mrv_data_validation,
    command = combine_EU_data(mrv_raw_files)
  ),
  tar_file_read(
    name = trip_emissions_for_mrv_validation,
    command = file.path("data", "MRV", "trip_emissions_for_mrv_validation.csv"),
    read = readr::read_csv(!!.x)
  ),
  # Load other data ----
  # EDGAR - Emissions Database for Global Atmospheric Research
  # From the European Commission
  # Annual totals by sector and country (1970-2024)
  # Downloaded from here:https://edgar.jrc.ec.europa.eu/dataset_ghg2025
  # For each substance emission time series (1970-2024) by sector and country are provided in an overview table (.xlsx). Emission country totals are expressed in kton substance / year. The IPCC 1996 and 2006 codes are used for specification of the sectors.
  tar_file_read(
    name = annual_edgar_emissions,
    command = file.path("data", "IEA_EDGAR_CO2_1970_2024", "IEA_EDGAR_CO2_1970_2024.xlsx"),
    read = readxl::read_excel(!!.x, sheet = "IPCC 2006", skip = 9)
  ),
  # Downloaded from here on August 27, 2025: https://data-explorer.oecd.org/vis?fs[0]=Topic%2C1%7CEnvironment%20and%20climate%20change%23ENV%23%7CAir%20and%20climate%23ENV_AC%23&pg=0&fc=Topic&bp=true&snb=17&df[ds]=dsDisseminateFinalDMZ&df[id]=DSD_MARITIME_TRANSPORT%40DF_MARITIME_TRANSPORT&df[ag]=OECD.SDD.NAD.SEEA&df[vs]=1.0&dq=W.A......ALL_VESSELS&pd=2019%2C2024&to[TIME_PERIOD]=false&vw=tb&isAvailabilityDisabled=false
  tar_file_read(
    name = oecd_data,
    command = file.path("data", "oecd", "annual_oecd_experimental_data.csv"),
    read = readr::read_csv(!!.x) |>
      dplyr::select(year = TIME_PERIOD, emissions_co2_mt = OBS_VALUE) |>
      dplyr::mutate(data_source = "OECD")
  ),
  # Data sources table, for model feature table in supplement
  tar_file_read(
    name = data_sources,
    command = file.path("data", "data_sources.csv"),
    read = readr::read_csv(!!.x)
  ),
  # Data sources table, for model feature table in supplement
  tar_file_read(
    name = pixels_for_offshore_training_testing_split,
    command = file.path("data", "gfw", "pixels_for_offshore_training_testing_split.csv"),
    read = readr::read_csv(!!.x)
  ),
  # Inventories comparison inputs ----
  # CSVs written by _targets_03_inventories_comparison.R, which does the data
  # work for the "Inventories comparison" section of the notebook. Read here so
  # the notebook re-renders when an extract changes, the same contract as every
  # other series above; the figures themselves are drawn in the notebook.
  #
  # The dependency crosses stores, so targets cannot see it: run
  # 03_inventories_comparison before this pipeline when those inputs change.
  # Loaded under an SI-specific name: the notebook already builds a variable
  # called all_inventory_data for its own inventory figure, and a tar_load()ed
  # object of the same name would be overwritten by it.
  tar_file_read(
    name = si_all_inventory_data,
    command = file.path("data", "inventories", "all_inventory_data.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = multisector_inventory_data,
    command = file.path("data", "inventories", "multisector_inventory_data.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = inventory_intensity_all_models,
    command = file.path(
      "data",
      "inventories",
      "inventory_intensity_all_models.csv"
    ),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = inventory_vessel_counts_by_registry,
    command = file.path(
      "data",
      "inventories",
      "si_inventory_comparison",
      "inventory_vessel_counts_by_registry.csv"
    ),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = gfw_edgar_marine_emissions,
    command = file.path("data", "gfw", "gfw_edgar_marine_emissions.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = gfw_registry_emissions,
    command = file.path("data", "gfw", "gfw_registry_emissions.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = registry_shares_by_year,
    command = file.path("data", "gfw", "registry_shares_by_year.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = fleet_shares_by_year,
    command = file.path("data", "gfw", "fleet_shares_by_year.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = fleet_growth_by_year_data,
    command = file.path("data", "gfw", "fleet_growth_by_year.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = s1_detections_by_fixed_length_bin,
    command = file.path("data", "gfw", "s1_detections_by_fixed_length_bin.csv"),
    read = readr::read_csv(!!.x)
  ),
  # Feeds the two S1 detection-density figures. The extract is committed rather
  # than pulled: its query scans several GB and the result is settled.
  tar_file_read(
    name = s1_detection_density_by_denominator,
    command = file.path(
      "data",
      "gfw",
      "s1_detection_density_by_denominator.csv"
    ),
    read = readr::read_csv(!!.x)
  ),
  # Activity extracts from 01_gfw_data_pull, read straight from the CSV the way
  # the plotting code used to
  tar_file_read(
    name = annual_ais_activity_summary,
    command = file.path("data", "gfw", "annual_ais_activity_summary.csv"),
    read = readr::read_csv(!!.x)
  ),
  tar_file_read(
    name = annual_ais_activity_summary_cheap,
    command = file.path("data", "gfw", "annual_ais_activity_summary_cheap.csv"),
    read = readr::read_csv(!!.x)
  ),
  # Render quarto notebook -----
  tar_quarto(
    name = quarto_notebook,
    path = "qmd/quarto_notebook.qmd",
    quiet = FALSE
  )
)
