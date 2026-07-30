# Load packages required to define the pipeline:
library(targets)
library(tarchetypes) # Load other packages as needed.
library(ecmwfr) # CAMS downloads go through this, so declare it for renv
library(ncdf4) # NetCDF grids are read through this, so declare it for renv

# Set the targets pipeline, since this repo has multiple targets pipelines
Sys.setenv(TAR_PROJECT = "03_inventories_comparison")

# Run the R scripts in the R/ folder with your custom functions:
tar_source("r/functions.R")

# This pipeline downloads published emissions inventories from their public
# sources, processes them onto a common schema, and writes tidy CSVs to
# data/inventories/ that 02_quarto_notebook reads back in for the comparison
# analysis.
#
# Raw inventory downloads are deliberately not kept: the source grids are large
# and we only need a handful of annual numbers from them, so each year is
# downloaded to a temporary file, aggregated, and deleted in the same target.
# Only the small processed CSVs are stored in the repo. Expect roughly 900 MB of
# transient download and ~25 seconds of aggregation per CAMS year.
#
# The CAMS targets need an Atmosphere Data Store personal access token, taken
# from https://ads.atmosphere.copernicus.eu/profile and stored once with:
#
#   ecmwfr::wf_set_key()
#
# That writes the token to the keyring under service "ecmwfr", which is where
# wf_request() looks for it. Note that wf_get_key(service = "ads") will not find
# it - the service argument refers to a different, older storage layout.

list(
  # CAMS-GLOB-SHIP (STEAM model) ----
  # Global gridded shipping emissions from the Ship Traffic Emission Assessment
  # Model (STEAM), produced by the Finnish Meteorological Institute and served
  # from the Copernicus Atmosphere Data Store:
  # https://ads.atmosphere.copernicus.eu/datasets/cams-global-emission-inventories
  #
  # Each year is a ~885 MB zip holding one NetCDF of daily flux in kg m-2 s-1 on
  # a 0.1 degree grid (365 x 1800 x 3600). The file records STEAM 4.2.5 as the
  # underlying model version, and covers emissions released at stack heights of
  # 0-100 m. Reference: Jalkanen, Johansson et al. 2012.
  #
  # The results themselves are STEAM model output, so the downstream targets are
  # named for STEAM. The version target keeps the CAMS name because v3.2 is the
  # CAMS product version, which is what the ADS request is keyed on - it is not
  # the STEAM version, which the file records separately as STEAM 4.2.5.
  #
  # v3.2 is the most recent version carrying carbon_dioxide for the shipping
  # source. It covers 2000-2021, so this series ends in 2021 - earlier than
  # analysis_end_year and earlier than edgar_comparison_year. Bump these targets
  # when CAMS publishes a newer version or additional years.
  tar_target(
    name = cams_ship_version,
    command = "v3.2"
  ),
  tar_target(
    name = steam_ship_years,
    command = as.character(2017:2021)
  ),
  # One year per branch: download to a temp file, area-weight the grid cells and
  # sum to a global annual total in Mt CO2, then drop the NetCDF. Branching by
  # year keeps peak disk use to a single year's grid and lets one year be
  # re-run without re-downloading the rest.
  tar_target(
    name = steam_ship_annual_emissions_by_year,
    command = summarize_cams_ship_co2(
      year = steam_ship_years,
      version = cams_ship_version
    ),
    pattern = map(steam_ship_years)
  ),
  # Write the tidy series that 02_quarto_notebook reads back in
  tar_target(
    name = steam_ship_annual_emissions_file,
    command = write_inventory_csv(
      steam_ship_annual_emissions_by_year,
      file.path("data", "steam", "steam_ship_annual_emissions.csv")
    ),
    format = "file"
  )

  ,

  # SEIM (Shipping Emission Inventory Model) ----
  # Global shipping emissions from SEIM, developed at Tsinghua University and
  # published on Zenodo: https://zenodo.org/records/11069531
  # Wen, Wang, He, Liu, Luo, He (2024), CC-BY-4.0.
  #
  # The record also holds 0.1 degree daily grids, but we read the tidy daily
  # time series instead: it is 25 MB rather than up to 2.6 GB and already carries
  # absolute emissions in metric tonnes, so no area weighting is needed.
  #
  # The time series covers 2016-2021 (the 2013 data exists only as grids), so
  # like STEAM this series ends in 2021 - short of analysis_end_year and of
  # edgar_comparison_year.
  tar_target(
    name = seim_ship_years,
    command = as.character(2017:2021)
  ),
  tar_target(
    name = seim_ship_annual_emissions,
    command = summarize_seim_ship_co2(years = seim_ship_years)
  ),
  tar_target(
    name = seim_ship_annual_emissions_file,
    command = write_inventory_csv(
      seim_ship_annual_emissions,
      file.path("data", "seim", "seim_ship_annual_emissions.csv")
    ),
    format = "file"
  )

  ,

  # ICCT ----
  # The International Council on Clean Transportation's systematic assessment of
  # global shipping emissions, published as a supplemental workbook alongside
  # "Greenhouse gas emissions and air pollution from global shipping, 2016-2023":
  # https://theicct.org/publication/greenhouse-gas-emissions-and-air-pollution-from-global-shipping-2016-2023-apr25/
  #
  # A 96 KB workbook with one sheet per year, each holding 20 ship classes with
  # CO2 already in tonnes, so this is a small download and a straight sum.
  #
  # Unlike STEAM and SEIM this inventory runs to 2023, so it is the only one of
  # the three that reaches within a year of edgar_comparison_year.
  tar_target(
    name = icct_ship_years,
    command = as.character(2017:2023)
  ),
  tar_target(
    name = icct_ship_annual_emissions,
    command = summarize_icct_ship_co2(years = icct_ship_years)
  ),
  tar_target(
    name = icct_ship_annual_emissions_file,
    command = write_inventory_csv(
      icct_ship_annual_emissions,
      file.path("data", "icct", "icct_ship_annual_emissions.csv")
    ),
    format = "file"
  )

  ,

  # OECD ----
  # The OECD's experimental maritime transport CO2 statistics, taken from the
  # SDMX API so the series updates with the pipeline rather than being a manual
  # export:
  # https://data-explorer.oecd.org/vis?df[id]=DSD_MARITIME_TRANSPORT%40DF_MARITIME_TRANSPORT
  #
  # This supersedes data/oecd/annual_oecd_experimental_data.csv, which
  # 02_quarto_notebook still reads: that file is a hand-downloaded extract of
  # dataflow v1.0, while this pulls v2.0, which revises the values and adds a
  # methodology dimension. Point the notebook at this target to move over.
  #
  # The series starts in 2019 - later than the other inventories - but runs to
  # 2025, so it is the only one covering the full GFW analysis window.
  tar_target(
    name = oecd_ship_years,
    command = as.character(2019:2025)
  ),
  tar_target(
    name = oecd_ship_annual_emissions,
    command = summarize_oecd_ship_co2(years = oecd_ship_years)
  ),
  tar_target(
    name = oecd_ship_annual_emissions_file,
    command = write_inventory_csv(
      oecd_ship_annual_emissions,
      file.path("data", "oecd", "oecd_ship_annual_emissions.csv")
    ),
    format = "file"
  )

  ,

  # Inventory comparison figure ----
  # An extended version of the notebook's Figure S4: the same GFW / EDGAR / OECD
  # / IMO comparison, plus the inventories this pipeline downloads (STEAM, SEIM,
  # ICCT) and MariTEAM.
  #
  # The GFW and EDGAR series are derived inside qmd/quarto_notebook.qmd rather
  # than being targets, so gfw_edgar_marine_co2() reads the upstream targets from
  # the 02_quarto_notebook and 01_gfw_data_pull stores and repeats that
  # aggregation. This pipeline therefore depends on 02_quarto_notebook having
  # been run; because the dependency crosses stores, targets cannot see it, so
  # this target will not invalidate on its own when those upstream targets change.
  tar_target(
    name = gfw_edgar_marine_emissions,
    command = gfw_edgar_marine_co2()
  ),
  # IMO and MariTEAM have no machine-readable source, so their values are
  # transcribed in r/functions.R rather than downloaded. IMO covers 2016-2018;
  # MariTEAM reports a single year (2017, 943 Mt). IMO enters twice: the full
  # total, and the Type 1/2+3 subset, which is the tracked fleet and so the
  # closer comparison to our AIS series - see imo_ghg_study_type123_co2() for the
  # approximations behind that second series.
  tar_target(
    name = all_inventory_data,
    command = combine_inventory_series(
      inventory_files = c(
        steam_ship_annual_emissions_file,
        seim_ship_annual_emissions_file,
        icct_ship_annual_emissions_file,
        oecd_ship_annual_emissions_file
      ),
      gfw_edgar_series = gfw_edgar_marine_emissions,
      hardcoded_series = list(
        imo_ghg_study_co2(),
        imo_ghg_study_type123_co2(),
        mariteam_ship_co2()
      )
    )
  ),
  tar_target(
    name = all_inventory_data_file,
    command = write_inventory_csv(
      all_inventory_data,
      file.path("data", "inventories", "all_inventory_data.csv")
    ),
    format = "file"
  ),
  tar_target(
    name = inventory_comparison_figure,
    command = plot_inventory_comparison(
      all_inventory_data,
      file_path = file.path("figures", "inventory_comparison_all_sources.png")
    ),
    format = "file"
  ),

  # ICCT vs our AIS estimate ----
  # ICCT is the only published inventory here that reports activity as well as
  # emissions, so it is the only one we can compare on more than one number. This
  # table pairs intensity, absolute emissions, distance and vessel count with a
  # percent difference for each, year by year.
  #
  # Compared against GFW (AIS) rather than the fused AIS + S1 estimate, because
  # ICCT is also AIS-derived and makes no attempt to include non-broadcasting
  # vessels - so the AIS series is the like-for-like comparison.
  #
  # Needs data/gfw/annual_ais_activity_summary.csv from 01_gfw_data_pull, which
  # carries the distance and vessel counts this comparison depends on.
  tar_target(
    name = icct_gfw_ais_comparison,
    command = compare_icct_to_gfw_ais()
  ),
  tar_target(
    name = icct_gfw_ais_comparison_file,
    command = write_inventory_csv(
      icct_gfw_ais_comparison,
      file.path("data", "inventories", "icct_gfw_ais_comparison.csv")
    ),
    format = "file"
  )

  # Additional inventories ----
  # TODO: one download / process / write group per additional inventory
)
