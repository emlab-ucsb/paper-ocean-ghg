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

# Normalize each inventory to its value in baseline_year, so panel B compares
# trends rather than levels.
#
# Every series has to share one baseline year for the relative changes to be
# comparable - normalizing each series to its own first year would mean each
# curve starts from a different point in time. baseline_year defaults to 2017,
# the earliest year most inventories share, and any series without a value that
# year is dropped (OECD, which starts in 2019, and MariTEAM, which is a single
# point and has no trend to show).
normalize_inventory_series <- function(
  all_inventory_data,
  baseline_year = 2017L
) {
  baseline <- all_inventory_data |>
    dplyr::filter(year == baseline_year) |>
    dplyr::select(data_source, emissions_co2_mt_baseline = emissions_co2_mt)

  if (nrow(baseline) == 0) {
    stop(
      "No inventory has a value for baseline_year ",
      baseline_year,
      ", so there is nothing to normalize against."
    )
  }

  all_inventory_data |>
    # Years before the baseline would draw a line crossing the very point it is
    # normalized to, so the relative panels start at their own baseline even
    # when panel A reaches further back
    dplyr::filter(year >= baseline_year) |>
    # inner_join drops the series with no baseline-year value
    dplyr::inner_join(baseline, by = "data_source") |>
    dplyr::group_by(data_source) |>
    # A single point has no trend, so drop those series too
    dplyr::filter(dplyr::n_distinct(year) > 1) |>
    dplyr::ungroup() |>
    dplyr::mutate(
      emissions_co2_mt_normalized = emissions_co2_mt /
        emissions_co2_mt_baseline -
        1
    )
}

# Panel B: relative change from the baseline year, following panel B of Figure 4
# in the notebook - zero line, percent axis, and each line labelled at its own
# last year with its absolute value.
plot_inventory_relative_change <- function(
  all_inventory_data,
  baseline_year = 2017L,
  source_order
) {
  normalized <- normalize_inventory_series(
    all_inventory_data,
    baseline_year = baseline_year
  )

  included_sources <- intersect(source_order, unique(normalized$data_source))

  plot_data <- normalized |>
    dplyr::mutate(
      data_source = factor(data_source, levels = included_sources)
    )

  ggplot2::ggplot(plot_data) +
    ggplot2::geom_hline(yintercept = 0, linetype = 2) +
    ggplot2::geom_line(
      ggplot2::aes(
        x = year,
        y = emissions_co2_mt_normalized,
        color = data_source,
        linetype = data_source
      ),
      linewidth = 1.1
    ) +
    ggplot2::scale_x_continuous(
      breaks = sort(unique(plot_data$year))
    ) +
    ggplot2::scale_y_continuous(labels = scales::percent) +
    ggplot2::scale_color_manual(
      name = "Emissions inventory",
      values = inventory_color_palette(included_sources)
    ) +
    ggplot2::scale_linetype_manual(
      values = inventory_linetypes(included_sources),
      guide = "none"
    ) +
    ggplot2::labs(
      x = "",
      y = bquote(atop(
        Relative ~ change ~ of,
        CO[2] ~ emissions ~ from ~ .(baseline_year) ~ baseline
      ))
    ) +
    ggplot2::theme_minimal() +
    ggplot2::theme(
      axis.title.y = ggplot2::element_text(
        angle = 90,
        face = "bold",
        vjust = 3,
        size = 12
      ),
      panel.grid.minor = ggplot2::element_blank(),
      legend.position = "none"
    )
}

# Panel A: absolute annual CO2 by inventory. Series with a single year
# (MariTEAM) would be invisible as a line, so all series get points and only
# multi-year ones get a connecting line.
plot_inventory_levels <- function(
  all_inventory_data,
  source_order
) {
  # Round the axis up to the next 0.25 Gt, as the notebook figure does
  axis_max <- ceiling(max(all_inventory_data$emissions_co2_mt) / 0.25e9) *
    0.25e9

  plot_data <- all_inventory_data |>
    dplyr::mutate(data_source = factor(data_source, levels = source_order)) |>
    dplyr::group_by(data_source) |>
    dplyr::mutate(n_years = dplyr::n_distinct(year)) |>
    dplyr::ungroup()

  inventory_plot <- ggplot2::ggplot(
    plot_data,
    ggplot2::aes(x = year, y = emissions_co2_mt, color = data_source)
  ) +
    ggplot2::geom_line(
      data = plot_data |> dplyr::filter(n_years > 1),
      ggplot2::aes(linetype = data_source),
      linewidth = 1
    ) +
    ggplot2::geom_point(size = 1.8) +
    # The linetype guide is suppressed rather than merged with the color guide.
    # geom_line only draws the multi-year series, so its levels never match the
    # color scale's (MariTEAM is a lone point), and two guides that differ cannot
    # merge - the figure would carry two "Emissions inventory" legends. Instead
    # the color guide is the single key, with the dashed entry drawn in below.
    ggplot2::scale_linetype_manual(
      values = inventory_linetypes(source_order),
      guide = "none"
    ) +
    ggplot2::guides(
      color = ggplot2::guide_legend(
        override.aes = list(linetype = inventory_linetypes(source_order))
      )
    ) +
    ggplot2::scale_y_continuous(
      labels = scales::unit_format(unit = "B", scale = 1e-9),
      limits = c(0, axis_max),
      breaks = seq(0, axis_max, 0.25e9)
    ) +
    ggplot2::scale_x_continuous(
      breaks = sort(unique(plot_data$year))
    ) +
    ggplot2::scale_color_manual(
      name = "Emissions inventory",
      values = inventory_color_palette(source_order)
    ) +
    ggplot2::labs(
      x = "",
      y = expression(Annual ~ CO[2] ~ emissions ~ (MT))
    ) +
    ggplot2::theme_minimal() +
    ggplot2::theme(
      axis.title.y = ggplot2::element_text(
        angle = 90,
        face = "bold",
        vjust = 3,
        size = 12
      ),
      panel.grid.minor = ggplot2::element_blank(),
      # Legend outside to the right, as in Figure S4 in the notebook
      legend.position = "right",
      legend.key.height = ggplot2::unit(0.9, "lines")
    )

  inventory_plot
}

# The two-panel inventory comparison: (A) absolute annual CO2 for every
# inventory, (B) relative change from baseline_year for the series that can show
# a trend from it. Both panels share one color per inventory and one legend
# ordering, so a reader can carry a color between them; only panel A draws the
# key, since panel B is a subset of the same sources.
plot_inventory_comparison <- function(
  all_inventory_data,
  baseline_year = 2017L,
  late_baseline_year = 2019L,
  start_year = 2015L,
  exclude_sources = "EDGAR",
  file_path = NULL,
  width = 9,
  height = 14
) {
  # Series dropped from every panel of this figure. EDGAR is left to the
  # notebook figures that focus on it, so it does not earn a line here. Kept as
  # an argument rather than filtered upstream so the series stays in
  # all_inventory_data for the other figures and tables that use it.
  all_inventory_data <- all_inventory_data |>
    dplyr::filter(!.data$data_source %in% exclude_sources)

  # start_year is 2015 so the inventories that reach back that far are drawn
  # over their full published extent. It is deliberately earlier than the panel
  # B baseline: those panels normalize to baseline_year and filter to it
  # themselves, so the pre-baseline years show up only in panel A, where levels
  # are comparable without a shared starting point.
  all_inventory_data <- all_inventory_data |>
    dplyr::filter(year >= start_year) |>
    # Shorten labels for the legend only. The stored data keeps the full name
    # (which records the CAMS product serving the model), and renaming here
    # rather than in the summarizer avoids invalidating the download targets.
    dplyr::mutate(
      data_source = dplyr::recode(
        data_source,
        "CAMS-GLOB-SHIP (STEAM)" = "STEAM"
      )
    )

  # Order the legend by each inventory's most recent magnitude, so the key reads
  # top-to-bottom in the same order the lines appear on the right of panel A
  source_order <- all_inventory_data |>
    dplyr::group_by(data_source) |>
    dplyr::filter(year == max(year)) |>
    dplyr::summarise(
      emissions_co2_mt = max(emissions_co2_mt),
      .groups = "drop"
    ) |>
    dplyr::arrange(dplyr::desc(emissions_co2_mt)) |>
    dplyr::pull(data_source)

  panel_a <- plot_inventory_levels(
    all_inventory_data,
    source_order = source_order
  )
  panel_b <- plot_inventory_relative_change(
    all_inventory_data,
    baseline_year = baseline_year,
    source_order = source_order
  )
  # Panel C rebaselines to a later year so OECD, whose series starts in 2019, can
  # be included - at the cost of dropping the pre-2019 years and any series that
  # ends before then (IMO). Drop the earlier years first, so the panel starts at
  # its own baseline rather than showing lines that pre-date it.
  panel_c <- plot_inventory_relative_change(
    all_inventory_data |> dplyr::filter(year >= late_baseline_year),
    baseline_year = late_baseline_year,
    source_order = source_order
  )

  # Panel A carries the legend and the others do not, so their plotting areas
  # would be different widths and the x-axes would not line up. align = "v"
  # with axis = "lr" pads the other panels out to match. Panel C still spans a
  # shorter range of years, so only its left edge aligns.
  #
  # plot_grid also assembles onto a transparent canvas, so set an explicit white
  # background - otherwise the saved PNG has no background at all
  inventory_plot <- cowplot::plot_grid(
    panel_a,
    panel_b,
    panel_c,
    ncol = 1,
    labels = c("A", "B", "C"),
    align = "v",
    axis = "lr"
  ) +
    ggplot2::theme(
      plot.background = ggplot2::element_rect(fill = "white", color = NA)
    )

  if (!is.null(file_path)) {
    dir.create(dirname(file_path), showWarnings = FALSE, recursive = TRUE)
    ggplot2::ggsave(
      file_path,
      inventory_plot,
      width = width,
      height = height,
      dpi = 300
    )
    return(file_path)
  }

  inventory_plot
}

# Colours for figures that draw the registry fragments without the published
# inventories beside them.
#
# inventory_color_palette() puts the fragments on one light blue ramp on
# purpose: drawn among the inventories they have to read as parts of our own
# series rather than as estimates of their own, and the ramp is what does that.
# On a figure that is only fragments there is nothing to distinguish them from,
# and the ramp becomes a liability - near-identical light blues, one of which
# runs below zero.
#
# So these figures separate the fragments by hue instead. The no-registry line
# keeps a warm hue because it is the subject of the argument, the registered
# half takes a dark blue, and the total stays the GFW orange it carries
# everywhere else.
registry_fragment_colors <- function(data_sources) {
  known <- c(
    "GFW (AIS)" = "#E69F00",
    "GFW (AIS, no registry)" = "#CC3311",
    "GFW (AIS, registry)" = "#004488",
    # A size cut rather than a registry cut, so it takes a hue outside the
    # red/blue pair the registry halves use.
    "GFW (AIS, ≥150 m)" = "#56B4E9",
    "ICCT" = "#CC79A7",
    "IMO" = "#009E73",
    "OECD" = "#D55E00"
  )
  missing <- setdiff(data_sources, names(known))
  if (length(missing) > 0) {
    stop(
      "No color assigned for series: ",
      paste(missing, collapse = ", "),
      ". Add it to registry_fragment_colors()."
    )
  }

  known[data_sources]
}

# The registry split on its own, in relative terms, with no published inventory
# drawn beside it.
#
# The full comparison figure has to hold the published inventories and the
# registry fragments on one pair of axes, and they do not sit together in
# relative terms: the no-registry fragment reaches roughly +295 % from 2017
# while no inventory exceeds +45 %, so the axis needed for one flattens the
# other. This version drops the inventories entirely and keeps only our own
# series, which is what makes the divergence between the halves legible - the
# whole vertical range is theirs.
#
# What it is for: the fleet-scope argument needs the registered and unregistered
# parts of our own total to be seen growing at different rates from a common
# baseline. Registered emissions fall over the series while unregistered ones
# multiply, so the total's growth is entirely the unregistered half's doing. In
# absolute terms that is registry_sankey_with_series_2025.png panel C; this is
# the same fact as a rate.
#
# Levels are carried by the end-of-line labels rather than the axis. Every line
# starts at 0 % by construction, so the axis alone says nothing about how large
# each fragment is; the label at each line's right-hand end gives its final
# absolute value beside its percent change, which is what lets a +295 % fragment
# be read against the much larger half it is growing away from.
#
# A third cut is drawn beside the two registry halves: vessels at or above 150 m.
# The registry split says which part of our total the other inventories were ever
# in a position to enumerate. The size cut says which part of it is immune to our
# own observation expanding - carriage there was already settled in 2017 and the
# unmatched share of S1 detections has barely moved since, so that fragment's
# growth cannot be vessels entering the record by beginning to broadcast. Two
# different questions about the same line, and the growth argument needs both.
plot_registry_split_relative <- function(
  registry_series = NULL,
  gfw_activity_file = file.path(
    "data",
    "gfw",
    "annual_ais_activity_summary_cheap.csv"
  ),
  baseline_year = 2017L,
  # Includes the GFW (AIS) total so the halves can be read against the line they
  # partition rather than only against each other.
  include_total = TRUE,
  # The length bins that make up the size-restricted fragment. Named by the
  # labels used in annual_ais_activity_summary_cheap.csv.
  large_bins = c("150-175m", "175-200m", "200-225m", "225m+"),
  large_label = "GFW (AIS, ≥150 m)",
  file_path = NULL,
  width = 10,
  height = 6
) {
  if (is.null(registry_series)) {
    registry_series <- gfw_registry_series(
      gfw_activity_file = gfw_activity_file
    )
  }

  # One registered line rather than a per-register breakdown. What bounds a
  # registry-derived inventory is whether a vessel is registered anywhere at all,
  # not which register holds it, so IMO and other-register vessels are read
  # together here and the figure carries two halves and their total.
  #
  # gfw_registry_series() already sums the two into "any registry", so take that
  # row and drop the per-register fragments rather than re-summing them - adding
  # the fragments to a total that contains them would double the registered half.
  #
  # Done here rather than in gfw_registry_series() so the other consumer of that
  # series, the inventory-comparison figure, keeps the breakdown it draws.
  series <- registry_series |>
    dplyr::select(dplyr::all_of(c("data_source", "year", "emissions_co2_mt"))) |>
    dplyr::filter(
      .data$data_source %in%
        c("GFW (AIS, any registry)", "GFW (AIS, no registry)")
    ) |>
    dplyr::mutate(
      year = as.integer(.data$year),
      data_source = ifelse(
        .data$data_source == "GFW (AIS, any registry)",
        "GFW (AIS, registry)",
        .data$data_source
      )
    )

  if (include_total) {
    # The split partitions the total and the two halves do not overlap, so
    # summing them reconstructs it exactly.
    total <- series |>
      dplyr::group_by(.data$year) |>
      dplyr::summarise(
        emissions_co2_mt = sum(.data$emissions_co2_mt, na.rm = TRUE),
        .groups = "drop"
      ) |>
      dplyr::mutate(data_source = "GFW (AIS)")
    series <- dplyr::bind_rows(series, total)
  }

  # Added after the total is computed, not before: the total is the sum of the
  # two registry halves, and this fragment overlaps both, so folding it in
  # earlier would double-count it.
  #
  # All vessel classes, not non-fishing only. Fishing vessels are 0.1 % of
  # emissions at these lengths (0.45 of 511 Mt in 2017), so restricting the cut
  # would change the series by less than the rounding on its label while making
  # it differ from the other three in two ways instead of one.
  large_series <- readr::read_csv(gfw_activity_file, show_col_types = FALSE) |>
    dplyr::filter(.data$length_bin %in% large_bins) |>
    dplyr::group_by(year = as.integer(.data$year)) |>
    dplyr::summarise(
      emissions_co2_mt = sum(.data$emissions_co2_mt, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::mutate(data_source = large_label)
  series <- dplyr::bind_rows(series, large_series)

  relative <- series |>
    dplyr::filter(.data$year >= baseline_year) |>
    dplyr::group_by(.data$data_source) |>
    dplyr::arrange(.data$year, .by_group = TRUE) |>
    dplyr::mutate(
      baseline = .data$emissions_co2_mt[.data$year == baseline_year][1],
      relative_change = .data$emissions_co2_mt / .data$baseline - 1
    ) |>
    dplyr::ungroup() |>
    dplyr::filter(!is.na(.data$relative_change))

  # Ordered from the half that grows most to the one that grows least, so the
  # legend reads down the figure in the same order the lines end.
  source_levels <- c(
    "GFW (AIS, no registry)",
    "GFW (AIS)",
    large_label,
    "GFW (AIS, registry)"
  )
  relative <- relative |>
    dplyr::mutate(
      data_source = factor(
        .data$data_source,
        levels = intersect(source_levels, unique(.data$data_source))
      )
    )

  present <- levels(relative$data_source)

  # Percent change and the absolute level it ends at, so the figure carries
  # magnitude as well as rate.
  end_labels <- relative |>
    dplyr::group_by(.data$data_source) |>
    dplyr::filter(.data$year == max(.data$year)) |>
    dplyr::ungroup() |>
    dplyr::mutate(
      label = sprintf(
        "%+.0f%%  (%s Mt)",
        100 * .data$relative_change,
        formatC(
          round(.data$emissions_co2_mt / 1e6),
          format = "d",
          big.mark = ","
        )
      )
    )

  # The AIS total and the size-restricted fragment end within a few percentage
  # points of each other, so label positions are walked apart from the lowest up
  # until each clears the one below by a minimum gap in axis units. Only the text
  # moves; the lines and points stay where the data put them.
  label_gap <- 0.06 * diff(range(relative$relative_change))
  label_order <- order(end_labels$relative_change)
  stacked <- end_labels$relative_change[label_order]
  for (i in seq_along(stacked)[-1]) {
    if (stacked[i] - stacked[i - 1] < label_gap) {
      stacked[i] <- stacked[i - 1] + label_gap
    }
  }
  end_labels$label_y <- NA_real_
  end_labels$label_y[label_order] <- stacked

  relative_plot <- ggplot2::ggplot(
    relative,
    ggplot2::aes(
      x = .data$year,
      y = .data$relative_change,
      color = .data$data_source,
      linetype = .data$data_source
    )
  ) +
    ggplot2::geom_hline(yintercept = 0, linetype = "dashed", color = "grey40") +
    ggplot2::geom_line(linewidth = 1) +
    ggplot2::geom_point(size = 1.8) +
    ggplot2::geom_text(
      data = end_labels,
      ggplot2::aes(
        x = .data$year + 0.12,
        y = .data$label_y,
        label = .data$label,
        color = .data$data_source
      ),
      hjust = 0,
      size = 3.1,
      fontface = "bold",
      show.legend = FALSE,
      inherit.aes = FALSE
    ) +
    ggplot2::scale_color_manual(values = registry_fragment_colors(present)) +
    ggplot2::scale_linetype_manual(values = inventory_linetypes(present)) +
    ggplot2::scale_x_continuous(
      breaks = sort(unique(relative$year)),
      # Right-hand room for the end labels.
      expand = ggplot2::expansion(mult = c(0.02, 0.20))
    ) +
    ggplot2::scale_y_continuous(labels = scales::percent) +
    ggplot2::labs(
      x = "",
      y = paste0(
        "Relative change of\nCO2 emissions from ",
        baseline_year,
        " baseline"
      ),
      color = "",
      linetype = ""
    ) +
    ggplot2::theme_minimal() +
    ggplot2::theme(
      axis.title.y = ggplot2::element_text(
        angle = 90,
        face = "bold",
        vjust = 3,
        size = 11
      ),
      panel.grid.minor = ggplot2::element_blank(),
      legend.position = "right"
    ) +
    ggplot2::theme(
      plot.background = ggplot2::element_rect(fill = "white", color = NA)
    )

  if (!is.null(file_path)) {
    dir.create(dirname(file_path), showWarnings = FALSE, recursive = TRUE)
    ggplot2::ggsave(
      file_path,
      relative_plot,
      width = width,
      height = height,
      dpi = 300,
      bg = "white"
    )
    return(file_path)
  }

  relative_plot
}

# Colors for the inventory comparison. The four sources already in the notebook
# figure keep their Okabe-Ito colors from all_data_source_color_palette so the
# two figures stay readable side by side; the inventories added by this pipeline
# take the remaining Okabe-Ito hues.
# Line style per inventory. Every published inventory is solid; only the
# registry fragments below are dashed.
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

# The fishing classes collapsed into a single "Fishing" slice. Kept in one place
# because the notebook hardcodes the same list when it facets figure 3.
gfw_fishing_vessel_classes <- function() {
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

# Turn a raw GFW vessel_class into the label used on the pies, folding every
# fishing gear type into one slice.
gfw_vessel_class_label <- function(vessel_class) {
  ifelse(
    vessel_class %in% gfw_fishing_vessel_classes(),
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

# Fold the activity extract's raw vessel classes into the display list the fleet
# figures use, on whatever measures are asked for.
#
# The rules live here rather than inside the calling figure so that any figure
# drawing per-class series gets the same class list: the reefer sub-classes
# collapse to one, a named set of small non-fishing classes collapse to "Other",
# and anything below min_share on every measure in every year joins them. Folding
# is decided across all years at once, so a class cannot enter and leave the
# legend between points on its own line.
#
# measures are summed within each class-year. Pass the columns the caller needs;
# they must all be present in the extract.
#
# keep_classes overrides the smallness test with an explicit list of display
# classes to keep, anything else folding into the catch-all. It exists for
# callers that split the fleet a second way and need every part to use one class
# list: judged independently, a class can clear the threshold in one part and
# not another, and the parts would stop summing to the whole. The reefer and
# named-group folding still applies, so the list is compared against labels that
# have already been through it.
fold_gfw_vessel_classes <- function(
  activity_data,
  measures = c("emissions_co2_mt", "n_pings"),
  keep_classes = NULL,
  min_share = 0.005,
  grouped_as_reefer = c(
    "Specialized reefer",
    "Container reefer",
    "Cargo: refrigerated"
  ),
  reefer_label = "Reefer",
  grouped_as_other = c(
    "Supply vessel",
    "Patrol vessel",
    "Bunker",
    "Dredge non fishing",
    "Other not fishing"
  )
) {
  missing <- setdiff(measures, names(activity_data))
  if (length(missing) > 0) {
    stop(
      "The activity extract has no column: ",
      paste(missing, collapse = ", ")
    )
  }

  by_class <- activity_data |>
    dplyr::mutate(
      vessel_class = gfw_vessel_class_label(.data$vessel_class),
      # Left alone when it is not already numeric: callers that split the fleet
      # on something other than time pass that grouping in as `year`, and
      # coercing it would turn those labels into NA
      year = if (is.numeric(.data$year)) {
        as.integer(.data$year)
      } else {
        .data$year
      }
    ) |>
    dplyr::group_by(.data$vessel_class, .data$year) |>
    dplyr::summarise(
      dplyr::across(dplyr::all_of(measures), \(x) sum(x, na.rm = TRUE)),
      .groups = "drop"
    )

  # Small on every measure in every year, judged as a within-year share
  small <- by_class |>
    dplyr::group_by(.data$year) |>
    dplyr::mutate(
      dplyr::across(
        dplyr::all_of(measures),
        \(x) x / sum(x),
        .names = "share_{.col}"
      )
    ) |>
    dplyr::ungroup() |>
    dplyr::group_by(.data$vessel_class) |>
    dplyr::summarise(
      small = all(
        dplyr::if_all(dplyr::starts_with("share_"), \(x) x < min_share)
      ),
      .groups = "drop"
    )

  by_class |>
    dplyr::left_join(small, by = "vessel_class") |>
    dplyr::mutate(
      vessel_class = ifelse(
        .data$vessel_class %in% grouped_as_reefer,
        reefer_label,
        .data$vessel_class
      ),
      vessel_class = ifelse(
        .data$vessel_class %in% grouped_as_other,
        "Other",
        .data$vessel_class
      ),
      vessel_class = ifelse(
        # An explicit keep list replaces the smallness test entirely, so every
        # caller splitting the fleet a second way folds to the same classes
        if (is.null(keep_classes)) {
          .data$small
        } else {
          !.data$vessel_class %in% keep_classes
        } &
          !.data$vessel_class %in% c(reefer_label, "Other"),
        "Other",
        .data$vessel_class
      )
    ) |>
    dplyr::group_by(.data$vessel_class, .data$year) |>
    dplyr::summarise(
      dplyr::across(dplyr::all_of(measures), sum),
      .groups = "drop"
    )
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


# Perceived brightness of a colour, on the WCAG relative-luminance definition:
# sRGB channels linearised, then weighted for the eye's sensitivity to each.
# Used to decide whether a fill needs dark or light text over it. A plain mean
# of the RGB channels would call the palette's yellows and its blues equally
# bright, when the yellows are far lighter to look at.
relative_luminance <- function(colors) {
  channels <- grDevices::col2rgb(colors) / 255
  linear <- ifelse(
    channels <= 0.03928,
    channels / 12.92,
    ((channels + 0.055) / 1.055)^2.4
  )
  as.numeric(
    0.2126 * linear[1, ] + 0.7152 * linear[2, ] + 0.0722 * linear[3, ]
  )
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

# The single-year Sankey and the two year-series columns in one figure: the
# Sankey down the whole left side as panel A, and the fleet-size and CO2 series
# stacked on the right as B and C.
#
# B and C are one 100 % stacked column per year, fleet size and CO2, standalone
# rather than facing each other across a connector band: each carries its own
# percent axis, and stacking them vertically means only the lower one needs the
# year labels. A retired figure drew this pair on its own, facing across a band;
# this is now the only place the year series is drawn.
plot_fleet_sankey_with_series <- function(
  fleet_data,
  file_path = NULL,
  year = 2025L,
  min_share = 0.005,
  min_label_share = 0.04,
  grouped_as_reefer = c(
    "Specialized reefer",
    "Container reefer",
    "Cargo: refrigerated"
  ),
  reefer_label = "Reefer",
  grouped_as_other = c(
    "Supply vessel",
    "Patrol vessel",
    "Bunker",
    "Dredge non fishing",
    "Other not fishing"
  ),
  light_fill_luminance = 0.62,
  width = 13,
  height = 9.5,
  bar_width = 0.92,
  # The Sankey's share of the figure width. Panel A is the tall narrow element
  # here, so it takes less width than the stacked pair beside it.
  rel_width_sankey = 0.62,
  # Blank space above and below panel A, as a fraction of its own height, so its
  # diagram starts level with the top of B's columns and ends level with the foot
  # of C's. Solved against the rendered PNG rather than derived: the levels being
  # matched are set by ggplot's own text layout, so there is no closed form for
  # them short of rendering. Panel A carries its own headings in the small
  # y-expansion it keeps, which is why almost none of the allowance is at the
  # top; the bottom clears C's year labels.
  pad_top = 0,
  pad_bottom = 0.024
) {
  small <- fleet_data |>
    dplyr::group_by(vessel_class) |>
    dplyr::summarise(
      small = max(.data$share_emissions) < min_share &
        max(.data$share_vessels) < min_share,
      .groups = "drop"
    )

  # As in the year-series figure: the ramp is spread over the class list before
  # the support classes are folded away, so every class keeps the colour it has
  # in the other figures.
  palette_levels <- fleet_data |>
    dplyr::left_join(small, by = "vessel_class") |>
    dplyr::mutate(
      vessel_class = ifelse(
        .data$vessel_class %in% grouped_as_reefer,
        reefer_label,
        .data$vessel_class
      ),
      vessel_class = ifelse(
        .data$small & .data$vessel_class != reefer_label,
        "Other",
        .data$vessel_class
      )
    ) |>
    dplyr::group_by(vessel_class, .data$year) |>
    dplyr::summarise(
      emissions_co2_mt = sum(.data$emissions_co2_mt),
      n_unique_vessels = sum(.data$n_unique_vessels),
      .groups = "drop"
    ) |>
    stacked_class_levels()

  full_palette <- grDevices::colorRampPalette(
    RColorBrewer::brewer.pal(11, "Spectral")
  )(length(palette_levels))
  names(full_palette) <- palette_levels

  series_data <- fleet_data |>
    dplyr::left_join(small, by = "vessel_class") |>
    dplyr::mutate(
      # Reefers go into the catch-all rather than standing as their own group,
      # matching panel A. Every reefer spelling is below the size threshold, so
      # separately they are slivers too thin to label or to pick out of the key.
      # The group still exists in palette_levels above, which is what keeps the
      # other classes on the colours they have in the year-series figures.
      vessel_class = ifelse(
        .data$vessel_class %in% c(grouped_as_reefer, grouped_as_other),
        "Other",
        .data$vessel_class
      ),
      vessel_class = ifelse(
        .data$small & .data$vessel_class != "Other",
        "Other",
        .data$vessel_class
      )
    ) |>
    dplyr::group_by(vessel_class, .data$year) |>
    dplyr::summarise(
      emissions_co2_mt = sum(.data$emissions_co2_mt),
      n_unique_vessels = sum(.data$n_unique_vessels),
      .groups = "drop"
    ) |>
    dplyr::group_by(.data$year) |>
    dplyr::mutate(
      share_emissions = .data$emissions_co2_mt / sum(.data$emissions_co2_mt),
      share_vessels = .data$n_unique_vessels / sum(.data$n_unique_vessels)
    ) |>
    dplyr::ungroup()

  class_levels <- stacked_class_levels(series_data)
  palette <- full_palette[class_levels]

  # `show_years` rather than `show_axis`: stacked one above the other, both
  # panels keep their percent axis and only the lower one needs the year labels,
  # which is the reverse of the side-by-side pair's sharing.
  series_panel <- function(share_col, total_col, total_fmt, title, show_years) {
    totals <- series_data |>
      dplyr::group_by(.data$year) |>
      dplyr::summarise(
        total = sum(.data[[total_col]], na.rm = TRUE),
        .groups = "drop"
      ) |>
      dplyr::mutate(label = total_fmt(.data$total))

    panel_data <- series_data |>
      dplyr::mutate(
        vessel_class = factor(.data$vessel_class, levels = class_levels),
        stack_order = forcats::fct_rev(.data$vessel_class),
        share = .data[[share_col]],
        label = ifelse(
          .data$share >= min_label_share,
          paste0(round(.data$share * 100), " %"),
          ""
        ),
        light_fill = relative_luminance(
          palette[as.character(.data$vessel_class)]
        ) >
          light_fill_luminance,
        label_color = ifelse(.data$light_fill, "grey45", "white"),
        label_face = ifelse(.data$light_fill, "plain", "bold"),
        label_size = ifelse(.data$light_fill, 2.6, 2.8)
      )

    ggplot2::ggplot(
      panel_data,
      ggplot2::aes(
        x = factor(.data$year),
        y = .data$share,
        fill = .data$vessel_class,
        group = .data$stack_order
      )
    ) +
      ggplot2::geom_col(width = bar_width, color = "white", linewidth = 0.25) +
      ggplot2::geom_text(
        ggplot2::aes(
          label = .data$label,
          color = .data$label_color,
          fontface = .data$label_face,
          size = .data$label_size
        ),
        position = ggplot2::position_stack(vjust = 0.5),
        show.legend = FALSE
      ) +
      ggplot2::scale_color_identity() +
      ggplot2::scale_size_identity() +
      ggplot2::geom_text(
        data = totals,
        ggplot2::aes(x = factor(.data$year), y = 1, label = .data$label),
        inherit.aes = FALSE,
        vjust = -0.6,
        size = 2.5,
        color = "grey25"
      ) +
      ggplot2::scale_fill_manual(values = palette, drop = FALSE, name = NULL) +
      ggplot2::scale_x_discrete(
        expand = ggplot2::expansion(add = 0.375)
      ) +
      # Axis on the right: these panels sit to the right of the Sankey, so their
      # scale reads on the figure's outer edge rather than in the gutter between
      # the two halves.
      ggplot2::scale_y_continuous(
        labels = scales::label_percent(),
        expand = ggplot2::expansion(mult = c(0, 0.08)),
        position = "right"
      ) +
      ggplot2::labs(x = NULL, y = NULL, title = title) +
      ggplot2::theme_minimal() +
      ggplot2::theme(
        plot.title = ggplot2::element_text(hjust = 0.5, size = 11),
        axis.text.x = if (show_years) {
          ggplot2::element_text(size = 8)
        } else {
          ggplot2::element_blank()
        },
        axis.text.y = ggplot2::element_text(size = 8),
        # Nothing sits to the left of the bars now that the scale has moved to
        # the right, so the default left margin is dead space between these
        # panels and the Sankey.
        plot.margin = ggplot2::margin(5.5, 5.5, 5.5, 0),
        panel.grid.major.x = ggplot2::element_blank(),
        panel.grid.minor = ggplot2::element_blank()
      )
  }

  size_panel <- series_panel(
    "share_vessels",
    "n_unique_vessels",
    scales::label_comma(accuracy = 1),
    "AIS-broadcasting fleet size",
    show_years = FALSE
  )
  emissions_panel <- series_panel(
    "share_emissions",
    "emissions_co2_mt",
    function(x) paste0(round(x / 1e6), " Mt"),
    expression("AIS-broadcasting" ~ CO[2] ~ "emissions"),
    show_years = TRUE
  )

  # A tighter margin than the standalone figure uses. Panel A is drawn into a
  # tall slot here, so the annotations keep their point size while the diagram
  # gets taller -- at the standalone 0.42 they would sit in a band of empty
  # space either side.
  #
  # The y-expansion is squeezed almost flat and the headings moved inside, so
  # the diagram itself reaches the top and bottom of whatever slot it is given.
  # That is what lets the padding below position its drawn edges: with the
  # standalone 12 % headroom in place, the diagram floats inside its slot by
  # more than the alignment needs to move it, and no amount of outer padding
  # can pull it back out.
  sankey <- plot_fleet_sankey(
    fleet_data,
    year = year,
    x_margin = 0.22,
    # Trimmed on the facing side, but not past what the heading needs: the
    # widest thing on this edge is "2025 CO2 emissions" centred on the node, not
    # the "(269 Mt)" value lines, and too small a value here cuts the heading off
    # mid-word rather than overflowing visibly. 0.17 is about the floor.
    x_margin_right = 0.17,
    # The heading is what sets the floor above, so shrinking it is what actually
    # buys space between the two halves -- the value labels below it are much
    # narrower and are nowhere near the edge.
    heading_size = 2.8,
    y_expand_lower = 0.005,
    y_expand_upper = 0.045,
    heading_inside = FALSE,
    plot_margin = ggplot2::margin(0, 0, 0, 10)
  )

  legend <- cowplot::get_plot_component(
    size_panel +
      ggplot2::guides(fill = ggplot2::guide_legend(nrow = 1, byrow = TRUE)) +
      ggplot2::theme(
        legend.position = "bottom",
        legend.text = ggplot2::element_text(size = 8)
      ),
    "guide-box-bottom",
    return_all = TRUE
  )

  # align = "v" so B and C share a plotting region width despite only C carrying
  # the year labels; without it the upper panel's columns would be wider than the
  # lower one's by exactly the height the axis text occupies.
  series_column <- cowplot::plot_grid(
    size_panel + ggplot2::theme(legend.position = "none"),
    emissions_panel + ggplot2::theme(legend.position = "none"),
    ncol = 1,
    align = "v",
    axis = "lr",
    rel_heights = c(1, 1.08),
    labels = c("B", "C")
  )

  # Panel A's drawn area is made to span exactly from C's baseline up to B's
  # ceiling, rather than filling the slot the way a bare plot would.
  #
  # Those two levels are not the outer edge of the column: B carries a title
  # above its bars and C a row of year labels below its own, so the columns
  # themselves start and stop some way inside the block. The Sankey is padded by
  # the same amounts -- title height at the top, axis-text height at the bottom
  # -- so its diagram lines up with the bars and not with the block's border.
  #
  # Expressed in null units against the panel heights so the padding tracks any
  # later change to rel_heights, instead of being an absolute size that would
  # have to be re-tuned whenever the figure is resized.
  sankey_padded <- cowplot::plot_grid(
    NULL,
    sankey,
    NULL,
    ncol = 1,
    rel_heights = c(pad_top, 1, pad_bottom)
  )

  panels <- cowplot::plot_grid(
    sankey_padded,
    series_column,
    nrow = 1,
    rel_widths = c(rel_width_sankey, 1),
    labels = c("A", "")
  )

  combined <- cowplot::plot_grid(
    panels,
    legend,
    ncol = 1,
    rel_heights = c(1, 0.07)
  ) +
    ggplot2::theme(
      plot.background = ggplot2::element_rect(fill = "white", color = NA)
    )

  if (!is.null(file_path)) {
    dir.create(dirname(file_path), showWarnings = FALSE, recursive = TRUE)
    ggplot2::ggsave(
      file_path,
      combined,
      width = width,
      height = height,
      dpi = 300,
      bg = "white"
    )
    return(file_path)
  }

  combined
}

# The Sankey-with-series figure drawn over registry status rather than vessel
# class: three groups instead of thirty-seven, answering how much of the fleet
# each register accounts for against how much of the CO2.
#
# A thin wrapper on plot_fleet_sankey_with_series(), which is generic over
# whatever grouping arrives in the vessel_class column. Only the defaults change:
#
#   * min_share = 0 and grouping lists emptied. Those defaults exist to fold
#     three dozen classes down to a legible dozen; with three groups there is
#     nothing to fold, and leaving them at their class values would sweep any
#     group under 0.5 % into an "Other" that should not exist here.
#   * min_label_share lowered, since every group is large enough to label and the
#     class-figure threshold would silently drop one.
#   * A shorter default height: three bands need far less vertical room than
#     thirty-seven, and at the class height the diagram stretches into a few
#     enormous slabs.
#
# Colours come from the same Spectral ramp the class figures use, spread over
# three levels rather than a dozen, so this figure reads as part of the same set
# without pretending its groups are the class groups.
plot_registry_sankey_with_series <- function(
  registry_data,
  file_path = NULL,
  year = 2025L,
  min_share = 0,
  min_label_share = 0.02,
  height = 6.5,
  ...
) {
  plot_fleet_sankey_with_series(
    registry_data,
    file_path = file_path,
    year = year,
    min_share = min_share,
    min_label_share = min_label_share,
    grouped_as_reefer = character(),
    reefer_label = NA_character_,
    grouped_as_other = character(),
    height = height,
    ...
  )
}


# A single year as a plain Sankey: one stacked node for the fleet, one for CO2,
# and a ribbon per class flowing between them. No axes and no legend -- each
# class is named once, on whichever side its band is thicker, and its share is
# printed outside the nodes on both sides.
#
# Shares the folding rules and the palette construction of the year-series
# figure so the two stay comparable, but nothing else: with one year there is no
# series to draw and the bars stop being charts, so this is written as a diagram
# rather than assembled from two panels and a connector.
plot_fleet_sankey <- function(
  fleet_data,
  file_path = NULL,
  year = 2025L,
  min_share = 0.005,
  # Kept as its own group only for the palette: the ramp has to be spread over
  # the same class list the year-series figures use, or the shared classes would
  # come out a different colour here. In the diagram itself reefers are part of
  # "Other" -- see the fold below.
  grouped_as_reefer = c(
    "Specialized reefer",
    "Container reefer",
    "Cargo: refrigerated"
  ),
  reefer_label = "Reefer",
  grouped_as_other = c(
    "Supply vessel",
    "Patrol vessel",
    "Bunker",
    "Dredge non fishing",
    "Other not fishing"
  ),
  # Shorter names for the diagram. The pipeline's vocabulary is prefixed by group
  # so the classes sort together, which is redundant once each is labelled.
  display_label = c(
    "Cargo: general" = "General cargo",
    "Cargo: bulk carrier" = "Bulk carrier",
    "Tanker: oil" = "Oil tanker",
    "Cargo: container" = "Container",
    "Tanker: chemical" = "Chemical",
    "Cargo: ro ro" = "Ro ro cargo",
    "Tanker: liquefied gas" = "Liquified gas"
  ),
  # Below this a band gets no printed share or name: the slab is thinner than
  # the text would be.
  min_label_share = 0.02,
  # Fills brighter than this take dark text; the same cutoff the year-series
  # figure uses, so a class is labelled the same way in both.
  light_fill_luminance = 0.62,
  node_width = 0.028,
  # Space outside the diagram, as a fraction of its 0-1 span, for the share
  # annotations. Wide enough for the longest of them -- "(232,497)", the value
  # line -- at the standalone width. These are fractions of the x-range, so a
  # narrower canvas buys the text less room rather than the same room, and too
  # small a value here silently clips the labels instead of overflowing
  # visibly. Settable per side so a caller butting this against another panel
  # can trim the facing margin: the emissions side needs less, its values being
  # "(269 Mt)" rather than a six-digit count.
  x_margin = 0.24,
  x_margin_right = x_margin,
  # Space above and below the diagram, as a fraction of its own height. The
  # upper allowance holds the column headings. A caller aligning this against
  # other panels can shrink both so the diagram reaches its slot's edges --
  # the headings then need somewhere else to go, which is what heading_inside
  # is for.
  y_expand_lower = 0.02,
  y_expand_upper = 0.12,
  # Headings drawn just inside the top of the diagram rather than above it, for
  # when the caller has squeezed the expansion out to align the plot area.
  heading_inside = FALSE,
  heading_size = 3.1,
  plot_margin = ggplot2::margin(10, 10, 10, 10),
  width = 6.5,
  height = 7.5
) {
  fleet_data <- dplyr::filter(fleet_data, .data$year == .env$year)
  if (nrow(fleet_data) == 0) {
    stop("no rows for year ", year, call. = FALSE)
  }

  small <- fleet_data |>
    dplyr::group_by(vessel_class) |>
    dplyr::summarise(
      small = max(.data$share_emissions) < min_share &
        max(.data$share_vessels) < min_share,
      .groups = "drop"
    )

  folded <- fleet_data |>
    dplyr::left_join(small, by = "vessel_class") |>
    dplyr::mutate(
      # Reefers are folded in with the rest of the catch-all here. Every reefer
      # spelling is below the size threshold anyway, so on its own it would be a
      # band too thin to label; the group only survives in the palette, where it
      # still occupies its slot on the ramp.
      vessel_class = ifelse(
        .data$vessel_class %in% c(grouped_as_reefer, grouped_as_other),
        "Other",
        .data$vessel_class
      ),
      vessel_class = ifelse(
        .data$small & .data$vessel_class != "Other",
        "Other",
        .data$vessel_class
      )
    ) |>
    dplyr::group_by(vessel_class) |>
    dplyr::summarise(
      emissions_co2_mt = sum(.data$emissions_co2_mt),
      n_unique_vessels = sum(.data$n_unique_vessels),
      .groups = "drop"
    ) |>
    dplyr::mutate(
      share_emissions = .data$emissions_co2_mt / sum(.data$emissions_co2_mt),
      share_vessels = .data$n_unique_vessels / sum(.data$n_unique_vessels)
    )

  # Column totals for the headings: the whole AIS-broadcasting fleet and its
  # whole CO2 output for this year, which the percentages below are shares of.
  total_vessels <- sum(folded$n_unique_vessels)
  total_co2 <- sum(folded$emissions_co2_mt)

  # Ordered by fleet size with the catch-all last, so the ramp runs top to
  # bottom in the same sequence on both nodes.
  trailing <- "Other"
  ordered <- folded |>
    dplyr::filter(!.data$vessel_class %in% trailing) |>
    dplyr::arrange(dplyr::desc(.data$n_unique_vessels)) |>
    dplyr::pull(.data$vessel_class)
  class_levels <- c(ordered, intersect(trailing, folded$vessel_class))

  # The ramp is spread over the class list as it stands BEFORE the support
  # classes are folded into "Other", then subset to the classes actually drawn.
  # Generating it over the folded list instead would spread the same Spectral
  # ramp across four fewer classes and hand every one of them a different
  # colour, so this diagram would not match the year-series figures.
  palette_levels <- fleet_data |>
    dplyr::left_join(small, by = "vessel_class") |>
    dplyr::mutate(
      vessel_class = ifelse(
        .data$vessel_class %in% grouped_as_reefer,
        reefer_label,
        .data$vessel_class
      ),
      vessel_class = ifelse(
        .data$small & .data$vessel_class != reefer_label,
        "Other",
        .data$vessel_class
      )
    ) |>
    dplyr::group_by(vessel_class, .data$year) |>
    dplyr::summarise(
      emissions_co2_mt = sum(.data$emissions_co2_mt),
      n_unique_vessels = sum(.data$n_unique_vessels),
      .groups = "drop"
    ) |>
    stacked_class_levels()

  full_palette <- grDevices::colorRampPalette(
    RColorBrewer::brewer.pal(11, "Spectral")
  )(length(palette_levels))
  names(full_palette) <- palette_levels

  palette <- full_palette[class_levels]

  # The end nodes take a darker shade of each class's colour, so they read as
  # solid anchors while the flows between them stay lighter. Mixing toward black
  # in RGB rather than reaching for a colour-space package keeps this
  # dependency-free; at this size the difference from a proper luminance
  # darkening is not visible.
  darken <- function(colors, amount) {
    rgb <- grDevices::col2rgb(colors) / 255
    grDevices::rgb(t((1 - amount) * rgb))
  }
  node_palette <- darken(palette, 0.38)
  names(node_palette) <- class_levels

  # Stacked extents per side, first level at the bottom and the catch-all on
  # top, so the diagram stacks in the same direction as the year-series figures:
  # Passenger against the axis, Other at the ceiling.
  extent <- function(share_col, value_col) {
    folded |>
      dplyr::mutate(
        vessel_class = factor(.data$vessel_class, levels = class_levels)
      ) |>
      dplyr::arrange(as.integer(.data$vessel_class)) |>
      dplyr::mutate(
        lower = cumsum(.data[[share_col]]) - .data[[share_col]],
        upper = .data$lower + .data[[share_col]],
        share = .data[[share_col]],
        # The raw quantity behind the share, carried through so each class can
        # be annotated with its own count or tonnage, not just its percentage.
        value = .data[[value_col]]
      ) |>
      dplyr::select(vessel_class, lower, upper, share, value)
  }

  left <- extent("share_vessels", "n_unique_vessels")
  right <- extent("share_emissions", "emissions_co2_mt")

  nodes <- dplyr::bind_rows(
    dplyr::mutate(left, side = "fleet", xmin = 0, xmax = node_width),
    dplyr::mutate(right, side = "co2", xmin = 1 - node_width, xmax = 1)
  )

  flows <- dplyr::inner_join(
    left |> dplyr::select(vessel_class, lower, upper),
    right |> dplyr::select(vessel_class, lower, upper),
    by = "vessel_class",
    suffix = c("_left", "_right")
  )

  # Logistic edges, so a ribbon leaves and arrives horizontally rather than
  # meeting the node at an angle. Stretched over +/-6 because the curve is
  # visually flat by then; a narrower window leaves a kink at the nodes.
  curve_steepness <- 6
  n_points <- 80
  sigmoid <- function(from, to) {
    t <- seq(-curve_steepness, curve_steepness, length.out = n_points)
    s <- 1 / (1 + exp(-t))
    # Rescaled to span exactly 0-1. The raw logistic is only asymptotically flat:
    # at +/-6 it still sits ~0.25 % short of its limits, so a ribbon would leave
    # its node a fraction of a percent below the node's own edge. On the wide
    # bands that is invisible, but the separator carries the same offset and
    # reads as a slight tilt across the node face.
    s <- (s - s[1]) / (s[length(s)] - s[1])
    from + (to - from) * s
  }

  ribbons <- flows |>
    dplyr::rowwise() |>
    dplyr::reframe(
      vessel_class = .data$vessel_class,
      x = c(
        seq(node_width, 1 - node_width, length.out = n_points),
        seq(1 - node_width, node_width, length.out = n_points)
      ),
      y = c(
        sigmoid(.data$upper_left, .data$upper_right),
        rev(sigmoid(.data$lower_left, .data$lower_right))
      )
    )

  # One separator per class boundary, run across the whole diagram: flat over
  # the fleet node, curved along the ribbon's top edge, flat again over the CO2
  # node. Drawing it in one pass is what makes the seam line up.
  #
  # Splitting it -- an outline on the node plus a line on the ribbon -- cannot be
  # made to match: the node's rule is drawn *at* y = upper while the ribbon's is
  # *centred* on it, so at the join the two land a pixel or two apart and the
  # separator visibly steps. An outline on the polygon is worse still, since it
  # also paints the ribbon's vertical ends onto the node face.
  edges <- flows |>
    # The top of the stack is the outer edge of the diagram, not a boundary
    # between two classes; a rule there just thickens the silhouette. Dropped
    # before the path is built, so a whole class goes rather than stray points.
    dplyr::filter(.data$upper_left < 1 - 1e-9) |>
    dplyr::rowwise() |>
    dplyr::reframe(
      vessel_class = .data$vessel_class,
      x = c(
        0,
        seq(node_width, 1 - node_width, length.out = n_points),
        1
      ),
      y = c(
        .data$upper_left,
        sigmoid(.data$upper_left, .data$upper_right),
        .data$upper_right
      )
    )

  # Shares sit outside the nodes -- left of the fleet node, right of the CO2
  # node -- so no text is drawn over a fill and no contrast rule is needed.
  # Only the bands with room for the text get one: below the threshold the slab
  # is thinner than the line of type, and annotating those anyway forces a stack
  # of displaced labels and leader lines down the side of the diagram.
  # Two lines per band: the share, and the quantity behind it in brackets on the
  # line below at a smaller size. Drawn as two layers rather than one "\n" label
  # because a single geom_text can only carry one size, and the point of the
  # pairing is that the percentage leads and the raw figure supports it.
  pct <- nodes |>
    dplyr::filter(.data$share >= min_label_share) |>
    dplyr::mutate(
      y = (.data$lower + .data$upper) / 2,
      x = ifelse(.data$side == "fleet", -0.012, 1.012),
      hjust = ifelse(.data$side == "fleet", 1, 0),
      share_label = paste0(round(.data$share * 100), " %"),
      # Vessels are counts; the emissions column is CO2 in tonnes despite its
      # _mt name, so it is divided down to million tonnes to stay readable.
      value_label = paste0(
        "(",
        ifelse(
          .data$side == "fleet",
          scales::label_comma(accuracy = 1)(.data$value),
          paste0(round(.data$value / 1e6), " Mt")
        ),
        ")"
      )
    )

  # Each class named once, on the side where its band is thicker: that is where
  # there is vertical room for the text to sit inside the flow.
  names_at <- flows |>
    dplyr::mutate(
      thick_left = .data$upper_left - .data$lower_left,
      thick_right = .data$upper_right - .data$lower_right,
      # The catch-all is pinned to the emissions side. Its two bands are nearly
      # the same thickness, so the general rule picks the fleet side by a hair
      # and drops the name right where the ordered classes above it are already
      # crowded; on the right it has the corner to itself.
      on_left = .data$thick_left >= .data$thick_right &
        .data$vessel_class != "Other",
      y = ifelse(
        .data$on_left,
        (.data$lower_left + .data$upper_left) / 2,
        (.data$lower_right + .data$upper_right) / 2
      ),
      x = ifelse(.data$on_left, node_width + 0.025, 1 - node_width - 0.025),
      hjust = ifelse(.data$on_left, 0, 1),
      thickness = pmax(.data$thick_left, .data$thick_right),
      label = dplyr::coalesce(
        display_label[as.character(.data$vessel_class)],
        as.character(.data$vessel_class)
      ),
      # Same rule, same threshold and same palette as the year-series figure:
      # white and bold over the saturated fills, plain grey over the pale ones.
      # The name sits on the flow, so the test is against the base colour rather
      # than the darker node shade.
      light_fill = relative_luminance(
        palette[as.character(.data$vessel_class)]
      ) >
        light_fill_luminance,
      label_color = ifelse(.data$light_fill, "grey45", "white"),
      label_face = ifelse(.data$light_fill, "plain", "bold"),
      label_size = ifelse(.data$light_fill, 3, 3.2)
    ) |>
    dplyr::filter(.data$thickness >= min_label_share)

  # Just above the ceiling, or hanging just under it. Only the anchor and the
  # direction the text grows differ between the two.
  heading_y <- if (heading_inside) 0.995 else 1.03
  heading_vjust <- if (heading_inside) 0 else 1

  sankey <- ggplot2::ggplot() +
    ggplot2::geom_polygon(
      data = ribbons,
      ggplot2::aes(
        x = .data$x,
        y = .data$y,
        group = .data$vessel_class,
        fill = .data$vessel_class
      ),
      # Full-strength fill: at a lower alpha the ribbons washed out against the
      # nodes and the paler classes stopped being identifiable.
      color = NA
    ) +
    ggplot2::geom_rect(
      data = nodes,
      # fill taken from the row, not mapped through the shared scale: the nodes
      # use the darkened shade while the flows keep the base colour, and one
      # discrete fill scale cannot serve both.
      ggplot2::aes(
        xmin = .data$xmin,
        xmax = .data$xmax,
        ymin = .data$lower,
        ymax = .data$upper
      ),
      fill = node_palette[as.character(nodes$vessel_class)],
      # No outline: an outlined node draws a white edge down the face where the
      # flows arrive, which is the seam that made the ribbons look as though they
      # stopped short of the column.
      color = NA
    ) +
    # The separators go on last, over both the flows and the nodes, so each is a
    # single unbroken white line from one edge of the diagram to the other.
    ggplot2::geom_line(
      data = edges,
      ggplot2::aes(x = .data$x, y = .data$y, group = .data$vessel_class),
      color = "white",
      linewidth = 0.35,
      lineend = "butt"
    ) +
    # The share sits just above the band's midpoint and its value just below, so
    # the pair straddles the centre the single-line label used to sit on.
    ggplot2::geom_text(
      data = pct,
      ggplot2::aes(
        x = .data$x,
        y = .data$y,
        label = .data$share_label,
        hjust = .data$hjust
      ),
      vjust = -0.1,
      size = 3.1,
      color = "grey25"
    ) +
    ggplot2::geom_text(
      data = pct,
      ggplot2::aes(
        x = .data$x,
        y = .data$y,
        label = .data$value_label,
        hjust = .data$hjust
      ),
      vjust = 1.2,
      size = 2.5,
      color = "grey45"
    ) +
    ggplot2::geom_text(
      data = names_at,
      ggplot2::aes(
        x = .data$x,
        y = .data$y,
        label = .data$label,
        hjust = .data$hjust,
        color = .data$label_color,
        fontface = .data$label_face,
        size = .data$label_size
      )
    ) +
    ggplot2::scale_color_identity() +
    ggplot2::scale_size_identity() +
    # Column headings: what each column is, and nothing else. The totals used to
    # sit on a line below, but every band already carries its own value, so the
    # column sum was the one number here that no one reads off the diagram.
    # Placed above the diagram, or just below its ceiling when the caller has
    # closed up the expansion to align this panel against others.
    ggplot2::annotate(
      "text",
      x = node_width / 2,
      y = heading_y,
      label = paste(year, "fleet size"),
      hjust = 0.5,
      vjust = heading_vjust,
      size = heading_size,
      color = "grey15"
    ) +
    ggplot2::annotate(
      "text",
      x = 1 - node_width / 2,
      y = heading_y,
      label = paste0("'", year, "'~CO[2]~'emissions'"),
      parse = TRUE,
      hjust = 0.5,
      vjust = heading_vjust,
      size = heading_size,
      color = "grey15"
    ) +
    ggplot2::scale_fill_manual(values = palette, guide = "none") +
    # Room outside the nodes for the shares; the diagram itself spans 0-1. Both
    # margins hold one line of the same text, so they are symmetric -- and wide
    # enough that "44 %  (232,497)" fits at the narrowest width this is drawn
    # at. These are fractions of the x-range, so a narrower canvas buys the
    # annotations less room, not the same room: too tight a margin here silently
    # clips the leading digits rather than overflowing visibly.
    ggplot2::scale_x_continuous(
      limits = c(-x_margin, 1 + x_margin_right),
      expand = ggplot2::expansion(0)
    ) +
    ggplot2::scale_y_continuous(
      # The upper margin clears the heading; the lower one is a hairline so the
      # bottom band is not cut by the panel edge.
      expand = ggplot2::expansion(mult = c(y_expand_lower, y_expand_upper))
    ) +
    ggplot2::theme_void() +
    ggplot2::theme(
      plot.background = ggplot2::element_rect(fill = "white", color = NA),
      plot.margin = plot_margin
    )

  if (!is.null(file_path)) {
    dir.create(dirname(file_path), showWarnings = FALSE, recursive = TRUE)
    ggplot2::ggsave(
      file_path,
      sankey,
      width = width,
      height = height,
      dpi = 300,
      bg = "white"
    )
    return(file_path)
  }

  sankey
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

multisector_color_palette <- function(series_labels) {
  known <- multisector_colors()

  missing <- setdiff(series_labels, names(known))
  if (length(missing) > 0) {
    stop(
      "No color assigned for multi-sector series: ",
      paste(missing, collapse = ", "),
      ". Add it to multisector_colors()."
    )
  }

  known[series_labels]
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

# Line style per series. Everything is solid except the maritime-transport
# subsets, which are dashed.
#
# On the trend figure those two run almost exactly on top of GFW (AIS + S1) -
# the transport fleet grows at nearly the same rate as the whole fused fleet -
# and the series that is drawn last hides the one beneath it. They are adjacent
# steps on the same blue ramp by design, so lightness alone cannot separate them
# where they coincide; a dash reads through the overlap, and does so for readers
# who cannot separate the hues at all.
multisector_linetypes <- function(series_labels) {
  linetypes <- rep("solid", length(series_labels))
  names(linetypes) <- series_labels
  linetypes[grepl("maritime transport", series_labels)] <- "22"
  linetypes
}

# The multi-sector inventories' shipping estimates beside our GFW series.
#
# This is the shipping-only view of the multi-sector sources: it answers "when a
# global inventory allocates a line to marine, how does that line compare to a
# bottom-up estimate?". It parallels fig-inventory-comparison, but is kept
# separate because every series here comes from a database that also estimates
# every other sector - the disagreements have different causes than those among
# the shipping models.
#
# CEDS appears at both scopes so the figure shows what the international /
# domestic split is worth: the gap between the two CEDS lines is the domestic
# navigation that EDGAR folds into its single marine sector.
plot_multisector_shipping_comparison <- function(
  multisector_inventory_data,
  gfw_series = NULL,
  gfw_data_sources = c("GFW (AIS + S1)", "GFW (AIS)"),
  gfw_transport_series = NULL,
  shipping_scopes = "Shipping",
  first_year = 2017L,
  file_path = NULL,
  width = 9,
  height = 5.5
) {
  # Only the marine scopes: this figure is the shipping-only view, so the
  # all-sector and other-transportation series carried alongside them in the
  # same table are dropped here rather than filtered by the caller.
  #
  # shipping_scopes selects which marine scopes to draw. The default is the
  # total alone, which is what compares to GFW: our series has no
  # international / domestic split, so drawing the inventories' splits beside it
  # invites a comparison that cannot be made. Pass the split scopes to recover
  # the fuller view - the gap between the two CEDS lines is then the domestic
  # navigation that EDGAR folds into its single marine sector.
  shipping <- multisector_inventory_data |>
    dplyr::filter(scope %in% shipping_scopes) |>
    dplyr::mutate(series = paste(data_source, "-", scope)) |>
    dplyr::select(series, year, emissions_co2_mt)

  # Both GFW series are drawn: AIS alone is the like-for-like against
  # inventories built from broadcasting vessels, while AIS + S1 adds the
  # non-broadcasting fleet that none of these inventories attempt to cover
  if (!is.null(gfw_series)) {
    shipping <- dplyr::bind_rows(
      shipping,
      gfw_series |>
        dplyr::filter(data_source %in% gfw_data_sources) |>
        dplyr::transmute(
          series = data_source,
          year,
          emissions_co2_mt
        )
    )
  }

  # The maritime-transport subset of the AIS fleet, which is the scope-matched
  # comparison: it drops the fishing and service vessels that the inventories'
  # water-borne navigation sectors do not cover
  if (!is.null(gfw_transport_series)) {
    shipping <- dplyr::bind_rows(
      shipping,
      gfw_transport_series |>
        dplyr::transmute(
          series = data_source,
          year,
          emissions_co2_mt
        )
    )
  }

  # Applied after the series are combined so every one starts together: GFW
  # (AIS) and the multi-sector inventories run from 2015, the fused AIS + S1
  # series only from 2017, and a common start keeps the comparison from opening
  # on years where the headline series is absent.
  shipping <- shipping |>
    dplyr::filter(.data$year >= first_year)

  # Grouped by source rather than by magnitude, so each inventory's scopes sit
  # together in the key
  series_order <- multisector_series_order(unique(shipping$series))

  plot_data <- shipping |>
    dplyr::mutate(series = factor(series, levels = series_order))

  axis_max <- ceiling(max(plot_data$emissions_co2_mt) / 0.25e9) * 0.25e9

  shipping_plot <- ggplot2::ggplot(
    plot_data,
    ggplot2::aes(x = year, y = emissions_co2_mt, color = series)
  ) +
    ggplot2::geom_line(ggplot2::aes(linetype = series), linewidth = 1) +
    ggplot2::geom_point(size = 1.8) +
    # Dashed for the maritime-transport subsets, as on the trend figure, so a
    # series keeps the same style in both
    ggplot2::scale_linetype_manual(
      values = multisector_linetypes(series_order),
      guide = "none"
    ) +
    ggplot2::guides(
      color = ggplot2::guide_legend(
        override.aes = list(linetype = multisector_linetypes(series_order))
      )
    ) +
    ggplot2::scale_y_continuous(
      labels = scales::unit_format(unit = "B", scale = 1e-9),
      limits = c(0, axis_max),
      breaks = seq(0, axis_max, 0.25e9)
    ) +
    ggplot2::scale_x_continuous(breaks = sort(unique(plot_data$year))) +
    ggplot2::scale_color_manual(
      name = "Inventory and scope",
      values = multisector_color_palette(series_order)
    ) +
    ggplot2::labs(
      x = "",
      y = expression(Annual ~ CO[2] ~ emissions ~ (MT))
    ) +
    ggplot2::theme_minimal() +
    ggplot2::theme(
      axis.title.y = ggplot2::element_text(
        angle = 90,
        face = "bold",
        vjust = 3,
        size = 12
      ),
      panel.grid.minor = ggplot2::element_blank(),
      legend.position = "right",
      legend.key.height = ggplot2::unit(0.9, "lines"),
      plot.background = ggplot2::element_rect(fill = "white", color = NA)
    )

  if (!is.null(file_path)) {
    dir.create(dirname(file_path), showWarnings = FALSE, recursive = TRUE)
    ggplot2::ggsave(
      file_path,
      shipping_plot,
      width = width,
      height = height,
      dpi = 300
    )
    return(file_path)
  }

  shipping_plot
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

# The growth series as three panels: vessel count, pings, then CO2, one line per
# class, all relative to the baseline year.
#
# Drawn side by side rather than stacked because the measures answer one linked
# question - whether a class's emissions grew because there are more vessels,
# because each vessel is tracked more, or neither - and the comparison is
# between panels at the same x, not down a column. Emissions sit last because
# they are the quantity the first two panels are offered to explain.
#
# Each panel keeps its own y-scale. The three measures differ by an order of
# magnitude in range (fleet size grows tens of percent, pings several hundred),
# so a shared scale would flatten panels A and C into near-horizontal lines.
plot_fleet_growth_by_year <- function(
  fleet_growth_data,
  file_path = NULL,
  width = 18,
  height = 6
) {
  # Ordered by final vessel count, so the legend reads in the order the classes
  # sit on the right of the left-hand panel, with the catch-all last
  latest <- max(fleet_growth_data$year)
  trailing <- "Other"
  ordered <- fleet_growth_data |>
    dplyr::filter(.data$year == latest, !.data$vessel_class %in% trailing) |>
    dplyr::arrange(dplyr::desc(.data$n_unique_vessels)) |>
    dplyr::pull(.data$vessel_class)
  class_levels <- c(
    ordered,
    intersect(trailing, fleet_growth_data$vessel_class)
  )

  plot_data <- fleet_growth_data |>
    dplyr::mutate(
      vessel_class = factor(.data$vessel_class, levels = class_levels)
    )

  # The same Spectral ramp the composition figures spread over their class list,
  # so a class keeps its colour across every fleet figure
  class_colors <- grDevices::colorRampPalette(
    RColorBrewer::brewer.pal(11, "Spectral")
  )(length(class_levels))
  names(class_colors) <- class_levels

  baseline_year <- unique(fleet_growth_data$baseline_year)

  panel <- function(measure, panel_title) {
    ggplot2::ggplot(
      # Drops any class with no baseline value for this measure, rather than
      # letting geom_line warn about missing rows
      dplyr::filter(plot_data, !is.na(.data[[measure]])),
      ggplot2::aes(
        x = .data$year,
        y = .data[[measure]],
        color = .data$vessel_class
      )
    ) +
      ggplot2::geom_hline(yintercept = 0, linetype = 2) +
      ggplot2::geom_line(linewidth = 1) +
      ggplot2::geom_point(size = 1.5) +
      ggplot2::scale_x_continuous(breaks = sort(unique(plot_data$year))) +
      ggplot2::scale_y_continuous(labels = scales::percent) +
      ggplot2::scale_color_manual(
        name = "Vessel class",
        values = class_colors
      ) +
      ggplot2::labs(x = "", y = "", title = panel_title) +
      ggplot2::theme_minimal() +
      ggplot2::theme(
        plot.title = ggplot2::element_text(face = "bold", size = 12),
        panel.grid.minor = ggplot2::element_blank(),
        legend.position = "none"
      )
  }

  panels <- cowplot::plot_grid(
    panel("vessels_change", "AIS-broadcasting fleet size"),
    panel("pings_change", "AIS position messages"),
    panel("emissions_change", expression(bold("CO"[2] * " emissions"))),
    nrow = 1,
    labels = c("A", "B", "C"),
    align = "h",
    axis = "tb"
  )

  legend <- cowplot::get_plot_component(
    panel("vessels_change", "") +
      ggplot2::theme(legend.position = "right") +
      ggplot2::guides(
        color = ggplot2::guide_legend(override.aes = list(linewidth = 1.4))
      ),
    "guide-box-right",
    return_all = TRUE
  )

  growth_plot <- cowplot::plot_grid(
    panels,
    legend,
    nrow = 1,
    # Narrower than the two-panel version's 0.17: this is a fraction of the
    # panel block, which now holds three panels instead of two, and the legend
    # itself is no wider than before
    rel_widths = c(1, 0.115)
  ) +
    ggplot2::theme(
      plot.background = ggplot2::element_rect(fill = "white", color = NA)
    )

  # One shared y-axis title, since all three panels are the same quantity
  # against the same baseline
  growth_plot <- cowplot::ggdraw(growth_plot) +
    cowplot::draw_label(
      paste0("Relative change from ", baseline_year, " baseline"),
      x = 0.005,
      y = 0.5,
      angle = 90,
      fontface = "bold",
      size = 12
    )

  if (!is.null(file_path)) {
    dir.create(dirname(file_path), showWarnings = FALSE, recursive = TRUE)
    ggplot2::ggsave(
      file_path,
      growth_plot,
      width = width,
      height = height,
      dpi = 300
    )
    return(file_path)
  }

  growth_plot
}

# Fleet totals each model reports, transcribed from the "Number of vessels" row
# of comparions_model_table.xlsx (Table 2 - Input data).
#
# These are the totals the model publications state, not counts we derived, and
# they are what makes an intensity possible for STEAM, SEIM and MariTEAM - none
# of which report a fleet count in their gridded output, so none appear in the
# per-year intensity figure built from inventory_vessel_counts.csv.
#
# Each count describes a stated span, which is carried here so the emissions it
# is divided by cover the same years. Two are single-year inventories; the rest
# are averages per year over the model's reporting period.
#
# STEAM's count is the 2015 figure of Johansson et al. 2017; later STEAM updates
# do not restate it. MariTEAM and STEAM are therefore single-year intensities
# and should be read as such.
#
# The GFW row is our own average per year over 2015-2025, on the same basis, so
# the comparison is like for like.
#
# Caption for the table this builds, to accompany it in the text:
#
#   CO2 intensity per vessel across global shipping emission inventories. For
#   each model, mean annual CO2 over its reporting period divided by the fleet
#   total it reports, giving one intensity per model rather than a time series.
#   Emissions are from all_inventory_data.csv, harmonised to CO2 in tonnes per
#   year; fleet totals are the "Number of vessels" row of Table 2 in
#   comparions_model_table.xlsx, transcribed from each model's own publication
#   and not derived by us. Each model's emissions are averaged over exactly the
#   span its reported count describes, so numerator and denominator cover the
#   same years: means per year for SEIM (2016-2021), OECD (2019-2024), SAVE/ICCT
#   (2016-2023), the Fourth IMO GHG Study (2015-2018) and emLab-GFW (2015-2025),
#   and single years for STEAM (2015, Johansson et al. 2017) and MariTEAM (2017),
#   neither of which restates a fleet count in later updates. Intensities span
#   roughly an order of magnitude, from ~2,300 t CO2 per vessel to over 20,000,
#   while the mean annual totals behind them agree to within a few per cent: the
#   spread reflects disagreement about which vessels to count, not about how much
#   shipping emits. The two models enumerating the whole AIS-active fleet rather
#   than a registry - STEAM and emLab-GFW - agree to within half a per cent
#   despite being independent, while the highest intensities belong to the models
#   restricted to a few tens of thousands of large registered ships.
#
# Caveats a reader needs and the table cannot show. The counts are not
# harmonised: each is the fleet its own model states, on that model's matching
# pipeline, coverage thresholds and definition of an active vessel, so they are
# comparable in magnitude but not like-for-like hull counts. Ours is distinct
# ssvid, a broadcast identifier rather than a hull, which undercounts vessels
# changing ssvid and overcounts ssvids shared between hulls. OECD's total
# includes roughly 14 thousand vessels whose emissions are imputed rather than
# observed, the only fleet here that is not activity-bounded. The ICCT figure is
# its headline total over all 20 SAVE classes, but slightly over half of those
# vessels sit in the "Unknown" class, which reports emissions and no distance
# and so is not the fleet behind ICCT's own intensity - restricted to the
# distance-reporting classes its intensity roughly doubles, and that restricted
# basis is the one to cite when comparing intensities rather than fleet sizes.
# STEAM's and MariTEAM's single-year values carry no information about trend.
# CEDS, EDGAR and the other gridded fuel-based inventories are necessarily
# absent: they downscale fuel statistics and never enumerate vessels, so no
# denominator exists for them.
inventory_reported_fleet_totals <- function() {
  tibble::tribble(
    ~data_source, ~n_vessels, ~count_basis, ~year_from, ~year_to,
    "CAMS-GLOB-SHIP (STEAM)", 376219L, "2015 only", 2015L, 2015L,
    "SEIM", 109300L, "reported total", 2016L, 2021L,
    "MariTEAM", 45891L, "2017 only", 2017L, 2017L,
    "OECD", 115817L, "mean per year", 2019L, 2024L,
    "ICCT", 252490L, "mean per year", 2016L, 2023L,
    "IMO", 188046L, "mean per year", 2015L, 2018L,
    "GFW (AIS)", 396221L, "mean per year", 2015L, 2025L
  )
}

# CO2 per vessel for every model, using the fleet total each one reports.
#
# The companion to plot_inventory_intensity(), which can only cover the four
# inventories publishing a vessel count per year. Taking the totals each model
# states in its own methodology table brings in STEAM, SEIM and MariTEAM, at the
# cost of a single number per model rather than a series - so this is drawn as
# ranked bars over one period each, not as lines over time.
#
# What the figure is for: the intensities span an order of magnitude, from
# roughly 2,300 t per vessel to over 20,000, while the total emissions behind
# them agree to within a few per cent. Panel B is what carries that - it shows
# the same models' mean annual CO2 sitting in a narrow band - so the spread in
# panel A reads as a disagreement about which ships to count rather than about
# how much shipping emits.
#
# Our estimate is the lowest but one, and the exception is telling: STEAM, the
# only other model here that counts the whole AIS fleet rather than a registry,
# lands within half a per cent of us despite being an entirely independent
# model. The models reporting far higher intensities are those enumerating a
# few tens of thousands of large registered ships.
plot_inventory_intensity_all_models <- function(
  inventory_data_file = file.path(
    "data",
    "inventories",
    "all_inventory_data.csv"
  ),
  fleet_totals = inventory_reported_fleet_totals(),
  file_path = NULL,
  width = 11,
  height = 8
) {
  emissions <- readr::read_csv(inventory_data_file, show_col_types = FALSE) |>
    dplyr::mutate(year = as.integer(.data$year))

  # Mean annual CO2 over exactly the span each reported count describes
  intensity <- emissions |>
    dplyr::inner_join(fleet_totals, by = "data_source") |>
    dplyr::filter(
      .data$year >= .data$year_from,
      .data$year <= .data$year_to
    ) |>
    dplyr::group_by(
      .data$data_source,
      .data$n_vessels,
      .data$count_basis
    ) |>
    dplyr::summarise(
      mean_co2_mt = mean(.data$emissions_co2_mt),
      years = paste(min(.data$year), max(.data$year), sep = "-"),
      .groups = "drop"
    ) |>
    dplyr::mutate(
      co2_t_per_vessel = .data$mean_co2_mt / .data$n_vessels,
      mean_co2_gt = .data$mean_co2_mt / 1e9,
      vessels_thousands = .data$n_vessels / 1e3,
      # Shortened for the axis, matching the comparison figure's legend
      label = dplyr::recode(
        .data$data_source,
        "CAMS-GLOB-SHIP (STEAM)" = "STEAM"
      )
    )

  ordered <- intensity |>
    dplyr::arrange(.data$co2_t_per_vessel) |>
    dplyr::pull(.data$label)

  plot_data <- intensity |>
    dplyr::mutate(label = factor(.data$label, levels = ordered))

  # Our own estimate in the accent hue, every other model in a recessive grey.
  # This is an emphasis figure rather than a categorical one: the question is
  # where we sit against the field, not which model is which.
  ours <- "GFW (AIS)"
  fill_values <- ifelse(ordered == ours, "#0072B2", "grey70")
  names(fill_values) <- ordered

  base_theme <- ggplot2::theme_minimal() +
    ggplot2::theme(
      axis.title.x = ggplot2::element_text(face = "bold", size = 11),
      panel.grid.major.y = ggplot2::element_blank(),
      panel.grid.minor = ggplot2::element_blank(),
      legend.position = "none"
    )

  bar_panel <- function(measure, x_label, label_fmt) {
    ggplot2::ggplot(
      plot_data,
      ggplot2::aes(
        x = .data[[measure]],
        y = .data$label,
        fill = .data$label
      )
    ) +
      ggplot2::geom_col(width = 0.7) +
      ggplot2::geom_text(
        ggplot2::aes(label = label_fmt(.data[[measure]])),
        hjust = -0.15,
        size = 3.2,
        color = "grey20"
      ) +
      ggplot2::scale_fill_manual(values = fill_values) +
      ggplot2::scale_x_continuous(
        expand = ggplot2::expansion(mult = c(0, 0.18))
      ) +
      ggplot2::labs(x = x_label, y = "") +
      base_theme
  }

  panel_a <- bar_panel(
    "co2_t_per_vessel",
    expression(bold(CO[2] ~ per ~ vessel ~ (t))),
    \(x) scales::comma(x, accuracy = 1)
  )
  panel_b <- bar_panel(
    "mean_co2_gt",
    expression(bold(Mean ~ annual ~ CO[2] ~ (Gt))),
    \(x) scales::number(x, accuracy = 0.01)
  )
  panel_c <- bar_panel(
    "vessels_thousands",
    "Vessels reported (thousands)",
    \(x) scales::comma(x, accuracy = 1)
  )

  combined <- cowplot::plot_grid(
    panel_a,
    panel_b,
    panel_c,
    ncol = 3,
    labels = c("A", "B", "C"),
    align = "h",
    axis = "tb"
  ) +
    ggplot2::theme(
      plot.background = ggplot2::element_rect(fill = "white", color = NA)
    )

  if (!is.null(file_path)) {
    dir.create(dirname(file_path), showWarnings = FALSE, recursive = TRUE)
    ggplot2::ggsave(
      file_path,
      combined,
      width = width,
      height = height,
      dpi = 300
    )
    return(file_path)
  }

  combined
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

# Ten-colour turbo ramp for the S1 length bins and deciles.
#
# end = 0.92 drops the pale yellow at the top of the ramp, which is unreadable
# as a thin line on white. Shared by the two panelled figures below so their
# bins stay comparable.
s1_length_palette <- function(n = 10) {
  viridisLite::turbo(n, end = 0.92)
}

# The dark (unmatched) share of S1 detections, per fleet length decile, with a
# single full-period trend per decile.
#
# The era-split version of this figure fits one line before the December 2021
# S1B failure and another after it. That split is the right way to read the
# density figures, where the break moves the level, but it is the wrong way to
# read this one: the unmatched share is a ratio of two counts drawn from the
# same scenes, so a change in how much ocean was imaged cancels out of it. A
# single fit over the whole period is therefore the honest summary, and it is
# what makes the figure a statement about the fleet rather than about the
# satellite.
#
# Fixed metre bins, the same ones as fig-density-by-match-status.png and
# ais_carriage_saturation_by_size.png: 0-25m upward in 25m steps to 225+m for
# non-fishing, collapsed to 100+m for fishing, which has almost nothing above
# it. An earlier version cut each fleet into its own deciles, which kept the
# panels equally populated but made a bin mean a different length range in each
# fleet, and a different one again from the density figures it is read beside.
plot_unmatched_fraction_fullperiod <- function(
  fixed_bin_file = file.path(
    "data",
    "gfw",
    "s1_detections_by_fixed_length_bin.csv"
  ),
  file_path = NULL,
  width = 11,
  height = 4.2
) {
  detections <- readr::read_csv(fixed_bin_file, show_col_types = FALSE) |>
    dplyr::mutate(
      month = as.Date(.data$month),
      fleet = forcats::fct_rev(
        ifelse(.data$fishing, "Fishing", "Non-fishing")
      ),
      bin_max = suppressWarnings(as.numeric(.data$length_bin_max)),
      bin = ifelse(
        is.na(.data$bin_max) | is.infinite(.data$bin_max),
        sprintf("%.0f+m", as.numeric(.data$length_bin_min)),
        sprintf(
          "%.0f-%.0fm",
          as.numeric(.data$length_bin_min),
          .data$bin_max
        )
      ),
      bin = forcats::fct_reorder(.data$bin, .data$length_size_bin),
      unmatched_share = .data$n_s1_detections_unmatched /
        .data$n_s1_detections
    )

  palette <- s1_length_palette()

  fleet_panel <- function(fleet_name) {
    panel_data <- detections |>
      dplyr::filter(.data$fleet == fleet_name)
    # Fishing has five bins to non-fishing's ten, so the colours are taken from
    # the low end of the shared ramp in both panels - the same convention as
    # fig-density-by-match-status.png, which keeps 0-25m the same colour in each.
    panel_bins <- panel_data |>
      dplyr::distinct(.data$length_size_bin, .data$bin) |>
      dplyr::arrange(.data$length_size_bin)

    panel_data |>
      ggplot2::ggplot(
        ggplot2::aes(.data$month, .data$unmatched_share, color = .data$bin)
      ) +
      ggplot2::geom_line(linewidth = 0.3, alpha = 0.5) +
      ggplot2::geom_smooth(method = "lm", se = FALSE, linewidth = 0.9) +
      ggplot2::facet_wrap(~fleet) +
      ggplot2::scale_y_continuous(
        limits = c(0, 1),
        labels = scales::percent
      ) +
      ggplot2::scale_x_date(date_breaks = "1 year", date_labels = "%Y") +
      ggplot2::scale_color_manual(
        name = paste0(fleet_name, "\nlength bin"),
        values = stats::setNames(
          palette[seq_len(nrow(panel_bins))],
          panel_bins$bin
        )
      ) +
      ggplot2::labs(
        x = "",
        y = "Unmatched (dark) share of detections"
      ) +
      ggplot2::theme_bw(base_size = 9) +
      ggplot2::theme(
        strip.background = ggplot2::element_rect(
          fill = "transparent",
          color = NA
        ),
        strip.text = ggplot2::element_text(face = "bold"),
        legend.key.height = ggplot2::unit(0.7, "lines"),
        legend.title = ggplot2::element_text(size = 8),
        legend.text = ggplot2::element_text(size = 7),
        panel.grid.minor = ggplot2::element_blank()
      )
  }

  combined <- cowplot::plot_grid(
    fleet_panel("Non-fishing"),
    fleet_panel("Fishing"),
    ncol = 2
  ) +
    ggplot2::theme(
      plot.background = ggplot2::element_rect(fill = "white", color = NA)
    )

  if (!is.null(file_path)) {
    dir.create(dirname(file_path), showWarnings = FALSE, recursive = TRUE)
    ggplot2::ggsave(
      file_path,
      combined,
      width = width,
      height = height,
      dpi = 200,
      bg = "white"
    )
    return(file_path)
  }

  combined
}

# Where AIS carriage grew, by vessel size.
#
# This is the figure the inventory comparison leans on when it says our series
# is conditioned by AIS uptake more than the registry-built inventories are.
# Each arrow runs from a size bin's dark share in the first comparison year to
# its share in the last. The large non-fishing bins, the ones an IMO-registry
# inventory enumerates, barely move: carriage there was already effectively
# universal, so nothing an AIS-derived series does can add vessels to that
# segment. The movement is all in the small tail, which is exactly the part no
# registry inventory counts.
#
# Fixed metre bins rather than the deciles the trend figure uses: the claim here
# is about specific size classes and their regulatory status, so a bin has to
# mean the same thing in both fleets.
#
# CAPTION SOURCE - the figure is drawn with no title or subtitle, so the reading
# lives in the caption instead of being burned into the image where a caption
# would only repeat it. The text that used to be drawn is kept here as the
# material to write that caption from:
#
#   Title    AIS carriage was already near-universal in the registry-mandated
#            segment; the expansion happens in the small-vessel tail.
#
#   Subtitle Unmatched share of Sentinel-1 detections, <first> vs <last> (the
#            two comparison_years). Large non-fishing vessels (AIS-mandated)
#            sit low and barely move; small and fishing vessels start largely
#            dark and migrate into the AIS-observed fleet.
#
# Not drawn, but needed by any caption written from the above: each arrow runs
# from a bin's unmatched share in the first comparison year to its share in the
# last, the point marks the two endpoints, and the label beside it is the change
# in percentage points.
plot_ais_carriage_saturation_by_size <- function(
  fixed_bin_file = file.path(
    "data",
    "gfw",
    "s1_detections_by_fixed_length_bin.csv"
  ),
  comparison_years = c(2017L, 2025L),
  file_path = NULL,
  width = 9,
  height = 4.4
) {
  first_year <- min(comparison_years)
  last_year <- max(comparison_years)

  detections <- readr::read_csv(fixed_bin_file, show_col_types = FALSE) |>
    dplyr::mutate(
      month = as.Date(.data$month),
      year = as.integer(format(.data$month, "%Y")),
      fleet = forcats::fct_rev(
        ifelse(.data$fishing, "Fishing", "Non-fishing")
      ),
      bin_max = suppressWarnings(as.numeric(.data$length_bin_max)),
      bin = ifelse(
        is.na(.data$bin_max) | is.infinite(.data$bin_max),
        sprintf("%.0f+m", as.numeric(.data$length_bin_min)),
        sprintf(
          "%.0f-%.0fm",
          as.numeric(.data$length_bin_min),
          .data$bin_max
        )
      ),
      bin = forcats::fct_reorder(.data$bin, .data$length_size_bin)
    )

  shares <- detections |>
    dplyr::filter(.data$year %in% c(first_year, last_year)) |>
    dplyr::group_by(.data$fleet, .data$bin, .data$year) |>
    dplyr::summarise(
      share = sum(.data$n_s1_detections_unmatched) /
        sum(.data$n_s1_detections),
      .groups = "drop"
    ) |>
    tidyr::pivot_wider(
      names_from = "year",
      values_from = "share",
      names_prefix = "y"
    ) |>
    dplyr::rename(
      share_start = paste0("y", first_year),
      share_end = paste0("y", last_year)
    ) |>
    dplyr::mutate(
      change_pp = 100 * (.data$share_end - .data$share_start),
      # Smallest bin at the top, so the axis reads down from the tail that
      # moves to the registry-mandated sizes that do not.
      bin = forcats::fct_rev(.data$bin)
    )

  endpoints <- shares |>
    tidyr::pivot_longer(
      c("share_start", "share_end"),
      names_to = "endpoint",
      values_to = "share"
    ) |>
    dplyr::mutate(
      year = ifelse(
        .data$endpoint == "share_start",
        as.character(first_year),
        as.character(last_year)
      )
    )

  year_colors <- stats::setNames(
    c("grey60", "#2c7fb8"),
    as.character(c(first_year, last_year))
  )

  saturation_plot <- shares |>
    ggplot2::ggplot(ggplot2::aes(y = .data$bin)) +
    ggplot2::geom_segment(
      ggplot2::aes(
        x = .data$share_start,
        xend = .data$share_end,
        yend = .data$bin
      ),
      arrow = ggplot2::arrow(
        length = ggplot2::unit(5, "pt"),
        type = "closed"
      ),
      color = "grey40",
      linewidth = 0.55
    ) +
    ggplot2::geom_point(
      data = endpoints,
      ggplot2::aes(x = .data$share, color = .data$year),
      size = 2.6
    ) +
    ggplot2::geom_text(
      ggplot2::aes(
        x = pmax(.data$share_start, .data$share_end) + 0.035,
        label = sprintf("%+.0f pp", .data$change_pp)
      ),
      size = 2.7,
      hjust = 0,
      color = "grey30"
    ) +
    ggplot2::facet_wrap(~fleet, scales = "free_y") +
    ggplot2::scale_x_continuous(
      labels = scales::percent,
      limits = c(0, 1.02),
      expand = ggplot2::expansion(mult = c(0.01, 0.06))
    ) +
    ggplot2::scale_color_manual(name = NULL, values = year_colors) +
    ggplot2::labs(
      x = "Share of S1-detected vessels not matched to an AIS broadcast",
      y = "Vessel length (S1-estimated)"
    ) +
    ggplot2::theme_bw(base_size = 9) +
    ggplot2::theme(
      strip.background = ggplot2::element_rect(
        fill = "transparent",
        color = NA
      ),
      strip.text = ggplot2::element_text(face = "bold"),
      legend.position = "top",
      panel.grid.minor = ggplot2::element_blank()
    )

  if (!is.null(file_path)) {
    dir.create(dirname(file_path), showWarnings = FALSE, recursive = TRUE)
    ggplot2::ggsave(
      file_path,
      saturation_plot,
      width = width,
      height = height,
      dpi = 200,
      bg = "white"
    )
    return(file_path)
  }

  saturation_plot
}

# Emissions reconciliation ----
#
# Two supporting figures for the top-down inventory comparison. They answer
# the objection the comparison invites: our series grows faster than the
# registry-built inventories, so is the growth real activity or just more of the
# ocean coming into view? Each figure isolates one channel through which
# observation could masquerade as activity.
#
# Both redraw from 01_gfw_data_pull extracts already in the repo.

# The length bins the S1 detection extracts use, so the AIS-side and
# satellite-side size axes can be read against each other without re-binning
# either. Matches the CASE expression in
# sql/annual_ais_activity_summary_cheap.sql.
s1_length_bin_levels <- function() {
  c(
    "0-25m",
    "25-50m",
    "50-75m",
    "75-100m",
    "100-125m",
    "125-150m",
    "150-175m",
    "175-200m",
    "200-225m",
    "225m+"
  )
}

# A series divided by its own mean over the opening window, so series in
# different units share an axis.
#
# A window rather than a single month because these are monthly series with a
# seasonal cycle, and dividing by one January would put that January's weather
# into every later value.
index_to_baseline <- function(x, t, months = 24L) {
  baseline_end <- seq(min(t), by = "1 month", length.out = months)[months]
  x / mean(x[t <= baseline_end])
}

# The passenger class opened up by vessel length, in four square panels: levels
# and changes, counts and emissions.
#
# Panel layout, and the reading each panel carries - kept here rather than in
# titles on the figure so the caption can be written from one place:
#
#   A  Passenger vessels observed in AIS by length bin, 2015-2025 (stacked).
#      The observed fleet goes 68k -> 230k vessels, and the stack is almost
#      entirely 0-25 m and 25-50 m.
#   B  AIS-based passenger CO2 by the same bins and years (stacked). 93 -> 269
#      Mt, with
#      the same two bins carrying it. Read against A: the two stacks rise
#      together, so the growth is vessels entering the observed fleet rather
#      than more activity credited to the vessels already there. The one visible
#      divergence is 2020, where emissions dip but the headcount does not - the
#      expected COVID signature of activity falling while vessels stayed
#      AIS-visible.
#   C  Change in vessels per bin, 2017-2025, as a percentage of 2017, with the
#      absolute change labelled.
#   D  The same for AIS-based CO2. Read C against D bin by bin: every bin adds vessels and
#      almost every bin adds emissions. 0-25 m grows faster in emissions than in
#      vessels (+186% vs +150%), so its average vessel also got more active.
#      Above 100 m the ratio inverts - 100-125 m adds +64% vessels for +33%
#      emissions, 225m+ +34% for +20%, and 175-200 m adds vessels (+26%) while
#      its emissions fall (-15%) - so larger passenger vessels are entering the
#      observed fleet at lower average activity than those already in it.
#
# Why C and D are percentages rather than absolute Mt:
# the 0-25 m bin adds ~119,000 vessels and ~100 Mt, two to three orders of
# magnitude above the bins over 100 m. On a shared absolute axis every bin above
# 50 m is a hairline and the vessels-against-emissions comparison the panels
# exist for cannot be read at all. Percentages put both measures and all ten bins
# on one scale; the bar labels keep the magnitudes.
#
# Caveat for the caption: the counts are vessels *seen in AIS that year*, so A
# and C cannot separate new vessels from newly-observed ones. That question is
# the S1 carriage-saturation figure's, not this one's.
#
# Counts are n_unique_vessels summed over registry_type within a bin-year. A
# vessel sits in one length bin and one registry class per year in this extract,
# so the sum is a headcount rather than a double count.
plot_passenger_size_panels <- function(
  gfw_activity_file = file.path(
    "data",
    "gfw",
    "annual_ais_activity_summary_cheap.csv"
  ),
  comparison_years = c(2017L, 2025L),
  vessel_class_name = "passenger",
  file_path = NULL,
  width = 7.6,
  height = 8.4
) {
  first_year <- min(comparison_years)
  last_year <- max(comparison_years)

  passenger <- readr::read_csv(gfw_activity_file, show_col_types = FALSE) |>
    dplyr::filter(.data$vessel_class == vessel_class_name) |>
    dplyr::mutate(
      year = as.integer(.data$year),
      length_bin = factor(.data$length_bin, levels = s1_length_bin_levels())
    )

  if (nrow(passenger) == 0) {
    stop(
      "The activity extract has no rows for vessel class ",
      vessel_class_name,
      "."
    )
  }

  for (yr in c(first_year, last_year)) {
    if (!yr %in% passenger$year) {
      stop(
        "The activity extract has no data for year ",
        yr,
        ". It covers ",
        paste(range(passenger$year), collapse = "-"),
        "."
      )
    }
  }

  bin_colors <- stats::setNames(
    s1_length_palette(length(s1_length_bin_levels())),
    s1_length_bin_levels()
  )

  # Emissions are named _mt in the extract but held in tonnes.
  by_bin_year <- passenger |>
    dplyr::group_by(.data$length_bin, .data$year) |>
    dplyr::summarise(
      co2_mt = sum(.data$emissions_co2_mt) / 1e6,
      n_vessels = sum(.data$n_unique_vessels),
      .groups = "drop"
    )

  # aspect.ratio = 1 makes the plotting region itself exactly square. cowplot's
  # align = "hv" would equalise panel widths across the grid and override it, so
  # the panels below are assembled unaligned - each keeps its own square panel
  # region and pays for its own axis text outside it.
  # The panel regions are square, so the only thing that can push the two
  # columns apart is the axis furniture between them: margins, tick length and
  # the gap under the axis titles. All three are trimmed here, and the figure
  # width is set just wide enough for the four square panels plus that
  # furniture, so the columns sit as close together as the labels allow.
  square_theme <- ggplot2::theme_bw(base_size = 9) +
    ggplot2::theme(
      aspect.ratio = 1,
      legend.position = "none",
      panel.grid.minor = ggplot2::element_blank(),
      plot.margin = ggplot2::margin(2, 3, 2, 2),
      axis.ticks.length = ggplot2::unit(2, "pt"),
      axis.title.x = ggplot2::element_text(
        margin = ggplot2::margin(t = 3)
      ),
      axis.title.y = ggplot2::element_text(
        margin = ggplot2::margin(r = 2)
      ),
      axis.text = ggplot2::element_text(
        margin = ggplot2::margin(1, 1, 1, 1)
      )
    )

  stacked_area_panel <- function(value, y_label, y_labels) {
    by_bin_year |>
      ggplot2::ggplot(
        ggplot2::aes(
          x = .data$year,
          y = .data[[value]],
          fill = forcats::fct_rev(.data$length_bin)
        )
      ) +
      ggplot2::geom_area(colour = "white", linewidth = 0.15) +
      ggplot2::scale_fill_manual(
        "Length group",
        values = bin_colors,
        breaks = s1_length_bin_levels()
      ) +
      ggplot2::scale_x_continuous(breaks = scales::breaks_width(2)) +
      ggplot2::scale_y_continuous(
        labels = y_labels,
        expand = ggplot2::expansion(mult = c(0, 0.04))
      ) +
      ggplot2::labs(x = NULL, y = y_label) +
      square_theme
  }

  counts_panel <- stacked_area_panel(
    "n_vessels",
    "Passenger vessels observed in AIS",
    scales::label_number(scale_cut = scales::cut_short_scale())
  )

  emissions_panel <- stacked_area_panel(
    "co2_mt",
    bquote("Annual AIS-based passenger CO"[2] * " (Mt)"),
    scales::label_number()
  )

  changes <- by_bin_year |>
    dplyr::filter(.data$year %in% c(first_year, last_year)) |>
    tidyr::pivot_longer(
      c("n_vessels", "co2_mt"),
      names_to = "measure",
      values_to = "value"
    ) |>
    tidyr::pivot_wider(
      names_from = "year",
      values_from = "value",
      names_prefix = "y"
    ) |>
    dplyr::mutate(
      dplyr::across(dplyr::starts_with("y"), ~ tidyr::replace_na(.x, 0)),
      change = .data[[paste0("y", last_year)]] -
        .data[[paste0("y", first_year)]],
      pct = 100 *
        .data$change /
        dplyr::na_if(.data[[paste0("y", first_year)]], 0),
      hjust = ifelse(.data$change < 0, 1.12, -0.12)
    )

  # C and D share one percentage axis so a bin's headcount bar and its emissions
  # bar can be compared by eye rather than by reading two different scales.
  pct_limits <- range(c(0, changes$pct), na.rm = TRUE)

  # D repeats C's length groups in the same row order, so only C carries the
  # length axis - dropping the duplicate is what lets the two columns sit close.
  change_panel <- function(
    measure_name,
    x_label,
    bar_color,
    label_fun,
    length_axis = TRUE
  ) {
    changes |>
      dplyr::filter(.data$measure == measure_name) |>
      dplyr::mutate(label = label_fun(.data$change)) |>
      ggplot2::ggplot(
        ggplot2::aes(
          y = forcats::fct_rev(.data$length_bin),
          x = .data$pct
        )
      ) +
      ggplot2::geom_vline(xintercept = 0, colour = "grey20", linewidth = 0.4) +
      ggplot2::geom_col(fill = bar_color, width = 0.62) +
      ggplot2::geom_text(
        ggplot2::aes(label = .data$label, hjust = .data$hjust),
        size = 2.4,
        colour = "grey25"
      ) +
      ggplot2::scale_x_continuous(
        labels = scales::label_number(style_positive = "plus", suffix = "%"),
        limits = pct_limits,
        # Left room for the one negative bar's label, right room for the rest.
        expand = ggplot2::expansion(mult = c(0.14, 0.26))
      ) +
      ggplot2::labs(
        x = x_label,
        y = if (length_axis) "Length group" else NULL
      ) +
      square_theme +
      ggplot2::theme(
        panel.grid.major.y = ggplot2::element_blank(),
        axis.text.y = if (length_axis) {
          ggplot2::element_text(margin = ggplot2::margin(1, 1, 1, 1))
        } else {
          ggplot2::element_blank()
        },
        axis.ticks.y = if (length_axis) {
          ggplot2::element_line()
        } else {
          ggplot2::element_blank()
        }
      )
  }

  counts_change_panel <- change_panel(
    "n_vessels",
    paste0(
      "Change in passenger vessels, ",
      first_year,
      " - ",
      last_year
    ),
    "#4c72a8",
    scales::label_number(
      style_positive = "plus",
      accuracy = 1,
      scale_cut = scales::cut_short_scale()
    )
  )

  emissions_change_panel <- change_panel(
    "co2_mt",
    bquote(
      "Change in AIS-based passenger CO"[2] * ", " * .(first_year) * " - " *
        .(last_year)
    ),
    "#5f8f4e",
    function(x) {
      paste0(
        scales::label_number(style_positive = "plus", accuracy = 0.1)(x),
        " Mt"
      )
    },
    length_axis = FALSE
  )

  # One length-bin key for A and B, taken from a copy of A that keeps its legend.
  legend <- cowplot::get_plot_component(
    counts_panel +
      ggplot2::theme(legend.position = "bottom") +
      ggplot2::guides(
        fill = ggplot2::guide_legend(
          nrow = 1,
          keywidth = ggplot2::unit(9, "pt"),
          keyheight = ggplot2::unit(9, "pt")
        )
      ),
    "guide-box-bottom",
    return_all = TRUE
  )

  # The width a plot spends on everything outside its panel - axis title, tick
  # labels, ticks and margins - measured off the built gtable in inches.
  #
  # This is what decides how far apart the two columns of a row sit, and the two
  # plots in a row do not spend the same amount: only C carries the length
  # labels. Measuring it here, rather than aligning the row or hard-coding a
  # width ratio, is what keeps the layout reproducible: it is derived from the
  # grobs the current device and font metrics actually produce, so re-running the
  # pipeline on another machine re-derives it instead of inheriting a constant
  # tuned to this one.
  #
  # cowplot's align = "hv" is the obvious alternative and is wrong here: it would
  # reserve C's label column on D's side too and fill it with whitespace, which
  # is the gap this layout exists to close.
  non_panel_width_in <- function(plot) {
    grDevices::pdf(NULL, width = width, height = height)
    on.exit(grDevices::dev.off(), add = TRUE)
    gt <- ggplot2::ggplotGrob(plot)
    panel_cols <- gt$layout$l[gt$layout$name == "panel"]
    outside <- setdiff(seq_along(gt$widths), seq(min(panel_cols), max(panel_cols)))
    sum(grid::convertWidth(gt$widths[outside], "in", valueOnly = TRUE))
  }

  # Cell widths that give the two panels of a row the same size: the plot that
  # spends more outside its panel gets the wider cell, by exactly that excess.
  row_widths <- function(left_plot, right_plot) {
    left_outside <- non_panel_width_in(left_plot)
    right_outside <- non_panel_width_in(right_plot)
    left_cell <- (width + left_outside - right_outside) / 2
    c(left_cell, width - left_cell)
  }

  levels_row <- cowplot::plot_grid(
    counts_panel,
    emissions_panel,
    ncol = 2,
    labels = c("A", "B"),
    label_size = 11,
    rel_widths = row_widths(counts_panel, emissions_panel)
  )

  change_row <- cowplot::plot_grid(
    counts_change_panel,
    emissions_change_panel,
    ncol = 2,
    labels = c("C", "D"),
    label_size = 11,
    rel_widths = row_widths(counts_change_panel, emissions_change_panel)
  )

  # The key sits between the rows because it belongs to A and B only - C and D
  # carry the bins on their y axis and take their colour from the measure.
  size_panels_plot <- cowplot::plot_grid(
    levels_row,
    legend,
    change_row,
    ncol = 1,
    rel_heights = c(1, 0.08, 1)
  )

  if (!is.null(file_path)) {
    dir.create(dirname(file_path), showWarnings = FALSE, recursive = TRUE)
    ggplot2::ggsave(
      file_path,
      size_panels_plot,
      width = width,
      height = height,
      dpi = 200,
      bg = "white"
    )
    return(file_path)
  }

  size_panels_plot
}

# Whether the AIS message explosion inflated the inventory.
#
# Dynamic AIS was widely adopted around 2021 and the message count roughly
# doubles after it. If emissions were being computed off message volume, the
# inventory would have inflated for reasons that have nothing to do with
# shipping. This plots messages, vessel-hours, distance and emissions as percent
# change from 2021 and shows emissions tracking hours and distance rather than
# messages: the extra messages densify tracks that were already observed, adding
# resolution rather than activity.
#
# Referenced to the phase-in year rather than the start of the record, so the
# four series are compared from the moment the concern begins.
plot_messages_hours_emissions <- function(
  gfw_activity_file = file.path(
    "data",
    "gfw",
    "annual_ais_activity_summary.csv"
  ),
  baseline_year = 2021L,
  start_year = 2017L,
  end_year = 2025L,
  file_path = NULL,
  width = 8.5,
  height = 5.2
) {
  series_levels <- c(
    "Messages",
    "Vessel-hours",
    "Distance travelled",
    "AIS CO2 emissions"
  )

  ais_activity <- readr::read_csv(
    gfw_activity_file,
    show_col_types = FALSE
  ) |>
    dplyr::filter(.data$year >= start_year, .data$year <= end_year) |>
    dplyr::group_by(.data$year) |>
    dplyr::summarise(
      Messages = sum(.data$n_pings),
      `Vessel-hours` = sum(.data$vessel_hours),
      `Distance travelled` = sum(.data$distance_travelled_nm),
      `AIS CO2 emissions` = sum(.data$emissions_co2_mt),
      .groups = "drop"
    ) |>
    tidyr::pivot_longer(
      -"year",
      names_to = "series",
      values_to = "value"
    ) |>
    dplyr::group_by(.data$series) |>
    dplyr::mutate(
      pct_change = 100 *
        (.data$value / .data$value[.data$year == baseline_year] - 1)
    ) |>
    dplyr::ungroup() |>
    dplyr::mutate(series = factor(.data$series, levels = series_levels))

  # Distance and emissions end within a whisker of each other, which is the
  # finding, but it collides the two end labels. Nudged apart by a fixed gap
  # rather than by ggrepel, which is not in renv.lock.
  end_labels <- ais_activity |>
    dplyr::filter(.data$year == end_year) |>
    dplyr::mutate(
      label = sprintf("%s  %+.0f%%", .data$series, .data$pct_change)
    ) |>
    dplyr::arrange(.data$pct_change) |>
    dplyr::mutate(
      y_position = {
        y <- .data$pct_change
        gap <- 7
        for (i in seq_along(y)[-1]) {
          if (y[i] - y[i - 1] < gap) y[i] <- y[i - 1] + gap
        }
        y
      }
    )

  series_colors <- c(
    "Messages" = "grey40",
    "Vessel-hours" = "#7b3294",
    "Distance travelled" = "#2c7fb8",
    "AIS CO2 emissions" = "#e69f00"
  )

  messages_plot <- ais_activity |>
    ggplot2::ggplot(
      ggplot2::aes(.data$year, .data$pct_change, colour = .data$series)
    ) +
    ggplot2::geom_hline(yintercept = 0, colour = "grey70", linewidth = 0.3) +
    ggplot2::geom_vline(
      xintercept = baseline_year,
      linetype = "dashed",
      colour = "grey40",
      linewidth = 0.35
    ) +
    ggplot2::geom_line(linewidth = 0.9) +
    ggplot2::geom_point(size = 1.4) +
    ggplot2::geom_text(
      data = end_labels,
      ggplot2::aes(
        x = end_year + 0.15,
        y = .data$y_position,
        label = .data$label
      ),
      hjust = 0,
      size = 2.9,
      fontface = "bold",
      show.legend = FALSE
    ) +
    ggplot2::scale_colour_manual(NULL, values = series_colors) +
    ggplot2::scale_x_continuous(
      breaks = seq(start_year, end_year, by = 1),
      limits = c(start_year, end_year + 2)
    ) +
    ggplot2::scale_y_continuous(
      labels = function(x) paste0(ifelse(x > 0, "+", ""), round(x), "%")
    ) +
    ggplot2::labs(
      x = "",
      y = paste0("Change from ", baseline_year)
    ) +
    ggplot2::theme_minimal(base_size = 9) +
    ggplot2::theme(
      legend.position = "top",
      panel.grid.minor = ggplot2::element_blank()
    )

  if (!is.null(file_path)) {
    dir.create(dirname(file_path), showWarnings = FALSE, recursive = TRUE)
    ggplot2::ggsave(
      file_path,
      messages_plot,
      width = width,
      height = height,
      dpi = 200,
      bg = "white"
    )
    return(file_path)
  }

  messages_plot
}
