# Function to download GFW data and save it in repo
# Returns file path, for keeping track with targets
download_gfw_data <- function(sql, bq_billing_project, file_path, ...) {
  bigrquery::bq_project_query(
    bq_billing_project,
    query = sql
  ) |>
    bigrquery::bq_table_download(n_max = Inf, bigint = "integer64") |>
    readr::write_csv(file_path)
  return(file_path)
}

# Function to access and combine CO2 emissions data from EU maritime transport
# Downloaded from https://mrv.emsa.europa.eu/# on July 10, 2025
# Each year is download separately for 2018-2024; we then combine them
combine_EU_data <- function(mrv_raw_files) {
  combined <- purrr::map_df(mrv_raw_files, function(year_tmp_file) {
    data <- readxl::read_excel(year_tmp_file, skip = 2, col_names = TRUE) |>
      janitor::clean_names()

    # Need to process 2024 somewhat differently - column formatting changed
    if (stringr::str_detect(basename(year_tmp_file), "\\b2024\\b")) {
      data <- data |>
        dplyr::select(-imo_number_9, -name_10) |>
        dplyr::rename(
          imo_number = imo_number_1,
          annual_average_co2_emissions_per_distance_kg_co2_n_mile = co2_emissions_per_distance_kg_co2_n_mile
        )
    }

    # The total hours variable has different names across years
    time_spent_at_sea_column <- if (
      "total_time_spent_at_sea_hours" %in% colnames(data)
    ) {
      "total_time_spent_at_sea_hours"
    } else {
      "time_spent_at_sea_hours"
    }
    data <- data |>
      dplyr::select(
        imo_number,
        ship_type,
        reporting_period,
        total_fuel_consumption_m_tonnes,
        total_co2_emissions_m_tonnes,
        co2_emissions_from_all_voyages_between_ports_under_a_ms_jurisdiction_m_tonnes,
        co2_emissions_from_all_voyages_which_departed_from_ports_under_a_ms_jurisdiction_m_tonnes,
        co2_emissions_from_all_voyages_to_ports_under_a_ms_jurisdiction_m_tonnes,
        co2_emissions_which_occurred_within_ports_under_a_ms_jurisdiction_at_berth_m_tonnes,
        annual_average_co2_emissions_per_distance_kg_co2_n_mile,
        paste(time_spent_at_sea_column)
      ) |>
      dplyr::mutate(
        annual_average_co2_emissions_per_distance_kg_co2_n_mile = as.numeric(replace(
          annual_average_co2_emissions_per_distance_kg_co2_n_mile,
          annual_average_co2_emissions_per_distance_kg_co2_n_mile ==
            "Division by zero!",
          NA
        ))
      ) |>
      dplyr::rename(
        total_time_spent_at_sea_hours = paste(time_spent_at_sea_column)
      )
  })

  combined
}

# Vessel class families --------------------------------------------------------
# GFW vessel classes are rolled up into four families for Figure 3. These
# definitions are the single source of truth for that roll-up: the notebook uses
# them to group and label the bar chart, and _targets_01_gfw_data_pull.R glues
# vessel_class_family_sql() into the spatial pull, so the maps and the bars are
# always grouped the same way. All of them take raw GFW class names
# ("cargo.container", "trawlers"), not the prettified labels.

# The fishing gears, which the notebook also uses for its fishing / non-fishing
# split
fishing_vessel_classes <- function() {
  c(
    "trawlers",
    "squid_jigger",
    "tuna_purse_seines",
    "set_longlines",
    "pole_and_line",
    "set_gillnets",
    "pots_and_traps",
    "dredge_fishing",
    "other_seines",
    "other_purse_seines",
    "trollers",
    "drifting_longlines",
    "driftnets",
    "fish_factory",
    "other_fishing"
  )
}

# Refrigerated cargo arrives under several class names, not all of which carry
# the "cargo" prefix. This is what puts them in the cargo family; Figure 3A
# gives each of them its own bar rather than collapsing them into one row.
reefer_vessel_classes <- function() {
  c("specialized_reefer", "container_reefer", "cargo.refrigerated")
}

# Assign raw GFW vessel classes to families
vessel_class_family <- function(vessel_class) {
  dplyr::case_when(
    vessel_class %in% fishing_vessel_classes() ~ "Fishing",
    vessel_class %in% reefer_vessel_classes() ~ "Cargo",
    stringr::str_starts(vessel_class, "cargo") ~ "Cargo",
    stringr::str_starts(vessel_class, "tanker") ~ "Tanker",
    .default = "Service and passenger"
  )
}

# The same assignment as a BigQuery CASE expression, so the spatial pull groups
# classes exactly the way vessel_class_family() does
vessel_class_family_sql <- function() {
  sql_list <- function(classes) {
    paste0("'", classes, "'", collapse = ", ")
  }
  paste(
    "CASE",
    paste0(
      "    WHEN vessel_class IN (",
      sql_list(fishing_vessel_classes()),
      ") THEN 'Fishing'"
    ),
    paste0(
      "    WHEN vessel_class IN (",
      sql_list(reefer_vessel_classes()),
      ") THEN 'Cargo'"
    ),
    "    WHEN STARTS_WITH(vessel_class, 'cargo') THEN 'Cargo'",
    "    WHEN STARTS_WITH(vessel_class, 'tanker') THEN 'Tanker'",
    "    ELSE 'Service and passenger'",
    "  END",
    sep = "\n"
  )
}

# Functions for the 03_inventories_comparison pipeline ----

# Download one year of CAMS-GLOB-SHIP CO2 from the Copernicus Atmosphere Data
# Store, sum it to a global annual total, and delete the download.
#
# One year is an ~885 MB zip holding a single NetCDF, and we only need one
# number out of it, so the download goes to a temporary directory and is removed
# on exit rather than being kept in the repo.
#
# CAMS-GLOB-SHIP is produced with the STEAM model (v3.2 records STEAM 4.2.5) and
# served as daily grids of flux in kg m-2 s-1 at 0.1 degrees.
#
# What we extract: the single emissions variable in the file - named "shipping",
# so the grid is already all-shipping with no sector selection to make - summed
# over every cell and every daily slice. Converting a flux to a mass requires
# weighting each cell by its own area (cells shrink toward the poles) and each
# slice by its own duration, which is why this cannot be a plain sum the way the
# tabular inventories can.
#
# The area weighting was checked against the closed-form spherical zone area and
# by confirming the cell areas sum to the surface area of the Earth; the result
# was then reproduced by an independent daily reconstruction (904.21 Mt for 2019
# both ways). Returns a one-row tibble with emissions in metric tonnes.
summarize_cams_ship_co2 <- function(
  year,
  version,
  dataset_short_name = "cams-global-emission-inventories"
) {
  year <- as.character(year)

  download_dir <- file.path(tempdir(), paste0("cams_ship_", version, "_", year))
  dir.create(download_dir, showWarnings = FALSE, recursive = TRUE)
  # Drop the grid as soon as we have the annual number, however this function exits
  on.exit(unlink(download_dir, recursive = TRUE), add = TRUE)

  request <- list(
    dataset_short_name = dataset_short_name,
    variable = "carbon_dioxide",
    source = "shipping",
    version = version,
    year = year,
    target = paste0("cams_ship_co2_", version, "_", year, ".zip")
  )

  downloaded <- ecmwfr::wf_request(
    request = request,
    transfer = TRUE,
    path = download_dir,
    verbose = TRUE
  )

  # ADS may return the NetCDF directly or wrapped in an archive depending on the
  # request; handle both so the pipeline does not depend on which one we get.
  if (
    any(grepl("\\.(zip|tar|tar\\.gz|tgz)$", downloaded, ignore.case = TRUE))
  ) {
    archive <- downloaded[grepl(
      "\\.(zip|tar|tar\\.gz|tgz)$",
      downloaded,
      ignore.case = TRUE
    )][1]
    if (grepl("\\.zip$", archive, ignore.case = TRUE)) {
      utils::unzip(archive, exdir = download_dir)
    } else {
      utils::untar(archive, exdir = download_dir)
    }
  }

  nc_files <- list.files(
    download_dir,
    pattern = "\\.nc$",
    full.names = TRUE,
    recursive = TRUE
  )
  if (length(nc_files) == 0) {
    stop(
      "No NetCDF found for CAMS-GLOB-SHIP ",
      version,
      " ",
      year,
      ". Files returned: ",
      paste(basename(downloaded), collapse = ", ")
    )
  }

  purrr::map_dfr(nc_files, function(nc_file) {
    annual <- sum_cams_nc_to_tonnes(nc_file, year)

    tibble::tibble(
      data_source = "CAMS-GLOB-SHIP (STEAM)",
      version = version,
      year = as.integer(year),
      n_time_slices = annual$n_time_slices,
      emissions_co2_mt = annual$emissions_co2_mt
    )
  })
}

# Sum a CAMS flux grid to a global annual total in metric tonnes.
#
# CAMS grids store flux in kg m-2 s-1 on a regular lat-lon grid, so a mass total
# needs each cell weighted by its own area and each time slice weighted by its
# own duration. On a regular lat-lon grid the cell area has a closed form - the
# spherical zone between two latitudes, split by longitude - which is why this
# needs only ncdf4 and no GIS dependency.
#
# CAMS-GLOB-SHIP v3.2 is daily at 0.1 degrees (365 x 1800 x 3600), which is far
# too large to hold in memory at once, so slices are read and reduced one at a
# time and only the running totals are kept.
sum_cams_nc_to_tonnes <- function(nc_file, year) {
  nc <- ncdf4::nc_open(nc_file)
  on.exit(ncdf4::nc_close(nc), add = TRUE)

  emissions_variable <- cams_emissions_variable(nc)
  lat_name <- cams_axis_name(nc, c("lat", "latitude"))
  lon_name <- cams_axis_name(nc, c("lon", "longitude"))
  lat <- as.numeric(ncdf4::ncvar_get(nc, lat_name))
  lon <- as.numeric(ncdf4::ncvar_get(nc, lon_name))

  # Dimension order varies between CAMS products, so locate each axis by name
  # rather than assuming a layout
  dim_names <- vapply(
    nc$var[[emissions_variable]]$dim,
    function(d) d$name,
    character(1)
  )
  time_axis <- which(dim_names == "time")
  lat_axis <- which(dim_names == lat_name)
  lon_axis <- which(dim_names == lon_name)

  if (length(lat_axis) != 1 || length(lon_axis) != 1) {
    stop(
      "Could not locate lat/lon axes of ",
      emissions_variable,
      " in ",
      basename(nc_file)
    )
  }

  n_slices <- if (length(time_axis) == 1) {
    nc$var[[emissions_variable]]$dim[[time_axis]]$len
  } else {
    1L
  }
  seconds_per_slice <- cams_seconds_per_slice(nc, year, n_slices)

  # Area is a lat x lon matrix here, matching the orientation of a single slice
  # once the time dimension is dropped
  cell_area_m2 <- cams_cell_area_m2(lat, lon, lat_first = lat_axis < lon_axis)

  # kg m-2 s-1 * m2 * s = kg, accumulated one slice at a time
  slice_kg <- vapply(
    seq_len(n_slices),
    function(slice_index) {
      start <- rep(1L, length(dim_names))
      count <- rep(-1L, length(dim_names))
      if (length(time_axis) == 1) {
        start[time_axis] <- slice_index
        count[time_axis] <- 1L
      }
      slice <- ncdf4::ncvar_get(
        nc,
        emissions_variable,
        start = start,
        count = count,
        collapse_degen = TRUE
      )
      sum(slice * cell_area_m2, na.rm = TRUE) * seconds_per_slice[slice_index]
    },
    numeric(1)
  )

  list(
    n_time_slices = n_slices,
    emissions_co2_mt = sum(slice_kg) / 1e3
  )
}

# Identify the emissions variable in a CAMS file, ignoring the coordinate and
# bounds variables that sit alongside it.
cams_emissions_variable <- function(nc) {
  candidates <- setdiff(
    names(nc$var),
    c(
      "lat",
      "latitude",
      "lon",
      "longitude",
      "time",
      "lat_bnds",
      "lon_bnds",
      "time_bnds",
      "crs"
    )
  )
  if (length(candidates) == 0) {
    stop("No emissions variable found in ", basename(nc$filename))
  }
  # CAMS ships one emissions variable per file; if that ever changes, the first
  # non-coordinate variable is still the flux field
  candidates[1]
}

# Find a coordinate axis by any of its plausible names
cams_axis_name <- function(nc, options) {
  available <- c(names(nc$dim), names(nc$var))
  found <- intersect(options, available)
  if (length(found) == 0) {
    stop(
      "None of the expected axis names (",
      paste(options, collapse = ", "),
      ") found in ",
      basename(nc$filename)
    )
  }
  found[1]
}

# Area of each grid cell on a regular lat-lon grid, in m2. Cells are spherical
# zones, so area depends on latitude but not longitude. `lat_first` orients the
# result to match the slice being multiplied: lat x lon when TRUE, lon x lat
# otherwise.
cams_cell_area_m2 <- function(
  lat,
  lon,
  lat_first = FALSE,
  earth_radius_m = 6371007.181
) {
  lat_step <- abs(stats::median(diff(lat)))
  lon_step <- abs(stats::median(diff(lon)))

  # Clamp to the poles so the outermost half-cells do not run past +/-90 degrees
  lat_upper <- pmin(lat + lat_step / 2, 90)
  lat_lower <- pmax(lat - lat_step / 2, -90)

  # Area of a spherical zone slice: R^2 * dlon * (sin(lat_upper) - sin(lat_lower))
  band_area_m2 <- earth_radius_m^2 *
    (lon_step * pi / 180) *
    (sin(lat_upper * pi / 180) - sin(lat_lower * pi / 180))

  if (lat_first) {
    matrix(
      rep(band_area_m2, times = length(lon)),
      nrow = length(lat),
      ncol = length(lon)
    )
  } else {
    matrix(
      rep(band_area_m2, each = length(lon)),
      nrow = length(lon),
      ncol = length(lat)
    )
  }
}

# Seconds covered by each time slice, so a flux can be converted to a mass.
#
# Derived from the gaps between the file's own timestamps, which handles the
# daily slices in CAMS-GLOB-SHIP v3.2 as well as the monthly layout of other
# CAMS products without assuming either. The final slice has no following
# timestamp, so it runs to the start of the next year. Falls back to spreading
# the year evenly across slices when the time axis is unusable.
cams_seconds_per_slice <- function(nc, year, n_slices) {
  seconds_in_year <- as.numeric(difftime(
    as.Date(sprintf("%d-01-01", as.integer(year) + 1)),
    as.Date(sprintf("%s-01-01", year)),
    units = "secs"
  ))

  slice_times <- cams_slice_times(nc)

  if (is.null(slice_times) || length(slice_times) != n_slices) {
    # No usable time axis: assume the slices evenly partition the year
    return(rep(seconds_in_year / n_slices, n_slices))
  }

  if (n_slices == 1) {
    return(seconds_in_year)
  }

  # Each slice runs until the next one starts. The last slice has no successor,
  # so it runs to the end of the year, but capped at one more step of its own
  # cadence. Without the cap a partial year would stretch its final slice across
  # every missing day and still report a full-year total; without the year-end
  # bound an irregular cadence (monthly) would give December the length of
  # November.
  gaps <- as.numeric(diff(slice_times), units = "secs")
  year_end <- as.POSIXct(
    sprintf("%d-01-01 00:00:00", as.integer(year) + 1),
    tz = "UTC"
  )
  last_to_year_end <- as.numeric(
    difftime(year_end, slice_times[n_slices], units = "secs")
  )
  durations <- c(gaps, min(last_to_year_end, gaps[length(gaps)] * 2))

  if (any(is.na(durations)) || any(durations <= 0)) {
    return(rep(seconds_in_year / n_slices, n_slices))
  }

  durations
}

# Decode a CF-style time axis ("<units> since <origin>") into timestamps,
# returning NULL when the axis is missing or not decodable.
cams_slice_times <- function(nc) {
  if (!("time" %in% c(names(nc$dim), names(nc$var)))) {
    return(NULL)
  }

  time_units <- try(ncdf4::ncatt_get(nc, "time", "units")$value, silent = TRUE)
  time_values <- try(as.numeric(ncdf4::ncvar_get(nc, "time")), silent = TRUE)

  if (
    inherits(time_units, "try-error") ||
      inherits(time_values, "try-error") ||
      !is.character(time_units) ||
      !grepl("since", time_units)
  ) {
    return(NULL)
  }

  seconds_per_step <- switch(
    tolower(trimws(sub("since.*", "", time_units))),
    "days" = 86400,
    "hours" = 3600,
    "minutes" = 60,
    "seconds" = 1,
    NA_real_
  )

  # The origin may or may not carry a clock time, e.g. "days since 2019-01-01 00:00"
  origin_text <- trimws(sub(".*since", "", time_units))
  origin <- suppressWarnings(as.POSIXct(
    origin_text,
    tz = "UTC",
    tryFormats = c(
      "%Y-%m-%d %H:%M:%S",
      "%Y-%m-%d %H:%M",
      "%Y-%m-%d"
    )
  ))

  if (is.na(seconds_per_step) || is.na(origin)) {
    return(NULL)
  }

  origin + time_values * seconds_per_step
}

# Download and summarize the SEIM global shipping emissions time series.
#
# SEIM (Shipping Emission Inventory Model, Tsinghua University) publishes global
# shipping emissions for 2013 and 2016-2021 on Zenodo:
# https://zenodo.org/records/11069531
#
# The record holds four files. Three are 0.1 degree daily grids (380 MB - 2.6 GB
# each); the fourth, timeSeries_16_21_global.csv, is a 25 MB tidy table of daily
# totals broken out by vessel type and build period, which is all we need for an
# annual comparison. Note that only the grids cover 2013, so the time series
# starts in 2016.
#
# What we extract: the CO2 column summed over every row of the requested year.
# Each row is one day x one of 15 vessel types x one of 4 build periods, and
# these are disaggregations rather than subtotals - the file carries no total row
# - so summing them all is the global annual figure. Emissions are already
# absolute masses in metric tonnes per day, not fluxes, so unlike the CAMS grids
# no area or duration weighting is needed.
#
# The record documents no units, so they were confirmed by cross-checking the
# published values: reading them as tonnes puts 2019 at 884 Mt CO2 against 904 Mt
# from CAMS-GLOB-SHIP for the same year, and gives a global CO2:NOx ratio of 52,
# both consistent with marine fuel combustion. The vessel-type split is also
# ordered as expected (container 276 Mt, bulk carrier 161 Mt, oil tanker 124 Mt).
#
# The download is deleted once summarized, matching how the CAMS years are
# handled, so no bulk data is stored in the repo. Returns one row per year, with
# n_days reporting how many distinct days each annual total was summed from.
summarize_seim_ship_co2 <- function(
  years,
  record_id = "11069531",
  file_name = "timeSeries_16_21_global.csv"
) {
  years <- as.integer(years)

  download_dir <- file.path(tempdir(), paste0("seim_", record_id))
  dir.create(download_dir, showWarnings = FALSE, recursive = TRUE)
  # Drop the download as soon as we have the annual numbers, however we exit
  on.exit(unlink(download_dir, recursive = TRUE), add = TRUE)

  destination <- file.path(download_dir, file_name)
  utils::download.file(
    sprintf(
      "https://zenodo.org/api/records/%s/files/%s/content",
      record_id,
      file_name
    ),
    destfile = destination,
    mode = "wb",
    quiet = TRUE
  )

  daily <- readr::read_csv(
    destination,
    col_types = readr::cols_only(
      Date = readr::col_date(),
      CO2 = readr::col_double()
    )
  )

  summarized <- daily |>
    dplyr::mutate(year = as.integer(format(.data$Date, "%Y"))) |>
    dplyr::group_by(year = .data$year) |>
    dplyr::summarize(
      # Days present in the file, as a check that a year is complete before its
      # total is compared against anything
      n_days = dplyr::n_distinct(.data$Date),
      emissions_co2_mt = sum(.data$CO2),
      .groups = "drop"
    ) |>
    dplyr::filter(.data$year %in% years) |>
    dplyr::transmute(
      data_source = "SEIM",
      # The Zenodo record names no model version: its metadata version field is
      # empty and the description only cites the SEIM methodology papers. Rather
      # than assert a version the source does not state, this is left missing -
      # set it here if the authors publish one.
      seim_model_version = NA_character_,
      year = .data$year,
      n_days = .data$n_days,
      emissions_co2_mt = .data$emissions_co2_mt
    ) |>
    dplyr::arrange(.data$year)

  missing_years <- setdiff(years, summarized$year)
  if (length(missing_years) > 0) {
    stop(
      "SEIM record ",
      record_id,
      " has no data for: ",
      paste(sort(missing_years), collapse = ", "),
      ". The published time series covers 2016-2021."
    )
  }

  summarized
}

# Download and summarize the ICCT global shipping emissions inventory.
#
# The International Council on Clean Transportation publishes its systematic
# assessment of shipping emissions as a supplemental workbook alongside
# "Greenhouse gas emissions and air pollution from global shipping, 2016-2023":
# https://theicct.org/publication/greenhouse-gas-emissions-and-air-pollution-from-global-shipping-2016-2023-apr25/
#
# The workbook holds one sheet per year, named for the year, each a small table
# of 20 ship classes by roughly 36 activity and emissions columns.
#
# What we extract: the "CO2 emissions (tonne)" column, summed over all 20 ship
# class rows. The column is already absolute tonnes, so there is no unit
# conversion, and the sheets carry no total row to accidentally double count -
# verified by listing the row labels, where the only non-class rows are a blank
# line and a trailing footnote about column H.
#
# The 20 rows include an "Unknown" class for vessels the ICCT could not identify,
# and it is included in the total. It is a genuine class rather than a subtotal:
# in 2019 it carries 61.1 Mt, so dropping it would report 805.6 Mt instead of
# 866.7 Mt and understate the global figure by 7%.
#
# This inventory runs through 2023, two years further than STEAM and SEIM.
# Returns one row per year, with n_ship_classes recording how many classes each
# annual total was summed from.
summarize_icct_ship_co2 <- function(
  years,
  url = "https://theicct.org/wp-content/uploads/2025/04/supplemental_vf.xlsx"
) {
  years <- as.integer(years)

  download_dir <- file.path(tempdir(), "icct_shipping")
  dir.create(download_dir, showWarnings = FALSE, recursive = TRUE)
  # Drop the workbook once summarized, however we exit
  on.exit(unlink(download_dir, recursive = TRUE), add = TRUE)

  destination <- file.path(download_dir, basename(url))
  utils::download.file(url, destfile = destination, mode = "wb", quiet = TRUE)

  available_sheets <- readxl::excel_sheets(destination)
  # Sheets are named for the year they cover
  wanted_sheets <- intersect(as.character(years), available_sheets)

  missing_years <- setdiff(as.character(years), available_sheets)
  if (length(missing_years) > 0) {
    stop(
      "The ICCT workbook has no sheet for: ",
      paste(sort(missing_years), collapse = ", "),
      ". It covers ",
      paste(
        range(suppressWarnings(as.integer(available_sheets)), na.rm = TRUE),
        collapse = "-"
      ),
      "."
    )
  }

  purrr::map_dfr(wanted_sheets, function(sheet) {
    sheet_data <- readxl::read_excel(destination, sheet = sheet)

    class_column <- names(sheet_data)[1]
    co2_column <- grep(
      "^CO2 emissions",
      names(sheet_data),
      value = TRUE
    )[1]

    if (is.na(co2_column)) {
      stop("No 'CO2 emissions' column found in ICCT sheet ", sheet)
    }

    # Each sheet ends with a blank row and a footnote about column H, so keep
    # only the labelled class rows
    classes <- sheet_data |>
      dplyr::filter(
        !is.na(.data[[class_column]]),
        !grepl("^Note", .data[[class_column]])
      )

    tibble::tibble(
      data_source = "ICCT",
      year = as.integer(sheet),
      n_ship_classes = nrow(classes),
      emissions_co2_mt = sum(
        as.numeric(classes[[co2_column]]),
        na.rm = TRUE
      )
    )
  }) |>
    dplyr::arrange(.data$year)
}

# Download and summarize the OECD experimental maritime transport CO2 series.
#
# Pulled from the OECD SDMX API rather than a manual export, so the series
# refreshes with the pipeline:
# https://data-explorer.oecd.org/vis?df[id]=DSD_MARITIME_TRANSPORT%40DF_MARITIME_TRANSPORT
#
# Note this supersedes data/oecd/annual_oecd_experimental_data.csv, which is a
# hand-downloaded extract of dataflow version 1.0. Version 2.0 adds a METHODOLOGY
# dimension and revises the values, so the two are not interchangeable.
#
# Picking the right rows matters. The dataflow reports the same emissions under
# three overlapping accounting frameworks, and summing everything would multiply
# count the same tonnes:
#
#   EMISSIONS_SEEA / RES_TOTAL  a residence-based total (SEEA air emissions
#                               accounts), complete in a single row
#   EMISSIONS_POD               a territory-based split by port of departure,
#                               as international (TER_INT) plus domestic (TER_DOM)
#   _Z                          the individual components A-G that build up the
#                               totals above
#
# We take EMISSIONS_SEEA / RES_TOTAL: the residence-based total, attributing
# emissions to vessels operated by residents of the reference country wherever
# they sail. The dataflow labels it classification A_B_D_E_F, i.e. the sum of
#
#   A  domestic voyages in the reference country, by residents
#   B  domestic voyages outside the reference country, by residents
#   D  international voyages departing the reference country, by residents
#   E  international voyages arriving in the reference country, by residents
#   F  international voyages outside the reference country, by residents
#
# Components C and G (the non-resident-operated rows) are deliberately excluded.
# At REF_AREA = W every vessel is resident somewhere, so A+B+D+E+F already spans
# the global fleet; adding C and G would count the same voyages a second time
# from the counterpart country's perspective. This is also why RES_TOTAL arrives
# as a single row per year and needs no summation.
#
# As a cross-check the three frameworks agree to within 0.05% (for 2019: 889.4 Mt
# for SEEA, 888.9 Mt summing the port-of-departure split, and 889.3 Mt summing
# components A+B+D+E+F), the small spread coming from rounding in the published
# components.
#
# Caveat if this is ever extended past REF_AREA = W: the frameworks are
# equivalent globally but not nationally. Residence-based and territory-based
# accounting diverge sharply for flag-of-convenience registries, so a per-country
# breakdown would need this choice revisited rather than inherited.
#
# Values are absolute tonnes of CO2. Returns one row per year.
summarize_oecd_ship_co2 <- function(
  years,
  dataflow = "OECD.SDD.NAD.SEEA,DSD_MARITIME_TRANSPORT@DF_MARITIME_TRANSPORT,2.0"
) {
  years <- as.integer(years)

  # W = world, A = annual, ALL_VESSELS; the remaining dimensions stay open so a
  # new dimension being added upstream does not silently drop the series
  query_url <- sprintf(
    "https://sdmx.oecd.org/public/rest/data/%s/W.A.......ALL_VESSELS.?format=csvfilewithlabels",
    dataflow
  )

  download_dir <- file.path(tempdir(), "oecd_maritime")
  dir.create(download_dir, showWarnings = FALSE, recursive = TRUE)
  on.exit(unlink(download_dir, recursive = TRUE), add = TRUE)

  destination <- file.path(download_dir, "oecd_maritime_transport.csv")
  utils::download.file(
    query_url,
    destfile = destination,
    mode = "wb",
    quiet = TRUE
  )

  raw <- readr::read_csv(destination, show_col_types = FALSE)

  residence_total <- raw |>
    dplyr::filter(
      .data$METHODOLOGY == "EMISSIONS_SEEA",
      .data$VESSEL_EMISSIONS_SOURCE == "RES_TOTAL"
    )

  if (nrow(residence_total) == 0) {
    stop(
      "No EMISSIONS_SEEA / RES_TOTAL rows in the OECD response. The dataflow ",
      "dimensions may have changed; check ",
      query_url
    )
  }

  summarized <- residence_total |>
    dplyr::transmute(
      data_source = "OECD",
      oecd_dataflow_version = sub(".*,([0-9.]+)$", "\\1", dataflow),
      year = as.integer(.data$TIME_PERIOD),
      emissions_co2_mt = as.numeric(.data$OBS_VALUE)
    ) |>
    dplyr::filter(.data$year %in% years) |>
    dplyr::arrange(.data$year)

  # One row per year, or the framework filter has stopped being selective
  duplicated_years <- summarized$year[duplicated(summarized$year)]
  if (length(duplicated_years) > 0) {
    stop(
      "The OECD response has more than one total per year (",
      paste(sort(unique(duplicated_years)), collapse = ", "),
      "), which would double count. Check the METHODOLOGY dimension."
    )
  }

  missing_years <- setdiff(years, summarized$year)
  if (length(missing_years) > 0) {
    stop(
      "The OECD series has no data for: ",
      paste(sort(missing_years), collapse = ", "),
      ". It currently covers ",
      paste(range(as.integer(residence_total$TIME_PERIOD)), collapse = "-"),
      "."
    )
  }

  summarized
}

# Write a processed inventory table to data/inventories and return the path, so
# targets tracks the output file rather than just the in-memory object.
write_inventory_csv <- function(data, file_path) {
  dir.create(dirname(file_path), showWarnings = FALSE, recursive = TRUE)
  readr::write_csv(data, file_path)
  return(file_path)
}

# The IMO's own global shipping CO2 totals, from the Fourth IMO GHG Study 2020
# (voyage-based totals). The study covers 2012-2018; we carry the years that
# overlap the inventory figure's window, which starts in 2015, so this series
# runs 2015-2018. There is no machine-readable source to download, so the
# numbers are transcribed. This mirrors imo_data in qmd/quarto_notebook.qmd.
imo_ghg_study_co2 <- function() {
  tibble::tibble(
    data_source = "IMO",
    year = c(2015L, 2016L, 2017L, 2018L),
    emissions_co2_mt = c(991e6, 1.026e9, 1.064e9, 1.056e9)
  )
}

# MariTEAM model global shipping CO2. The published assessment reports a single
# year, so this series is one point and draws as a point rather than a line.
mariteam_ship_co2 <- function() {
  tibble::tibble(
    data_source = "MariTEAM",
    year = 2017L,
    emissions_co2_mt = 943e6
  )
}

# Rebuild the GFW and EDGAR marine CO2 series that Figure S4 compares against.
# Both are derived in qmd/quarto_notebook.qmd rather than being targets of their
# own, so we read the same upstream targets from the notebook store and repeat
# the aggregation here. Keep this in sync with the wrangle-gfw-time-series and
# wrangle-edgar chunks of the notebook.
gfw_edgar_marine_co2 <- function(
  notebook_store = file.path("_targets", "02_quarto_notebook"),
  data_pull_store = file.path("_targets", "01_gfw_data_pull"),
  gfw_activity_file = file.path(
    "data",
    "gfw",
    "annual_ais_activity_summary_cheap.csv"
  )
) {
  analysis_start_year <- targets::tar_read(
    analysis_start_year,
    store = data_pull_store
  )
  analysis_end_year <- targets::tar_read(
    analysis_end_year,
    store = data_pull_store
  )

  # GFW: total CO2 by fleet, from the all-pollutant annual table
  annual_co2_by_fleet <- targets::tar_read(
    annual_emissions_all_pollutants,
    store = notebook_store
  ) |>
    tidyr::pivot_longer(
      -c(year, fishing),
      names_to = "pollutant",
      values_to = "emissions_mt"
    ) |>
    dplyr::mutate(
      fleet = ifelse(
        stringr::str_detect(pollutant, "dark"),
        "Non-broadcasting",
        "AIS-broadcasting"
      ),
      pollutant = stringr::str_remove_all(pollutant, "emissions_") |>
        stringr::str_remove_all("_mt") |>
        stringr::str_remove_all("_dark")
    ) |>
    dplyr::filter(pollutant == "co2") |>
    dplyr::group_by(year, fleet) |>
    dplyr::summarise(emissions_mt = sum(emissions_mt), .groups = "drop")

  # AIS + S1 is the sum over both fleets; AIS alone is the broadcasting fleet
  gfw_ais_s1 <- annual_co2_by_fleet |>
    dplyr::group_by(year) |>
    dplyr::summarise(
      emissions_co2_mt = sum(emissions_mt),
      .groups = "drop"
    ) |>
    dplyr::mutate(data_source = "GFW (AIS + S1)")

  gfw_ais <- annual_co2_by_fleet |>
    dplyr::filter(fleet == "AIS-broadcasting") |>
    dplyr::transmute(
      year,
      emissions_co2_mt = emissions_mt,
      data_source = "GFW (AIS)"
    )

  # Extend the AIS series before analysis_start_year.
  #
  # The all-pollutant table above is cut from the dark-fleet model run, which
  # holds no data before 2017 - so it bounds both GFW series even though AIS
  # itself was recorded earlier. The activity extract reads the AIS daily
  # gridded table instead, which does cover 2015-2016, and its yearly totals
  # reproduce the table above exactly (to floating point) across every
  # overlapping year, so the earlier years are the same measure carried further
  # back rather than a second estimate spliced onto the first.
  #
  # Only GFW (AIS) can be extended this way. AIS + S1 needs the non-broadcasting
  # half, which only the dark-fleet run provides, so that series still begins at
  # analysis_start_year and the two GFW lines start in different years by
  # construction.
  #
  # Treat the added years as a floor rather than a like-for-like continuation:
  # satellite AIS reception was thinner then, so vessels missing from the early
  # data are missing emissions, not zero emissions.
  if (!is.null(gfw_activity_file) && file.exists(gfw_activity_file)) {
    earlier_ais <- readr::read_csv(gfw_activity_file, show_col_types = FALSE) |>
      dplyr::mutate(year = as.integer(.data$year)) |>
      dplyr::filter(.data$year < analysis_start_year) |>
      dplyr::group_by(.data$year) |>
      dplyr::summarise(
        emissions_co2_mt = sum(.data$emissions_co2_mt, na.rm = TRUE),
        .groups = "drop"
      ) |>
      dplyr::mutate(data_source = "GFW (AIS)")

    gfw_ais <- dplyr::bind_rows(earlier_ais, gfw_ais) |>
      dplyr::arrange(.data$year)
  }

  # EDGAR: the water-borne navigation sector of the transportation table
  edgar_marine <- targets::tar_read(
    annual_edgar_emissions,
    store = notebook_store
  ) |>
    dplyr::rename(sector = ipcc_code_2006_for_standard_report_name) |>
    dplyr::select(sector, dplyr::starts_with("Y_")) |>
    tidyr::pivot_longer(
      cols = -sector,
      names_to = "year",
      values_to = "emissions_co2_kt"
    ) |>
    dplyr::filter(sector == "Water-borne Navigation") |>
    dplyr::mutate(
      year = as.integer(stringr::str_remove_all(year, "Y_")),
      # EDGAR reports kilotonnes; the comparison is in tonnes
      emissions_co2_mt = emissions_co2_kt * 1e3
    ) |>
    dplyr::group_by(year) |>
    dplyr::summarise(
      emissions_co2_mt = sum(emissions_co2_mt, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::mutate(data_source = "EDGAR") |>
    # EDGAR reaches back to 1970, far earlier than anything it is compared
    # against, so it keeps the analysis window's lower bound. Only the GFW AIS
    # series is allowed to start earlier, and only because the inventory figure
    # asks for those years specifically.
    dplyr::filter(year >= analysis_start_year)

  # No lower bound on the bind: the AIS extension above deliberately reaches
  # before analysis_start_year, and the other two series are already bounded by
  # their own sources. The upper bound stays, so a source published beyond the
  # analysis window does not quietly extend the figure to the right.
  dplyr::bind_rows(gfw_ais_s1, gfw_ais, edgar_marine) |>
    dplyr::mutate(year = as.integer(year)) |>
    dplyr::filter(year <= analysis_end_year)
}

# Stack every inventory onto the common data_source / year / emissions_co2_mt
# schema. The processed series arrive as file paths so targets invalidates this
# when a CSV is rewritten; the extra provenance columns each summarizer carries
# (model version, cell counts) are dropped here.
combine_inventory_series <- function(
  inventory_files,
  gfw_edgar_series,
  hardcoded_series = list(
    imo_ghg_study_co2(),
    mariteam_ship_co2()
  )
) {
  inventory_columns <- c("data_source", "year", "emissions_co2_mt")

  from_files <- purrr::map_dfr(inventory_files, function(file_path) {
    readr::read_csv(file_path, show_col_types = FALSE) |>
      dplyr::select(dplyr::all_of(inventory_columns))
  })

  dplyr::bind_rows(
    gfw_edgar_series |> dplyr::select(dplyr::all_of(inventory_columns)),
    from_files,
    purrr::map_dfr(
      hardcoded_series,
      dplyr::select,
      dplyr::all_of(inventory_columns)
    )
  ) |>
    dplyr::mutate(year = as.integer(year)) |>
    dplyr::arrange(data_source, year)
}

# Our AIS series split three ways by registry status, on the same schema the
# inventory table uses, so the three can be drawn as extra lines on the
# inventory-comparison figure.
#
# These are not inventories and are not independent of the GFW (AIS) line: they
# partition it, and the three sum back to it exactly in every year. Drawn beside
# the published inventories they answer a different question from the rest of the
# figure -- not "how does our total compare" but "which part of our total do the
# other inventories have any way of seeing". The IMO-registry line is the closest
# thing here to the fleet a registry-derived inventory enumerates.
#
# Reads annual_ais_activity_summary_cheap.csv, the only extract carrying
# registry_type. Years outside the inventory figure's window are left in; the
# plotting function filters to start_year itself.
gfw_registry_series <- function(
  gfw_activity_file = file.path(
    "data",
    "gfw",
    "annual_ais_activity_summary_cheap.csv"
  )
) {
  registry_labels <- c(
    imo = "GFW (AIS, IMO registry)",
    other_registry = "GFW (AIS, other registry)",
    no_registry = "GFW (AIS, no registry)"
  )

  activity <- readr::read_csv(gfw_activity_file, show_col_types = FALSE) |>
    dplyr::mutate(year = as.integer(.data$year))

  split <- activity |>
    dplyr::mutate(
      data_source = unname(registry_labels[.data$registry_type])
    ) |>
    dplyr::group_by(.data$data_source, .data$year) |>
    dplyr::summarise(
      emissions_co2_mt = sum(.data$emissions_co2_mt, na.rm = TRUE),
      .groups = "drop"
    )

  # The two registered fragments summed. This is the line that matters most for
  # the comparison: it is the emissions of the fleet a registry-derived
  # inventory could enumerate at all, whichever register it drew on, and so the
  # closest like-for-like against inventories built from commercial registries.
  # It overlaps the two fragments it contains by construction, which is why it
  # is drawn rather than left to be read off them.
  any_registry <- activity |>
    dplyr::filter(.data$registry_type != "no_registry") |>
    dplyr::group_by(.data$year) |>
    dplyr::summarise(
      emissions_co2_mt = sum(.data$emissions_co2_mt, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::mutate(data_source = "GFW (AIS, any registry)")

  dplyr::bind_rows(split, any_registry) |>
    dplyr::arrange(.data$data_source, .data$year)
}

inventory_linetypes <- function(data_sources) {
  linetypes <- rep("solid", length(data_sources))
  names(linetypes) <- data_sources
  # The registry split is a partition of our own AIS line rather than an
  # independent series, so the three fragments are dashed. Solid is reserved for
  # series that stand on their own, which keeps a fragment from reading as
  # another inventory's estimate.
  linetypes[startsWith(names(linetypes), "GFW (AIS, ")] <- "22"
  linetypes
}

inventory_color_palette <- function(data_sources) {
  okabe_ito <- paletteer::paletteer_d("colorblindr::OkabeIto")

  known <- c(
    "GFW (AIS + S1)" = okabe_ito[[5]],
    "GFW (AIS)" = okabe_ito[[1]],
    # The two narrowed GFW scopes follow the convention multisector_colors() sets:
    # same source, lighter as the scope narrows. Taken from that function's blue
    # ramp rather than reinvented, so a reader moving between the two figures sees
    # the same scope at the same lightness.
    "GFW (AIS, maritime transport)" = "#6BAED6",
    "GFW (AIS, maritime transport excl. passenger)" = "#BDD7E7",
    "EDGAR" = okabe_ito[[8]],
    "OECD" = okabe_ito[[6]],
    "IMO" = okabe_ito[[3]],
    # Keyed on the display label set in plot_inventory_comparison(), not the
    # longer name carried in the data
    "STEAM" = okabe_ito[[2]],
    # Okabe-Ito's yellow is too low-contrast on white for a thin line, so SEIM
    # takes a darker hue from outside the palette
    "SEIM" = "#7B3294",
    "ICCT" = okabe_ito[[7]],
    "MariTEAM" = "grey30",
    # The AIS series split by registry status. These are not inventories - they
    # are our own AIS total partitioned three ways, and they sum back to it in
    # every year - so they stay inside the GFW blues rather than taking hues of
    # their own, following the convention multisector_colors() sets: same source,
    # lighter as the scope narrows. They are also drawn dashed by
    # inventory_linetypes(), which is what separates a fragment of our total from
    # a series that stands on its own.
    #
    # Ordered by registry information rather than by size: the combined
    # registered fleet is darkest, then IMO alone, then other registers, with
    # no-registry lightest. The combined line takes the darkest because it is
    # the aggregate the other two partition, matching how the ramp treats
    # scope elsewhere.
    "GFW (AIS, any registry)" = "#4292C6",
    "GFW (AIS, IMO registry)" = "#6BAED6",
    "GFW (AIS, other registry)" = "#9ECAE1",
    "GFW (AIS, no registry)" = "#C6DBEF"
  )

  missing <- setdiff(data_sources, names(known))
  if (length(missing) > 0) {
    stop(
      "No color assigned for inventory: ",
      paste(missing, collapse = ", "),
      ". Add it to inventory_color_palette()."
    )
  }

  known[data_sources]
}

# Fleet composition ----
# Paired pies comparing each vessel class's share of CO2 emissions against its
# share of the fleet by vessel count. Emissions come from the same trip and
# port-visit extracts that feed figure 3, so the two panels describe the same
# classes; note the counts are not year-filtered (vessel_info has no date
# column) while the emissions are restricted to analysis_end_year.

# Turn a raw GFW vessel_class into the label used on the pies, folding every
# fishing gear type into one slice.
gfw_vessel_class_label <- function(vessel_class) {
  ifelse(
    vessel_class %in% fishing_vessel_classes(),
    "Fishing",
    # Same transform the notebook applies for figure 3, so the two figures label
    # the same class identically. tanker.chemical stays "Tanker: chemical": it is
    # a separate class from tanker.oil, so folding "or oil" into the name would
    # imply a merge that has not happened.
    stringr::str_replace_all(vessel_class, "\\.", ": ") |>
      stringr::str_replace_all("_", " ") |>
      stringr::str_to_sentence()
  )
}

# The same composition, but resolved by year rather than collapsed into a single
# total. Each year is normalised on its own, so a column answers "what did the
# fleet / the emissions look like that year", not "how did the fleet grow".
#
# Vessel counts start in 2015 but the emissions extracts start in 2017, so the
# series is intersected down to the years both cover; keeping the extra count
# years would draw fleet columns with no emissions column beside them.
fleet_emissions_and_size_by_year <- function(
  gfw_activity_file = file.path(
    "data",
    "gfw",
    "annual_ais_activity_summary.csv"
  )
) {
  # Both columns come from the one extract, so no join, no year intersection and
  # no NA filling: every class-year row carries its own emissions and its own
  # vessel count, and the two are guaranteed to describe the same activity.
  #
  # This deliberately does NOT use the trip and port-visit extracts. Those
  # attribute emissions to completed voyages and port visits, so they miss
  # activity the ping table includes -- their 2025 total runs about 14% below the
  # annual figure the paper reports in figure 1A. Reading the activity summary
  # instead makes these figures agree with that headline number.
  #
  # No peak-over-years step: within a single year the counts are already a fleet
  # size, so they only need summing over the sub-classes folding into each label.
  readr::read_csv(gfw_activity_file, show_col_types = FALSE) |>
    dplyr::mutate(vessel_class = gfw_vessel_class_label(.data$vessel_class)) |>
    dplyr::group_by(vessel_class, .data$year) |>
    dplyr::summarise(
      emissions_co2_mt = sum(.data$emissions_co2_mt, na.rm = TRUE),
      n_unique_vessels = sum(.data$n_unique_vessels, na.rm = TRUE),
      .groups = "drop"
    ) |>
    # Shares are within-year, so each year's two columns each sum to 100 %.
    dplyr::group_by(.data$year) |>
    dplyr::mutate(
      share_emissions = .data$emissions_co2_mt / sum(.data$emissions_co2_mt),
      share_vessels = .data$n_unique_vessels / sum(.data$n_unique_vessels)
    ) |>
    dplyr::ungroup() |>
    dplyr::arrange(.data$year, dplyr::desc(.data$emissions_co2_mt))
}

# The same composition question asked of registry status instead of vessel class:
# how much of the fleet, and how much of its CO2, sits on the IMO register, on
# some other public register, or on none at all.
#
# This is the split that separates a coverage difference from a modelling one.
# Vessels with no registry entry have no published engine power or design speed,
# so their characteristics are modelled rather than looked up; they are also the
# vessels a registry-derived inventory cannot enumerate at all. Their share of
# the fleet against their share of the emissions is the whole argument in two
# numbers.
#
# Reads annual_ais_activity_summary_cheap.csv rather than the ping-level extract,
# because the registry_type column only exists there. The two agree exactly on
# every shared measure, so this is the same fleet the class figures describe --
# see the header of sql/annual_ais_activity_summary_cheap.sql.
#
# Labels are set here rather than in the SQL so the figure can be relabelled
# without re-running a 233 GiB query. The order is deliberate and is the order
# the columns stack in: IMO first as the most documented, none last.
registry_emissions_and_size_by_year <- function(
  gfw_activity_file = file.path(
    "data",
    "gfw",
    "annual_ais_activity_summary_cheap.csv"
  )
) {
  registry_labels <- c(
    imo = "IMO registry",
    other_registry = "Other registry",
    no_registry = "No registry"
  )

  readr::read_csv(gfw_activity_file, show_col_types = FALSE) |>
    # vessel_class is the column the plotting code groups on, so the registry
    # label takes its place. Nothing downstream needs the class split, and
    # keeping both would double-count vessels across the two dimensions.
    #
    # Character rather than factor: the plotting code builds its own level order
    # with stacked_class_levels() and indexes the palette by name, so a factor
    # arriving here is dropped to its integer codes by the ifelse() folding steps
    # and the groups end up labelled "1", "2", "3".
    dplyr::mutate(
      vessel_class = unname(registry_labels[.data$registry_type])
    ) |>
    dplyr::group_by(vessel_class, .data$year) |>
    dplyr::summarise(
      emissions_co2_mt = sum(.data$emissions_co2_mt, na.rm = TRUE),
      n_unique_vessels = sum(.data$n_unique_vessels, na.rm = TRUE),
      .groups = "drop"
    ) |>
    # Shares are within-year, so each year's two columns each sum to 100 %.
    dplyr::group_by(.data$year) |>
    dplyr::mutate(
      share_emissions = .data$emissions_co2_mt / sum(.data$emissions_co2_mt),
      share_vessels = .data$n_unique_vessels / sum(.data$n_unique_vessels)
    ) |>
    dplyr::ungroup() |>
    dplyr::arrange(.data$year, .data$vessel_class)
}


# Class ordering for the stacked columns: by fleet size in the most recent year,
# with the catch-all classes pushed to the end. Ranked on the latest year rather
# than on an average so the legend order matches the column a reader is most
# likely to be looking at.
#
# Pulled out of the plotting function because it is needed twice: once for the
# levels the figure actually draws, and once over the unfolded class list to fix
# each class's colour (see the palette note in plot_fleet_sankey_with_series).
stacked_class_levels <- function(fleet_data) {
  trailing <- c("Other", "Other not fishing")
  latest <- max(fleet_data$year)
  ordered <- fleet_data |>
    dplyr::filter(
      .data$year == latest,
      !.data$vessel_class %in% trailing
    ) |>
    dplyr::arrange(
      dplyr::desc(.data$n_unique_vessels),
      dplyr::desc(.data$emissions_co2_mt)
    ) |>
    dplyr::pull(.data$vessel_class)
  c(ordered, intersect(trailing, fleet_data$vessel_class))
}


# Multi-sector inventories ----
# Everything above this point compares shipping-specific inventories: models
# built to estimate marine vessel emissions and nothing else (STEAM, SEIM, ICCT,
# IMO, MariTEAM, OECD). The functions below are a separate comparison against
# multi-sector inventories - global databases that estimate every emitting
# sector, of which shipping is one line among dozens.
#
# The two are kept apart deliberately. A shipping model and a global inventory
# disagree for different reasons (activity data and fleet coverage versus sector
# allocation and fuel statistics), and the multi-sector sources carry an
# all-sector total that the shipping models have no counterpart for. Mixing them
# into the existing figures would also put a ~39,000 Mt line beside ~800 Mt ones.
#
# Two inventories are covered, both downloaded from their published source the
# way the shipping inventories above are - nothing here reads a hand-downloaded
# file from the repo:
#
#   EDGAR   the JRC/IEA EDGAR 2025 release. The notebook already reads a manual
#           copy of this workbook from data/IEA_EDGAR_CO2_1970_2024/; the zip
#           downloaded here contains a byte-identical xlsx, so this target
#           reproduces that file from its source and additionally carries the
#           all-sector total, which the notebook's own aggregation does not
#           store.
#
#   CEDS    the Community Emissions Data System, v_2025_03_18, from Zenodo.
#           Unlike EDGAR it splits marine into international shipping and
#           domestic navigation as separate sectors, so both the IMO-comparable
#           (international only) and EDGAR-comparable (international + domestic)
#           scopes can be read off the same source.

# EDGAR's marine sector on the IPCC 2006 sheet. One label, covering
# international bunkers and inland navigation together: the 2006 codes collapse
# both into 1.A.3.d, so this is the only marine sector that sheet exposes.
edgar_marine_sector <- function() {
  "Water-borne Navigation"
}

# EDGAR's marine sectors on the IPCC 1996 sheet, which does keep the two apart.
# The same underlying EDGAR series are filed as:
#
#   1C2   "Memo: International navigation"  (EDGAR code TNR.SEA), reported as
#         the single global entity SEA - international bunkers
#   1A3d  "Inland navigation"               (EDGAR code TNR.ILW), reported per
#         country - inland waterways and domestic marine
#
# They sum to the 2006 sheet's Water-borne Navigation exactly, so reading the
# 1996 sheet costs nothing and buys the split. This matters because CEDS reports
# international and domestic separately, and without the split EDGAR can only be
# compared against CEDS' combined total.
edgar_marine_sectors_1996 <- function(
  scope = c("international", "inland", "total")
) {
  scope <- match.arg(scope)

  international <- "Memo: International navigation"
  inland <- "Inland navigation"

  switch(
    scope,
    international = international,
    inland = inland,
    total = c(international, inland)
  )
}

# CEDS marine sectors, split by scope.
#
# international is the bunkers sector alone, which is what the IMO studies
# estimate. total adds domestic navigation, which is the scope EDGAR's single
# Water-borne Navigation sector covers - so comparing EDGAR against CEDS
# like-for-like means using the total, not the international series.
#
# CEDS also files 1A3di_Oil_Tanker_Loading under the international code family,
# but it is evaporative VOC loss from cargo handling rather than fuel
# combustion, and reports as zero throughout the CO2 release. It is left out.
# The scope argument mirrors edgar_marine_sectors_1996(), so both inventories
# expose the same three marine scopes. "inland" is CEDS' domestic navigation:
# the name is shared with EDGAR's TNR.ILW for symmetry on the figures, but the
# two are not identical in scope - EDGAR's is inland waterways while CEDS'
# 1A3dii also covers coastal domestic traffic, which is part of why CEDS reports
# more of it.
ceds_marine_sectors <- function(
  scope = c("international", "inland", "total")
) {
  scope <- match.arg(scope)

  international <- "1A3di_International-shipping"
  inland <- "1A3dii_Domestic-navigation"

  switch(
    scope,
    international = international,
    inland = inland,
    total = c(international, inland)
  )
}

# The non-marine transportation sectors, for the "other transportation sectors"
# series that the notebook's figure 4 panel B draws from EDGAR.
#
# Both inventories carry the same four modes - road, aviation, rail and an
# other/non-specified class - but name them differently, and CEDS splits
# aviation into international and domestic where EDGAR has one civil aviation
# sector. Summing each source's own list keeps the series internally consistent;
# the two are not identical in scope, which is why they are drawn as two lines
# rather than pooled.
edgar_other_transport_sectors <- function() {
  c(
    "Civil Aviation",
    "Road Transportation no resuspension",
    "Other Transportation",
    "Railways"
  )
}

ceds_other_transport_sectors <- function() {
  c(
    "1A3ai_International-aviation",
    "1A3aii_Domestic-aviation",
    "1A3b_Road",
    "1A3c_Rail",
    "1A3eii_Other-transp"
  )
}

# Download and summarize the EDGAR 2025 workbook into its shipping, other
# transportation and all-sector series.
#
# The release is a 4.4 MB zip holding one xlsx: one row per country and sector
# with a Y_<year> column per year, in kilotonnes. Every series is a filter and a
# sum over that table. The zip goes to a temp directory and is deleted in the
# same call, as the other downloads in this pipeline are - only the processed
# CSV is kept.
#
# Two sheets are read. The IPCC 2006 sheet carries the sector list used for the
# all-sector and other-transportation series, but folds all marine into one
# Water-borne Navigation code. The IPCC 1996 sheet splits the same marine
# emissions into international bunkers and inland navigation, so the marine
# scopes come from there and are checked against the 2006 total.
#
# Returns one row per year and scope, in tonnes, matching the units the shipping
# inventories are stored in. Scopes: Shipping (all marine), Shipping
# (international), Shipping (inland), Other transportation, All sectors.
summarize_edgar_multisector_co2 <- function(
  years,
  version = "EDGAR 2025",
  source_url = paste0(
    "https://jeodpp.jrc.ec.europa.eu/ftp/jrc-opendata/EDGAR/datasets/",
    "EDGAR_2025_GHG/IEA_EDGAR_CO2_1970_2024.zip"
  ),
  sheet = "IPCC 2006",
  sheet_1996 = "IPCC 1996",
  skip = 9,
  timeout_seconds = 1200
) {
  years <- as.integer(years)

  # See summarize_ceds_multisector_co2(): R's 60 second default is enough for
  # this 4.4 MB archive on a good connection but not a slow one, and a timeout
  # surfaces as a download failure rather than a retry
  previous_timeout <- getOption("timeout")
  options(timeout = max(previous_timeout, timeout_seconds))
  on.exit(options(timeout = previous_timeout), add = TRUE)

  download_dir <- file.path(tempdir(), "edgar_multisector")
  dir.create(download_dir, showWarnings = FALSE, recursive = TRUE)
  on.exit(unlink(download_dir, recursive = TRUE), add = TRUE)

  archive <- file.path(download_dir, "edgar_co2.zip")
  utils::download.file(
    source_url,
    destfile = archive,
    mode = "wb",
    quiet = TRUE
  )

  members <- utils::unzip(archive, list = TRUE)$Name
  workbook <- grep("\\.xlsx$", members, value = TRUE)

  if (length(workbook) != 1) {
    stop(
      "Expected exactly one xlsx in the EDGAR release, found ",
      length(workbook),
      ". The release layout may have changed; members: ",
      paste(members, collapse = ", ")
    )
  }

  utils::unzip(archive, files = workbook, exdir = download_dir)

  raw <- readxl::read_excel(
    file.path(download_dir, workbook),
    sheet = sheet,
    skip = skip
  )

  long <- raw |>
    dplyr::rename(sector = ipcc_code_2006_for_standard_report_name) |>
    dplyr::select(sector, dplyr::starts_with("Y_")) |>
    tidyr::pivot_longer(
      cols = -sector,
      names_to = "year",
      values_to = "emissions_co2_kt"
    ) |>
    dplyr::mutate(
      year = as.integer(stringr::str_remove_all(year, "Y_")),
      # EDGAR reports kilotonnes; every series here is in tonnes
      emissions_co2_mt = emissions_co2_kt * 1e3
    ) |>
    dplyr::filter(year %in% years)

  available_years <- as.integer(stringr::str_remove_all(
    grep("^Y_", names(raw), value = TRUE),
    "Y_"
  ))
  missing_years <- setdiff(years, unique(long$year))
  if (length(missing_years) > 0) {
    stop(
      "The EDGAR workbook has no data for: ",
      paste(sort(missing_years), collapse = ", "),
      ". It covers ",
      paste(range(available_years), collapse = "-"),
      "."
    )
  }

  marine_sector <- edgar_marine_sector()
  if (!marine_sector %in% unique(long$sector)) {
    stop(
      "EDGAR sector '",
      marine_sector,
      "' is not in the workbook. The sector naming may have changed; found: ",
      paste(sort(unique(long$sector)), collapse = ", ")
    )
  }

  other_transport <- edgar_other_transport_sectors()
  absent_transport <- setdiff(other_transport, unique(long$sector))
  if (length(absent_transport) > 0) {
    stop(
      "EDGAR transportation sectors not found in the workbook: ",
      paste(absent_transport, collapse = ", "),
      ". The sector naming may have changed."
    )
  }

  shipping <- long |>
    dplyr::filter(sector == marine_sector) |>
    dplyr::group_by(year) |>
    dplyr::summarise(
      emissions_co2_mt = sum(emissions_co2_mt, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::mutate(scope = "Shipping")

  # The 2006 sheet folds international bunkers and inland navigation into one
  # sector; the 1996 sheet keeps them apart, so the split scopes are read from
  # there. Both sheets are in the same workbook, already downloaded.
  raw_1996 <- readxl::read_excel(
    file.path(download_dir, workbook),
    sheet = sheet_1996,
    skip = skip
  )

  long_1996 <- raw_1996 |>
    dplyr::rename(sector = ipcc_code_1996_for_standard_report_name) |>
    dplyr::select(sector, dplyr::starts_with("Y_")) |>
    tidyr::pivot_longer(
      cols = -sector,
      names_to = "year",
      values_to = "emissions_co2_kt"
    ) |>
    dplyr::mutate(
      year = as.integer(stringr::str_remove_all(year, "Y_")),
      emissions_co2_mt = emissions_co2_kt * 1e3
    ) |>
    dplyr::filter(year %in% years)

  absent_1996 <- setdiff(
    edgar_marine_sectors_1996("total"),
    unique(long_1996$sector)
  )
  if (length(absent_1996) > 0) {
    stop(
      "EDGAR 1996-sheet marine sectors not found: ",
      paste(absent_1996, collapse = ", "),
      ". The sector naming may have changed."
    )
  }

  sum_1996 <- function(sectors, scope_label) {
    long_1996 |>
      dplyr::filter(sector %in% sectors) |>
      dplyr::group_by(year) |>
      dplyr::summarise(
        emissions_co2_mt = sum(emissions_co2_mt, na.rm = TRUE),
        .groups = "drop"
      ) |>
      dplyr::mutate(scope = scope_label)
  }

  shipping_international <- sum_1996(
    edgar_marine_sectors_1996("international"),
    "Shipping (international)"
  )
  shipping_inland <- sum_1996(
    edgar_marine_sectors_1996("inland"),
    "Shipping (inland)"
  )

  # The two 1996 sectors must reconstruct the 2006 sheet's single marine sector,
  # or the sheets disagree about what counts as water-borne navigation and the
  # split scopes cannot be read beside the combined one
  reconciliation <- shipping |>
    dplyr::select(year, combined = emissions_co2_mt) |>
    dplyr::inner_join(
      sum_1996(edgar_marine_sectors_1996("total"), "split") |>
        dplyr::select(year, split = emissions_co2_mt),
      by = "year"
    ) |>
    dplyr::filter(abs(combined - split) > 1)

  if (nrow(reconciliation) > 0) {
    stop(
      "EDGAR's 1996 marine sectors do not sum to the 2006 Water-borne ",
      "Navigation total for: ",
      paste(sort(reconciliation$year), collapse = ", "),
      ". The two sheets disagree about marine scope."
    )
  }

  other_transportation <- long |>
    dplyr::filter(sector %in% other_transport) |>
    dplyr::group_by(year) |>
    dplyr::summarise(
      emissions_co2_mt = sum(emissions_co2_mt, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::mutate(scope = "Other transportation")

  all_sectors <- long |>
    dplyr::group_by(year) |>
    dplyr::summarise(
      emissions_co2_mt = sum(emissions_co2_mt, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::mutate(scope = "All sectors")

  dplyr::bind_rows(
    shipping,
    shipping_international,
    shipping_inland,
    other_transportation,
    all_sectors
  ) |>
    dplyr::transmute(
      data_source = "EDGAR",
      inventory_version = version,
      scope,
      year,
      emissions_co2_mt
    ) |>
    dplyr::arrange(scope, year)
}

# Download and summarize the CEDS global-by-sector CO2 table.
#
# The Zenodo record holds several bundles; this reads the aggregate one, whose
# global_estimates_by_sector file is a single ~170 KB CSV with one row per
# sector and an X<year> column per year, in kilotonnes. The 63 MB zip is
# downloaded to a temp directory and deleted in the same call.
#
# Returns three scopes per year: shipping on both definitions (see
# ceds_marine_sectors()) and the all-sector total.
summarize_ceds_multisector_co2 <- function(
  years,
  version = "v_2025_03_18",
  source_url = paste0(
    "https://zenodo.org/records/15059443/files/",
    "CEDS_v_2025_03_18_aggregate.zip?download=1"
  ),
  timeout_seconds = 1200
) {
  years <- as.integer(years)

  # R's default download timeout is 60 seconds, which this 63 MB archive does
  # not finish in - and download.file() reports the truncated file as a failure
  # rather than a partial read. Raised here rather than left to the caller so
  # the target does not depend on an option set outside the pipeline.
  previous_timeout <- getOption("timeout")
  options(timeout = max(previous_timeout, timeout_seconds))
  on.exit(options(timeout = previous_timeout), add = TRUE)

  download_dir <- file.path(tempdir(), "ceds_aggregate")
  dir.create(download_dir, showWarnings = FALSE, recursive = TRUE)
  on.exit(unlink(download_dir, recursive = TRUE), add = TRUE)

  archive <- file.path(download_dir, "ceds_aggregate.zip")
  utils::download.file(
    source_url,
    destfile = archive,
    mode = "wb",
    quiet = TRUE
  )

  members <- utils::unzip(archive, list = TRUE)$Name
  sector_file <- grep(
    paste0("CO2_CEDS_global_estimates_by_sector_", version, "\\.csv$"),
    members,
    value = TRUE
  )
  # The archive carries __MACOSX resource-fork copies of every member, which
  # match the name pattern but are not readable CSVs
  sector_file <- grep("__MACOSX", sector_file, value = TRUE, invert = TRUE)

  if (length(sector_file) != 1) {
    stop(
      "Expected exactly one CEDS global-by-sector CO2 file for version ",
      version,
      " in the archive, found ",
      length(sector_file),
      ". The record layout may have changed; members: ",
      paste(utils::head(members, 20), collapse = ", ")
    )
  }

  utils::unzip(archive, files = sector_file, exdir = download_dir)

  raw <- readr::read_csv(
    file.path(download_dir, sector_file),
    show_col_types = FALSE
  )

  units <- unique(raw$units)
  if (!identical(units, "ktCO2")) {
    stop(
      "CEDS units are '",
      paste(units, collapse = ", "),
      "', not the expected 'ktCO2'. The conversion below would be wrong."
    )
  }

  long <- raw |>
    dplyr::select(sector, dplyr::matches("^X[0-9]{4}$")) |>
    tidyr::pivot_longer(
      cols = -sector,
      names_to = "year",
      values_to = "emissions_co2_kt"
    ) |>
    dplyr::mutate(
      year = as.integer(stringr::str_remove(year, "^X")),
      # CEDS reports kilotonnes, as EDGAR does
      emissions_co2_mt = emissions_co2_kt * 1e3
    ) |>
    dplyr::filter(year %in% years)

  available_years <- as.integer(stringr::str_remove(
    grep("^X[0-9]{4}$", names(raw), value = TRUE),
    "^X"
  ))
  missing_years <- setdiff(years, unique(long$year))
  if (length(missing_years) > 0) {
    stop(
      "The CEDS series has no data for: ",
      paste(sort(missing_years), collapse = ", "),
      ". It currently covers ",
      paste(range(available_years), collapse = "-"),
      "."
    )
  }

  # Every sector named must exist, or a scope would silently sum to less than it
  # claims to cover
  absent <- setdiff(
    c(ceds_marine_sectors("total"), ceds_other_transport_sectors()),
    unique(long$sector)
  )
  if (length(absent) > 0) {
    stop(
      "CEDS sectors not found in the release: ",
      paste(absent, collapse = ", "),
      ". The sector naming may have changed."
    )
  }

  sum_over <- function(sectors, scope_label) {
    long |>
      dplyr::filter(sector %in% sectors) |>
      dplyr::group_by(year) |>
      dplyr::summarise(
        emissions_co2_mt = sum(emissions_co2_mt, na.rm = TRUE),
        .groups = "drop"
      ) |>
      dplyr::mutate(scope = scope_label)
  }

  dplyr::bind_rows(
    sum_over(ceds_marine_sectors("total"), "Shipping"),
    sum_over(ceds_marine_sectors("international"), "Shipping (international)"),
    sum_over(ceds_marine_sectors("inland"), "Shipping (inland)"),
    sum_over(ceds_other_transport_sectors(), "Other transportation"),
    long |>
      dplyr::group_by(year) |>
      dplyr::summarise(
        emissions_co2_mt = sum(emissions_co2_mt, na.rm = TRUE),
        .groups = "drop"
      ) |>
      dplyr::mutate(scope = "All sectors")
  ) |>
    dplyr::transmute(
      data_source = "CEDS",
      inventory_version = paste("CEDS", version),
      scope,
      year,
      emissions_co2_mt
    ) |>
    dplyr::arrange(scope, year)
}

# Stack the multi-sector inventories onto one table.
#
# Deliberately a different schema from combine_inventory_series(): that one is
# keyed on data_source alone because every series it holds is shipping, while
# these carry a scope column because each source contributes both a shipping and
# an all-sector series.
combine_multisector_series <- function(inventory_files) {
  multisector_columns <- c(
    "data_source",
    "inventory_version",
    "scope",
    "year",
    "emissions_co2_mt"
  )

  purrr::map_dfr(inventory_files, function(file_path) {
    readr::read_csv(file_path, show_col_types = FALSE) |>
      dplyr::select(dplyr::all_of(multisector_columns))
  }) |>
    dplyr::mutate(year = as.integer(year)) |>
    dplyr::arrange(data_source, scope, year)
}

# Colors for the multi-sector figures. Separate from
# inventory_color_palette(): that one is keyed on inventory, because every
# series there is shipping and the inventory is the only thing that varies.
# Here two inventories each carry several scopes, so the key has to name both.
#
# EDGAR keeps the Okabe-Ito hue it already has in the notebook figures and in
# the shipping comparison, so a reader carries one color for EDGAR across every
# figure in the paper. CEDS takes a hue not used by any shipping inventory.
# The scheme is two-dimensional, so a reader can decode a line without going
# back to the key twice:
#
#   hue       = which source it comes from. The three are far apart on the wheel
#               (GFW blue, EDGAR orange-red, CEDS green) and are distinguishable
#               under the common forms of color vision deficiency, since no two
#               sit on the red-green axis together.
#   lightness = how wide the scope is, dark to light, consistently in every
#               family: the widest scope is darkest and each narrower one is a
#               step lighter.
#
# So two lines of the same hue are always the same source at different scopes,
# and two lines of similar lightness are always comparable scopes from different
# sources. That is what makes the like-for-like pairs - EDGAR international
# against CEDS international, say - readable as a pair rather than as two
# unrelated lines.
#
# Ramps are hand-picked rather than generated, so each step stays above the
# contrast needed to separate thin lines on white.
#
# Declaration order is load-bearing: multisector_series_order() reads it to lay
# out the legend, so the series are listed grouped by source and widest scope
# first within each group.
multisector_colors <- function() {
  c(
    # GFW - blues. Widest fleet (AIS + S1) darkest, narrowing through the full
    # broadcasting fleet to the two maritime-transport subsets
    "GFW (AIS + S1)" = "#08306B",
    "GFW (AIS)" = "#2171B5",
    "GFW (AIS, maritime transport)" = "#6BAED6",
    "GFW (AIS, maritime transport excl. passenger)" = "#BDD7E7",

    # EDGAR - oranges and reds
    "EDGAR - All sectors" = "#7F2704",
    "EDGAR - Other transportation" = "#D94801",
    "EDGAR - Shipping" = "#F16913",
    "EDGAR - Shipping (international)" = "#FD8D3C",
    "EDGAR - Shipping (inland)" = "#FDD0A2",

    # CEDS - greens
    "CEDS - All sectors" = "#00441B",
    "CEDS - Other transportation" = "#238B45",
    "CEDS - Shipping" = "#41AB5D",
    "CEDS - Shipping (international)" = "#74C476",
    "CEDS - Shipping (inland)" = "#C7E9C0"
  )
}

# Legend order for the multi-sector figures: grouped by source, and within a
# source from widest scope to narrowest.
#
# Ordering by magnitude instead - as the shipping-inventory figures above do -
# interleaves the three sources, so a reader scanning the key has to hunt for
# one inventory's scopes among the others. Grouping puts each source's block
# together and makes the lightness ramp read top-to-bottom within it.
#
# The order is multisector_colors()' declaration order, so the legend and the
# palette cannot drift apart: adding a series there places it in the legend too,
# in whatever position it was declared.
multisector_series_order <- function(series_labels) {
  intersect(names(multisector_colors()), series_labels)
}

# Fleet growth by class ----
# The fleet-composition figures above answer "what share of the fleet was this
# class in year X". These answer the other question: how much has each class
# grown since the baseline, in vessel count, in ping volume and in CO2.
#
# Shares and growth say different things and can point opposite ways - a class
# can grow every year while its share falls, if the rest of the fleet grows
# faster - so this is not a restatement of the stacked columns.
#
# Both measures come from the same class-year rows of the activity extract that
# feed the composition figures, and are grouped with the same rules, so a class
# means the same thing in every fleet figure.
#
# The vessel count is COUNT(DISTINCT ssvid) computed per class, so summing it
# over the classes folded into a group double counts any ssvid that changed
# class within a year. Growth within a class is unaffected; only the "Other"
# group carries the caveat, and it is small. Pings and CO2 are additive, so they
# are exact for every group.
fleet_growth_by_year <- function(
  gfw_activity_file = file.path(
    "data",
    "gfw",
    "annual_ais_activity_summary.csv"
  ),
  baseline_year = 2017L,
  # The same folding rules the composition figures use, so the class list
  # matches. The "other" members are named explicitly rather than caught by a
  # share threshold, so a class cannot drift in or out of the fold between years
  # and change what the legend means.
  #
  # The three reefer classes go into "Other" here rather than carrying their own
  # "Reefer" label as they do in the composition figures. This figure draws
  # growth against a 2017 baseline, and the reefer count declines over the
  # period while every other class rises, so a separate reefer line reads as the
  # one interesting series in panel A when it is really the smallest segment on
  # the chart. The composition figures keep the label because a share column
  # shows its size at the same time; a growth line does not.
  min_share = 0.005,
  grouped_as_other = c(
    "Specialized reefer",
    "Container reefer",
    "Cargo: refrigerated",
    "Supply vessel",
    "Patrol vessel",
    "Bunker",
    "Dredge non fishing",
    "Other not fishing"
  )
) {
  baseline_year <- as.integer(baseline_year)

  by_class <- readr::read_csv(gfw_activity_file, show_col_types = FALSE) |>
    dplyr::mutate(
      vessel_class = gfw_vessel_class_label(.data$vessel_class),
      year = as.integer(.data$year)
    ) |>
    dplyr::filter(.data$year >= baseline_year) |>
    dplyr::group_by(.data$vessel_class, .data$year) |>
    dplyr::summarise(
      n_unique_vessels = sum(.data$n_unique_vessels, na.rm = TRUE),
      n_pings = sum(.data$n_pings, na.rm = TRUE),
      emissions_co2_mt = sum(.data$emissions_co2_mt, na.rm = TRUE),
      .groups = "drop"
    )

  if (!baseline_year %in% by_class$year) {
    stop(
      "The activity extract has no data for baseline_year ",
      baseline_year,
      ". It covers ",
      paste(range(by_class$year), collapse = "-"),
      "."
    )
  }

  # A class is folded into "Other" only if it is small in every year, matching
  # the composition figures' rule - folding per year would let a class enter and
  # leave the legend between points on its own line
  # Emissions join the test now that they are a plotted measure: a class that is
  # a rounding error in both hull count and ping volume can still burn enough
  # fuel to be worth its own line in panel C, and folding it on the other two
  # measures alone would hide that.
  small <- by_class |>
    dplyr::group_by(.data$year) |>
    dplyr::mutate(
      share_vessels = .data$n_unique_vessels / sum(.data$n_unique_vessels),
      share_pings = .data$n_pings / sum(.data$n_pings),
      share_emissions = .data$emissions_co2_mt / sum(.data$emissions_co2_mt)
    ) |>
    dplyr::ungroup() |>
    dplyr::group_by(.data$vessel_class) |>
    dplyr::summarise(
      small = all(
        .data$share_vessels < min_share &
          .data$share_pings < min_share &
          .data$share_emissions < min_share
      ),
      .groups = "drop"
    )

  folded <- by_class |>
    dplyr::left_join(small, by = "vessel_class") |>
    dplyr::mutate(
      vessel_class = ifelse(
        .data$vessel_class %in% grouped_as_other,
        "Other",
        .data$vessel_class
      ),
      vessel_class = ifelse(
        .data$small & .data$vessel_class != "Other",
        "Other",
        .data$vessel_class
      )
    ) |>
    dplyr::group_by(.data$vessel_class, .data$year) |>
    dplyr::summarise(
      n_unique_vessels = sum(.data$n_unique_vessels),
      n_pings = sum(.data$n_pings),
      emissions_co2_mt = sum(.data$emissions_co2_mt),
      .groups = "drop"
    )

  baseline <- folded |>
    dplyr::filter(.data$year == baseline_year) |>
    dplyr::select(
      vessel_class,
      vessels_baseline = "n_unique_vessels",
      pings_baseline = "n_pings",
      emissions_baseline = "emissions_co2_mt"
    )

  folded |>
    # inner_join drops any class with no baseline-year row, which would have no
    # growth to report
    dplyr::inner_join(baseline, by = "vessel_class") |>
    dplyr::mutate(
      baseline_year = baseline_year,
      vessels_change = .data$n_unique_vessels / .data$vessels_baseline - 1,
      pings_change = .data$n_pings / .data$pings_baseline - 1,
      # NA rather than Inf if a class emitted nothing in the baseline year: a
      # divide-by-zero would otherwise plot as an off-scale spike and drag the
      # whole panel's y-axis with it.
      emissions_change = ifelse(
        .data$emissions_baseline > 0,
        .data$emissions_co2_mt / .data$emissions_baseline - 1,
        NA_real_
      )
    ) |>
    dplyr::arrange(.data$vessel_class, .data$year)
}

# Sentinel-1 detection diagnostics ----
#
# The figures below come from a set of one-off BigQuery pulls over the S1
# detection table rather than from any target in 01_gfw_data_pull. Their query
# outputs are committed as data/gfw/s1_*.csv and the queries themselves as
# sql/s1_*.sql, so the figures redraw from the repo without touching BigQuery.
#
# They are not wired as tar_file_read() extracts on purpose: each query scans
# between 2.5 and 4.6 GB, the results are small and settled, and re-pulling them
# would cost money to reproduce numbers that have not changed. The SQL is kept
# beside the CSVs so the pull can be repeated deliberately if the underlying
# table is ever reprocessed.
#
# Panels are combined with cowplot rather than patchwork - patchwork is not in
# renv.lock, and cowplot::plot_grid() is already used elsewhere in this file.

# Inventory intensity across models ----
#
# CO2 per vessel for every inventory in the comparison, as one number per model
# rather than a series. This is the table behind the intensity sentence in
# inventories_comparison.md.
#
# Why the rows are built three different ways: the models differ in what fleet
# count they publish, so a single rule would either drop models or compare
# mismatched spans.
#
#   * Single-total models (STEAM, SEIM, MariTEAM) publish one fleet figure and
#     no per-year series, so the transcribed published total is used as-is.
#
#   * Per-year models (ICCT, IMO, OECD) publish a count for each year. The mean
#     is taken over the years where BOTH a count and emissions exist, rather
#     than over the publication's full span. This matters: IMO's vessel count
#     runs 2012-2018 while its emissions cover 2015-2018 only, and the three
#     extra years are its smallest fleets, so averaging over the whole count
#     span inflates the intensity (5.50 kt/vessel against 4.92 on matched
#     years).
#
#   * GFW rows are computed from our own activity summary, on the same
#     mean-per-year basis.
#
# Two supplementary rows make specific comparisons possible:
#
#   * "ICCT (distance-reporting classes)" restricts ICCT to the classes that
#     report distance. ICCT's Unknown class reports CO2 but no distance, so it
#     belongs to neither the numerator nor the denominator of a per-distance
#     intensity; without this restriction the kg/nm comparison is not like for
#     like.
#
#   * "GFW (AIS, any registry)" restricts our fleet to registry-matched
#     vessels, the closest analogue to the registry-anchored fleets the other
#     inventories model, and the fair row to read against them.
#
# The single-total fleet figures are transcribed from the "Number of vessels"
# row of Table 2 of the model comparison table; they are reported figures from
# each publication, not values we derive.
build_inventory_intensity <- function(
  inventory_data,
  vessel_counts_file,
  icct_comparison_file,
  gfw_activity_file,
  file_path
) {
  emissions <- inventory_data
  icct_comparison <- readr::read_csv(
    icct_comparison_file,
    show_col_types = FALSE
  )
  vessel_counts <- readr::read_csv(vessel_counts_file, show_col_types = FALSE) |>
    tidyr::pivot_longer(
      -"year",
      names_to = "data_source",
      values_to = "vessels"
    ) |>
    dplyr::filter(!is.na(.data$vessels))

  # Models publishing a per-year count: mean over matched years
  matched_rows <- c("ICCT", "IMO", "OECD") |>
    lapply(function(source_name) {
      d <- dplyr::inner_join(
        emissions |> dplyr::filter(.data$data_source == source_name),
        vessel_counts |> dplyr::filter(.data$data_source == source_name),
        by = c("data_source", "year")
      )
      tibble::tibble(
        data_source = source_name,
        n_total = round(mean(d$vessels)),
        count_basis = "mean per year (matched)",
        year_from = min(d$year),
        year_to = max(d$year),
        kg_nm = NA_real_,
        mean_mt = mean(d$emissions_co2_mt)
      )
    }) |>
    dplyr::bind_rows()

  # ICCT restricted to its distance-reporting classes
  icct_distance_row <- tibble::tibble(
    data_source = "ICCT (distance-reporting classes)",
    n_total = round(mean(icct_comparison$icct_n_vessels_with_distance)),
    count_basis = "mean per year (matched)",
    year_from = min(icct_comparison$year),
    year_to = max(icct_comparison$year),
    kg_nm = round(mean(icct_comparison$icct_intensity_kg_nm), 1),
    mean_mt = mean(icct_comparison$icct_co2_mt_with_distance)
  )

  # Our own fleet, whole and registry-matched.
  #
  # n_unique_vessels is counted within each (class, registry, length bin) group,
  # so summing it over a year can double-count a vessel whose class changed
  # mid-year. Length is a per-vessel attribute, so the length dimension added to
  # this extract introduces no further duplication.
  activity <- readr::read_csv(gfw_activity_file, show_col_types = FALSE) |>
    dplyr::mutate(year = as.integer(.data$year))

  gfw_row <- function(d, label) {
    tibble::tibble(
      data_source = label,
      n_total = round(mean(d$vessels)),
      count_basis = "mean per year (matched)",
      year_from = min(d$year),
      year_to = max(d$year),
      kg_nm = round(mean(d$emissions_mt) * 1000 / mean(d$distance_nm), 1),
      mean_mt = mean(d$emissions_mt)
    )
  }

  summarise_activity <- function(d) {
    d |>
      dplyr::group_by(.data$year) |>
      dplyr::summarise(
        emissions_mt = sum(.data$emissions_co2_mt),
        vessels = sum(.data$n_unique_vessels),
        distance_nm = sum(.data$distance_travelled_nm),
        .groups = "drop"
      )
  }

  gfw_all <- summarise_activity(activity)
  gfw_registered <- summarise_activity(
    activity |> dplyr::filter(.data$registry_type != "no_registry")
  )

  # Models publishing a single fleet total
  single_total_rows <- tibble::tribble(
    ~data_source, ~n_total, ~count_basis, ~year_from, ~year_to, ~kg_nm,
    "CAMS-GLOB-SHIP (STEAM)", 376219L, "2015 only", 2015L, 2015L, NA_real_,
    "SEIM", 109300L, "reported total", 2016L, 2021L, NA_real_,
    "MariTEAM", 45891L, "2017 only", 2017L, 2017L, NA_real_
  ) |>
    dplyr::rowwise() |>
    dplyr::mutate(
      mean_mt = mean(
        emissions$emissions_co2_mt[
          emissions$data_source == .data$data_source &
            emissions$year >= .data$year_from &
            emissions$year <= .data$year_to
        ]
      )
    ) |>
    dplyr::ungroup()

  intensity_table <- dplyr::bind_rows(
    single_total_rows,
    matched_rows,
    icct_distance_row,
    gfw_row(gfw_all, "GFW (AIS)"),
    gfw_row(gfw_registered, "GFW (AIS, any registry)")
  ) |>
    dplyr::mutate(
      period = paste0(.data$year_from, "-", .data$year_to),
      intensity_kt_per_vessel = round(.data$mean_mt / 1e3 / .data$n_total, 2),
      intensity_kg_per_nm = .data$kg_nm,
      mean_mt = round(.data$mean_mt / 1e6, 1),
      # Name the model, not the product delivering it, matching the labels the
      # comparison figures use. Renamed here rather than in the tribble above
      # because the stored data_source is the key the emissions lookup joins on.
      data_source = dplyr::recode(
        .data$data_source,
        "CAMS-GLOB-SHIP (STEAM)" = "STEAM"
      )
    ) |>
    dplyr::select(
      "data_source",
      "period",
      "count_basis",
      "n_total",
      "mean_mt",
      "intensity_kt_per_vessel",
      "intensity_kg_per_nm"
    ) |>
    dplyr::arrange(dplyr::desc(.data$intensity_kt_per_vessel))

  write_inventory_csv(intensity_table, file_path)
}
