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
  ),

  # Fleet coverage ----
  # How many vessels each inventory covers, where the inventory publishes it.
  # IMO is transcribed from the Fourth IMO GHG Study's "Total included" column
  # (2012-2018); ICCT is summed from the SAVE workbook (2016-2023). STEAM, SEIM
  # and OECD publish no vessel counts at all, so they do not appear here.
  #
  # No figure is drawn from this any more - it is kept as a table, and the CSV is
  # read back by the intensity figures, which divide each inventory's emissions by
  # the fleet it reports.
  tar_target(
    name = inventory_vessel_counts_by_year,
    command = inventory_vessel_counts(icct_years = as.integer(icct_ship_years))
  ),
  tar_target(
    name = inventory_vessel_counts_file,
    command = write_inventory_csv(
      inventory_vessel_counts_by_year,
      file.path("data", "inventories", "inventory_vessel_counts.csv")
    ),
    format = "file"
  ),

  # Fleet composition ----
  # Each vessel class's share of the AIS-broadcasting fleet beside its share of
  # that fleet's CO2 emissions. All fishing gear types are collapsed into one
  # class, matching how figure 3 splits fishing from non-fishing.
  #
  # The stacked-column figures that drew this directly are gone; the composition
  # is now drawn only by the Sankey figures below, which read this same target.
  #
  # It comes from annual_ais_activity_summary.csv, which carries the emissions
  # and the vessel count for the same class-year rows. That extract is grouped
  # straight off the ping table, so these figures total to the same annual
  # emissions the paper reports in figure 1A; the trip and port-visit extracts
  # they previously used only count activity resolvable to a completed voyage or
  # port visit, and run about 14% short.
  #
  # Read by path rather than as a target, the same way the ICCT comparison above
  # reads it: it is written by a different pipeline with its own store, so there
  # is no target to depend on from here.
  tar_target(
    name = fleet_shares_by_year,
    command = fleet_emissions_and_size_by_year()
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
      file_path = file.path("figures", "fleet_growth_by_year.png")
    ),
    format = "file"
  ),

  # Growth contribution ----
  # The growth figure above plots rates, which cannot say how much a class
  # mattered: a rate is blind to the base it grew from. Fishing grows 133 % and
  # passenger 108 %, so they read as the same story there, but fishing was 3.5 %
  # of 2017 emissions against passenger's 15.7 %, so passenger supplies about
  # 38 % of the fleet's CO2 growth and fishing about 10 %.
  #
  # These targets decompose the growth instead: each class's tonnes added since
  # the baseline, which sum to the fleet's net change and so can be stacked.
  tar_target(
    name = fleet_growth_contribution_data,
    command = fleet_growth_contribution_by_year(fleet_growth_by_year_data)
  ),
  tar_target(
    name = fleet_growth_contribution_file,
    command = write_inventory_csv(
      fleet_growth_contribution_data,
      file.path("data", "gfw", "fleet_growth_contribution_by_year.csv")
    ),
    format = "file"
  ),
  tar_target(
    name = fleet_growth_contribution_figure,
    command = plot_fleet_growth_contribution(
      fleet_growth_contribution_data,
      file_path = file.path("figures", "fleet_growth_contribution.png")
    ),
    format = "file"
  ),

  # The same growth question asked of a published inventory instead of our AIS
  # fleet: how far each ICCT ship class has moved from its first covered year,
  # per class per year, written out as a CSV.
  #
  # ICCT is the only inventory that can answer it. Its workbook reports a ship
  # count per class per year; the OECD dataflow breaks emissions down by vessel
  # type but publishes no counts, and the IMO study gives a fleet total only.
  #
  # No figure is drawn from this any more - the growth series is kept as a table
  # to quote from. The target is still needed regardless of the figure, since
  # icct_fleet_growth_by_year() is also the ICCT side of
  # compare_icct_gfw_vessel_classes(), which the class and dumbbell figures read.
  #
  # The baseline is the workbook's first year (2016) rather than the 2017 the GFW
  # growth figure uses, so the series starts where the data does. Deliberately not
  # driven by icct_ship_years, which starts at 2017 to line the emissions series
  # up with the other inventories - the workbook's ship counts go back to 2016 and
  # there is nothing to line up against here, so this takes the full span.
  #
  # The "Unknown" and "Miscellaneous-other" rows are dropped by the data function
  # as residuals rather than fleet segments - see icct_fleet_growth_by_year() for
  # why, and for the 2019-2020 coverage step in the underlying counts.
  tar_target(
    name = icct_fleet_growth_years,
    command = 2016:2023
  ),
  tar_target(
    name = icct_fleet_growth_by_year_data,
    command = icct_fleet_growth_by_year(icct_years = icct_fleet_growth_years)
  ),
  tar_target(
    name = icct_fleet_growth_by_year_file,
    command = write_inventory_csv(
      icct_fleet_growth_by_year_data,
      file.path("data", "inventories", "icct_fleet_growth_by_year.csv")
    ),
    format = "file"
  ),

  # The fleet composition for a single year, drawn as a plain Sankey: with no
  # series to carry, the two columns become the end nodes of the flows rather
  # than charts in their own right.
  tar_target(
    name = fleet_sankey_year,
    command = 2025L
  ),
  tar_target(
    name = fleet_sankey_figure,
    command = plot_fleet_sankey(
      fleet_shares_by_year,
      year = fleet_sankey_year,
      file_path = file.path(
        "figures",
        paste0("fleet_sankey_", fleet_sankey_year, ".png")
      )
    ),
    format = "file"
  ),
  # The Sankey and the two year-series columns as one figure: the single year
  # down the left as panel A, the series it belongs to stacked on the right as
  # B and C.
  tar_target(
    name = fleet_sankey_with_series_figure,
    command = plot_fleet_sankey_with_series(
      fleet_shares_by_year,
      year = fleet_sankey_year,
      file_path = file.path(
        "figures",
        paste0("fleet_sankey_with_series_", fleet_sankey_year, ".png")
      )
    ),
    format = "file"
  )

  ,

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
  # Shipping as a share of each inventory's own all-sector total. Computed
  # within an inventory rather than across them, since EDGAR and CEDS do not
  # cover an identical sector list - their totals are not directly comparable
  # but their internal shares are.
  tar_target(
    name = multisector_shipping_share_by_year,
    command = multisector_shipping_share(multisector_inventory_data)
  ),
  tar_target(
    name = multisector_shipping_share_file,
    command = write_inventory_csv(
      multisector_shipping_share_by_year,
      file.path("data", "inventories", "multisector_shipping_share.csv")
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
  # Our AIS series restricted to the maritime transport fleet - cargo, tanker
  # and passenger classes. This is the scope-matched comparison against the
  # inventories' water-borne navigation sectors: the full AIS series also counts
  # fishing fleets and service craft, which CEDS buries in
  # 1A4c_Agriculture-forestry-fishing and EDGAR does not label at all.
  #
  # Returned twice, with and without the passenger class: passenger is the
  # largest single class by emissions and is mostly ferry traffic, so whether it
  # belongs beside freight is a judgement the figure should not bury.
  #
  # Clipped to the same start year as the inventory series. The class extract
  # reaches back to 2015, but those extra years would draw a GFW line alone on
  # the left of the figure with no inventory to compare against.
  #
  # Reads data/gfw/annual_ais_activity_summary.csv by path, the same way the
  # ICCT comparison and fleet figures above do: it is written by 01_gfw_data_pull
  # with its own store, so there is no target to depend on from here.
  tar_target(
    name = gfw_maritime_transport_emissions,
    command = gfw_maritime_transport_co2(
      start_year = as.integer(edgar_multisector_years[1])
    )
  ),
  tar_target(
    name = gfw_maritime_transport_emissions_file,
    command = write_inventory_csv(
      gfw_maritime_transport_emissions,
      file.path("data", "gfw", "gfw_maritime_transport_emissions.csv")
    ),
    format = "file"
  ),
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
        "multisector_shipping_comparison.png"
      )
    ),
    format = "file"
  ),
  # Figure 2: the multi-sector view, the direct analogue of panel B of the
  # notebook's Figure 4 - marine against other transportation and the
  # all-sector total, as relative change from a common baseline, which is the
  # only way a ~39,000 Mt series and a ~800 Mt one share an axis. Drawn for both
  # inventories, so the comparison does not rest on EDGAR's sector allocation
  # alone.
  #
  # Shipping's share of each inventory's total is not drawn here - it is written
  # to multisector_shipping_share.csv above, where the numbers can be quoted
  # directly rather than read off an axis.
  tar_target(
    name = multisector_comparison_figure,
    command = plot_multisector_comparison(
      multisector_inventory_data,
      gfw_series = gfw_edgar_marine_emissions,
      # As on the shipping figure: the two whole-fleet GFW series, without the
      # maritime-transport subsets. On the relative-change view AIS and AIS + S1
      # do not coincide - the fused series grows faster, because the
      # non-broadcasting fleet it adds is the part that grows - so both are
      # worth drawing here even though the subsets are not.
      gfw_data_sources = c("GFW (AIS + S1)", "GFW (AIS)"),
      baseline_year = 2017L,
      file_path = file.path("figures", "multisector_comparison.png")
    ),
    format = "file"
  )
)
