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
  # v3.2 covers 2000-2021, so the series is drawn from 2015 - the earliest year
  # the inventory figure shows - rather than from 2017 with the GFW window.
  tar_target(
    name = steam_ship_years,
    command = as.character(2015:2021)
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
  # The published time series begins in 2016, so that is as far back as this
  # series can reach - one year short of the figure's 2015 start.
  tar_target(
    name = seim_ship_years,
    command = as.character(2016:2021)
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
  # The assessment covers 2016-2023, so like SEIM this reaches 2016 but not the
  # figure's 2015 start.
  tar_target(
    name = icct_ship_years,
    command = as.character(2016:2023)
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
  # transcribed in r/functions.R rather than downloaded. IMO covers 2015-2018;
  # MariTEAM reports a single year (2017, 943 Mt).
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
      # Panel A starts at 2017 rather than the function's 2015 default, so all
      # three panels open on the same year. The two years given up are sparse -
      # only the inventories that reach back that far draw them - and panels B
      # and C never showed them anyway, so the figure was asking the reader to
      # switch x ranges between panels for very little.
      start_year = 2017L,
      file_path = file.path(
        "figures",
        "figS-inventory-comparison-all-sources.png"
      )
    ),
    format = "file"
  ),
  # The same comparison asked of fleet size rather than emissions: how far each
  # inventory's vessel count has moved from its own first year, with ours split
  # by registry status.
  #
  # plot_vessel_counts_relative() was dropped in 03796c3 and this figure never
  # had a target at all - it had been drawn by hand - so the PNG the text cites
  # sat in figures/ with no code behind it. Both are restored here.
  #
  # The counts come from the committed CSV rather than being re-derived: building
  # it calls inventory_vessel_counts(), which downloads the ICCT workbook and
  # queries our own fleet, and the published counts it reads are settled. Tracked
  # as a tar_file() so an edited extract still triggers a redraw.
  tar_file(
    name = inventory_vessel_counts_by_registry_file,
    command = file.path(
      "data",
      "inventories",
      "si_inventory_comparison",
      "inventory_vessel_counts_by_registry.csv"
    )
  ),
  tar_target(
    name = vessel_counts_relative_figure,
    command = plot_vessel_counts_relative(
      vessel_counts_file = inventory_vessel_counts_by_registry_file,
      file_path = file.path(
        "figures",
        "figS-inventory-vessel-counts-by-registry.png"
      )
    ),
    format = "file"
  ),

  # Registry split of our AIS series ----
  # The same total the figure above compares against the published inventories,
  # cut by whether the vessel could be matched to a registry at all.
  #
  # This is what the comparison is for. Every inventory drawn beside us is built
  # from a registry, so the fleet each one can enumerate is bounded by
  # registration; ours is bounded by AIS instead. Splitting our own series on
  # that line shows which part of it the other models were ever in a position to
  # see, and the answer is that the growth sits almost entirely in the part they
  # were not.
  #
  # Reads annual_ais_activity_summary_cheap.csv by path, the same way the fleet
  # figures below do: registry_type only exists in that extract, and it is
  # written by 01_gfw_data_pull with its own store, so there is no target here to
  # depend on.
  tar_target(
    name = gfw_registry_emissions,
    command = gfw_registry_series()
  ),
  # The split on its own, in relative terms. This is the figure that lives at
  # figS-registry-split-comparison.png; it had been produced by hand and its function
  # was dropped in 03796c3, leaving the PNG with no code behind it. Restored as a
  # target so the file rebuilds with the rest.
  tar_target(
    name = registry_split_relative_figure,
    command = plot_registry_split_relative(
      gfw_registry_emissions,
      file_path = file.path(
        "figures",
        "figS-registry-split-comparison.png"
      )
    ),
    format = "file"
  ),
  # The same split as a composition rather than a trend: what share of the fleet
  # each registry status holds against what share of the CO2 it emits.
  #
  # Drawn for one year, because the point is the mismatch between the two shares
  # rather than its movement - the movement is what the comparison figure above
  # carries.
  tar_target(
    name = registry_shares_by_year,
    command = registry_emissions_and_size_by_year()
  ),
  tar_target(
    name = registry_sankey_year,
    command = 2025L
  ),
  tar_target(
    name = registry_sankey_with_series_figure,
    command = plot_registry_sankey_with_series(
      registry_shares_by_year,
      year = registry_sankey_year,
      file_path = file.path(
        "figures",
        paste0("figS-registry-sankey-with-series-", registry_sankey_year, ".png")
      )
    ),
    format = "file"
  ),
  # The same Sankey cut by vessel class rather than registry status. Restored
  # with its fleet-shares input from 03796c3^, which dropped both while the PNG
  # the text cites stayed in figures/.
  #
  # plot_registry_sankey_with_series() above is a thin wrapper on the same
  # plotting function, so the two figures are drawn by one implementation and
  # differ only in the composition handed to it.
  tar_target(
    name = fleet_shares_by_year,
    command = fleet_emissions_and_size_by_year()
  ),
  tar_target(
    name = fleet_sankey_year,
    command = 2025L
  ),
  tar_target(
    name = fleet_sankey_with_series_figure,
    command = plot_fleet_sankey_with_series(
      fleet_shares_by_year,
      year = fleet_sankey_year,
      file_path = file.path(
        "figures",
        paste0("figS-fleet-sankey-with-series-", fleet_sankey_year, ".png")
      )
    ),
    format = "file"
  ),

  # Fleet growth ----
  # The composition figures above show each class's share of the fleet in a
  # given year. These show growth instead: how far each class has moved from its
  # 2017 level, in vessel count, in AIS position messages and in CO2.
  #
  # The two questions can answer differently - a class can grow every year while
  # its share falls, if the rest of the fleet grows faster - so this is not a
  # restatement of the stacked columns.
  #
  # Pings are carried beside the vessel count because the two separate real
  # fleet growth from improving AIS coverage: a class whose messages rise faster
  # than its hull count is being tracked more densely, not necessarily sailing
  # more. The CO2 panel is what that distinction matters for: emissions should
  # track real activity, so a class whose CO2 stays flat while its pings
  # multiply is one whose apparent growth is mostly coverage.
  #
  # All three measures come from the same class-year rows of one activity
  # extract, so no join makes them agree.
  tar_target(
    name = fleet_growth_baseline_year,
    command = 2017L
  ),
  tar_target(
    name = fleet_growth_by_year_data,
    command = fleet_growth_by_year(baseline_year = fleet_growth_baseline_year)
  ),
  tar_target(
    name = fleet_growth_by_year_file,
    command = write_inventory_csv(
      fleet_growth_by_year_data,
      file.path("data", "gfw", "fleet_growth_by_year.csv")
    ),
    format = "file"
  ),
  tar_target(
    name = fleet_growth_by_year_figure,
    command = plot_fleet_growth_by_year(
      fleet_growth_by_year_data,
      file_path = file.path("figures", "figS-fleet-growth-by-year.png")
    ),
    format = "file"
  ),

  # Multi-sector inventories ----
  # Everything above compares shipping-specific inventories: models built to
  # estimate marine vessel emissions and nothing else. The targets below are a
  # separate comparison against multi-sector inventories - global databases that
  # estimate every emitting sector, of which shipping is one line among dozens.
  #
  # Kept apart from the targets above on purpose. A shipping model and a global
  # inventory disagree for different reasons, and only the multi-sector sources
  # carry an all-sector total, which is ~48x the shipping one and cannot share
  # an axis with it. The two figures below therefore split the question: one
  # shows only the shipping lines (comparable to fig-inventory-comparison), the
  # other shows shipping against the all-sector totals.
  #
  # Both inventories are downloaded from their published source, as the shipping
  # inventories above are. Note that the EDGAR download reproduces the workbook
  # already sitting in data/IEA_EDGAR_CO2_1970_2024/ that 02_quarto_notebook
  # reads - the release zip holds a byte-identical xlsx - so this target does
  # not replace that file, it makes the series reproducible from source and adds
  # the all-sector total the notebook never stores.
  #
  # Both windows start at 2017, to match the shipping comparison's baseline, but
  # each inventory runs to its own last published year rather than being cut
  # back to the shorter of the two: EDGAR 2025 reports through 2024, while CEDS
  # v_2025_03_18 stops at 2023. Truncating EDGAR would discard a year it
  # actually publishes, so the series simply end where their sources do and the
  # figures show one year with EDGAR alone.
  tar_target(
    name = edgar_multisector_years,
    command = as.character(2017:2024)
  ),
  tar_target(
    name = ceds_multisector_years,
    command = as.character(2017:2023)
  ),
  tar_target(
    name = edgar_multisector_emissions,
    command = summarize_edgar_multisector_co2(years = edgar_multisector_years)
  ),
  tar_target(
    name = edgar_multisector_emissions_file,
    command = write_inventory_csv(
      edgar_multisector_emissions,
      file.path("data", "edgar", "edgar_multisector_emissions.csv")
    ),
    format = "file"
  ),
  tar_target(
    name = ceds_multisector_emissions,
    command = summarize_ceds_multisector_co2(years = ceds_multisector_years)
  ),
  tar_target(
    name = ceds_multisector_emissions_file,
    command = write_inventory_csv(
      ceds_multisector_emissions,
      file.path("data", "ceds", "ceds_multisector_emissions.csv")
    ),
    format = "file"
  ),
  # One table on the data_source / inventory_version / scope / year schema.
  # Deliberately not folded into all_inventory_data: that table is keyed on
  # data_source alone because every series in it is shipping, while each source
  # here contributes both a shipping and an all-sector series.
  tar_target(
    name = multisector_inventory_data,
    command = combine_multisector_series(
      inventory_files = c(
        edgar_multisector_emissions_file,
        ceds_multisector_emissions_file
      )
    )
  ),
  tar_target(
    name = multisector_inventory_data_file,
    command = write_inventory_csv(
      multisector_inventory_data,
      file.path("data", "inventories", "multisector_inventory_data.csv")
    ),
    format = "file"
  ),
  # Figure 1: the shipping-only view. What each global inventory allocates to
  # marine, beside both our GFW estimates - AIS alone, which is the like-for-
  # like against inventories built from broadcasting vessels, and AIS + S1,
  # which adds the non-broadcasting fleet none of them attempt to cover. CEDS
  # appears at both scopes, so the gap between its two lines is the domestic
  # navigation that EDGAR folds into its single Water-borne Navigation sector.
  #
  # Reuses gfw_edgar_marine_emissions from the shipping comparison above for the
  # GFW series, so both figures draw the same GFW numbers.
  tar_target(
    name = multisector_shipping_comparison_figure,
    command = plot_multisector_shipping_comparison(
      multisector_inventory_data,
      gfw_series = gfw_edgar_marine_emissions,
      # GFW is carried by the two whole-fleet series: AIS alone is the
      # like-for-like against inventories built from broadcasting vessels, and
      # AIS + S1 adds the non-broadcasting fleet none of them attempt to cover,
      # so the gap between the two is what this comparison cannot otherwise see.
      # The maritime-transport subsets are dropped: four GFW lines on one ramp
      # crowded the comparison, and those scopes are the subject of the
      # inventory-comparison figures, where they can be read properly.
      gfw_data_sources = c("GFW (AIS + S1)", "GFW (AIS)"),
      file_path = file.path(
        "figures",
        "figS-multisector-shipping-comparison.png"
      )
    ),
    format = "file"
  ),
  # Figure 2: the same series indexed to a common baseline, which is the only
  # way a ~39,000 Mt series and a ~800 Mt one share an axis. Restored from
  # 03796c3^ along with plot_multisector_comparison(), which that commit dropped
  # while leaving the PNG the text cites in figures/.
  #
  # Both GFW whole-fleet series are drawn here even though the shipping figure
  # keeps only one pair: on the relative-change view AIS and AIS + S1 do not
  # coincide, because the non-broadcasting fleet the fused series adds is the
  # part that grows.
  tar_target(
    name = multisector_comparison_figure,
    command = plot_multisector_comparison(
      multisector_inventory_data,
      gfw_series = gfw_edgar_marine_emissions,
      gfw_data_sources = c("GFW (AIS + S1)", "GFW (AIS)"),
      baseline_year = 2017L,
      file_path = file.path("figures", "figS-multisector-comparison.png")
    ),
    format = "file"
  ),

  # Sentinel-1 detection diagnostics ----
  # The comparison above says our series grows faster than the registry-built
  # inventories. These figures answer the obvious objection to that: whether the
  # growth is activity or just more of the ocean coming into view.
  #
  # They read committed CSVs rather than pulling from BigQuery. Each underlying
  # query scans 2.5-4.6 GB and the results are settled, so the extracts are kept
  # in the repo as data/gfw/s1_*.csv with their queries beside them as
  # sql/s1_*.sql. Tracking the CSVs as tar_file() inputs means a redraw follows
  # an edited extract without a pull ever being wired in.
  # Reads the fixed-metre-bin extract, shared with the carriage-saturation and
  # density-by-match-status figures, so a length bin means the same thing
  # wherever it appears.
  tar_target(
    name = unmatched_fraction_fullperiod_figure,
    command = plot_unmatched_fraction_fullperiod(
      fixed_bin_file = s1_detections_by_fixed_length_bin_file,
      file_path = file.path("figures", "figS-unmatched-fraction-fullperiod.png")
    ),
    format = "file"
  ),
  tar_file(
    name = s1_detections_by_fixed_length_bin_file,
    command = file.path(
      "data",
      "gfw",
      "s1_detections_by_fixed_length_bin.csv"
    )
  ),
  tar_target(
    name = ais_carriage_saturation_figure,
    command = plot_ais_carriage_saturation_by_size(
      fixed_bin_file = s1_detections_by_fixed_length_bin_file,
      file_path = file.path(
        "figures",
        "figS-ais-carriage-saturation-by-size.png"
      )
    ),
    format = "file"
  ),

  # Emissions reconciliation ----
  # Two figures that close the same argument from the AIS side: whether the
  # passenger tail's growth is more vessels or more activity credited to the same
  # ones, and whether the post-2021 explosion in AIS message volume inflated the
  # inventory.
  #
  # These read 01_gfw_data_pull's extracts by path, the same way the fleet and
  # registry targets above do - that pipeline has its own store, so there is no
  # target here to depend on.

  # Passenger headcount beside passenger emissions, in levels (A, B) and in
  # 2017-2025 change (C, D), all on the same length bins and no registry split -
  # is the tail's growth more vessels, or more activity credited to the same ones?
  # The panel-by-panel reading is documented on the function.
  tar_target(
    name = passenger_size_panels_figure,
    command = plot_passenger_size_panels(
      file_path = file.path(
        "figures",
        "figS-passenger-size-panels.png"
      )
    ),
    format = "file"
  ),
  tar_target(
    name = messages_hours_emissions_figure,
    command = plot_messages_hours_emissions(
      file_path = file.path(
        "figures",
        "figS-messages-vs-hours-vs-emissions.png"
      )
    ),
    format = "file"
  )
)
