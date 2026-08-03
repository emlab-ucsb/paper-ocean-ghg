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

# Report the metadata of a CAMS NetCDF - global attributes, variables, units and
# grid - so the provenance of the inventory (model version, methodology, source
# publication) can be recorded alongside the numbers.
inspect_cams_nc_metadata <- function(nc_file) {
  nc <- ncdf4::nc_open(nc_file)
  on.exit(ncdf4::nc_close(nc), add = TRUE)

  global_attributes <- ncdf4::ncatt_get(nc, 0)
  emissions_variable <- cams_emissions_variable(nc)
  lat <- as.numeric(ncdf4::ncvar_get(
    nc,
    cams_axis_name(nc, c("lat", "latitude"))
  ))
  lon <- as.numeric(ncdf4::ncvar_get(
    nc,
    cams_axis_name(nc, c("lon", "longitude"))
  ))

  list(
    file = basename(nc_file),
    global_attributes = global_attributes,
    variables = names(nc$var),
    emissions_variable = emissions_variable,
    emissions_units = ncdf4::ncatt_get(nc, emissions_variable, "units")$value,
    emissions_long_name = ncdf4::ncatt_get(
      nc,
      emissions_variable,
      "long_name"
    )$value,
    grid_resolution_deg = c(
      lon = abs(stats::median(diff(lon))),
      lat = abs(stats::median(diff(lat)))
    ),
    grid_dim = c(lon = length(lon), lat = length(lat)),
    n_time_slices = if ("time" %in% names(nc$dim)) {
      nc$dim$time$len
    } else {
      NA_integer_
    }
  )
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

# Read the annual AIS activity summary collapsed back to one row per year.
#
# The extract is stored one row per year AND vessel class, so that the
# fleet-composition figures can split emissions by class from the same source
# that produces the paper's headline annual totals. Everything that wants only
# the year-level series goes through here rather than reading the file directly,
# so the class split cannot silently multiply rows in a caller that assumes one
# row per year.
#
# The measure columns are additive over classes -- every ping belongs to exactly
# one class -- so summing them reproduces the year totals exactly. The vessel
# count is the exception: COUNT(DISTINCT ssvid) is computed per class, so summing
# it would double count any ssvid that changed class mid-year. It does not on the
# current run version, but summing is still the wrong operation for a distinct
# count, so this returns the sum and the callers that care are documented as
# treating it as an upper bound.
read_annual_ais_activity <- function(
  gfw_activity_file = file.path(
    "data",
    "gfw",
    "annual_ais_activity_summary.csv"
  )
) {
  readr::read_csv(gfw_activity_file, show_col_types = FALSE) |>
    dplyr::group_by(.data$year) |>
    dplyr::summarise(
      emissions_co2_mt = sum(.data$emissions_co2_mt),
      distance_travelled_nm = sum(.data$distance_travelled_nm),
      vessel_hours = sum(.data$vessel_hours),
      n_unique_vessels = sum(.data$n_unique_vessels),
      n_pings = sum(.data$n_pings),
      .groups = "drop"
    )
}


# Year-by-year comparison of the ICCT inventory against our AIS-based estimate.
#
# ICCT is the only published inventory here that reports vessel activity as well
# as emissions, so it is the only one we can compare on more than a single
# number. It is also the closest methodological match to our AIS series: both are
# AIS-derived, and neither attempts to include non-broadcasting vessels, which is
# why this compares against GFW (AIS) rather than the fused AIS + S1 estimate.
#
# Compares five quantities, each with a percent difference (ours relative to
# theirs): CO2 intensity in kg per nautical mile, absolute CO2, distance
# travelled, vessel count, and average CO2 per vessel.
#
# Two caveats travel with the table rather than being smoothed over:
#
#   * ICCT's "Unknown" ship class carries CO2 and a ship count but no distance,
#     so its distance covers only identified vessels while its CO2 covers all of
#     them. Both vessel counts are reported for that reason.
#   * Our vessel count is distinct ssvid, a broadcast identifier rather than a
#     hull identity, spanning the whole AIS fleet including small fishing
#     vessels. It is not the same quantity as ICCT's count of merchant ships, so
#     the ratio shows the gap rather than implying a like-for-like discrepancy.
compare_icct_to_gfw_ais <- function(
  gfw_activity_file = file.path(
    "data",
    "gfw",
    "annual_ais_activity_summary.csv"
  ),
  icct_url = "https://theicct.org/wp-content/uploads/2025/04/supplemental_vf.xlsx"
) {
  download_dir <- file.path(tempdir(), "icct_comparison")
  dir.create(download_dir, showWarnings = FALSE, recursive = TRUE)
  on.exit(unlink(download_dir, recursive = TRUE), add = TRUE)

  destination <- file.path(download_dir, basename(icct_url))
  utils::download.file(
    icct_url,
    destfile = destination,
    mode = "wb",
    quiet = TRUE
  )

  icct <- purrr::map_dfr(readxl::excel_sheets(destination), function(sheet) {
    sheet_data <- readxl::read_excel(destination, sheet = sheet)
    class_column <- names(sheet_data)[1]
    classes <- !is.na(sheet_data[[class_column]]) &
      !grepl("^Note", sheet_data[[class_column]])
    identified <- classes & sheet_data[[class_column]] != "Unknown"
    total <- function(column, rows) {
      sum(
        suppressWarnings(as.numeric(sheet_data[[column]][rows])),
        na.rm = TRUE
      )
    }

    # An intensity needs its numerator and denominator to describe the same
    # vessels. ICCT reports "---" for the distance of its "Unknown" class, so
    # those vessels contribute emissions but no distance; dividing all-class CO2
    # by the distance of the classes that do report it would attribute their
    # emissions to other vessels' miles and overstate ICCT's intensity by about
    # 8%. The intensity therefore uses only the classes reporting both, selected
    # on whether distance is actually present rather than by class name, so a
    # future class without distance is handled the same way.
    reports_distance <- classes &
      !is.na(suppressWarnings(
        as.numeric(sheet_data[["Distance travelled (nm)"]])
      ))

    tibble::tibble(
      year = as.integer(sheet),
      # Headline totals, over every class
      icct_co2_mt = total("CO2 emissions (tonne)", classes),
      icct_distance_nm = total("Distance travelled (nm)", classes),
      icct_n_vessels = total("Number of ships", classes),
      icct_n_vessels_identified = total("Number of ships", identified),
      # Matched pair for the intensity: classes reporting both quantities
      icct_co2_mt_with_distance = total(
        "CO2 emissions (tonne)",
        reports_distance
      ),
      icct_distance_nm_with_distance = total(
        "Distance travelled (nm)",
        reports_distance
      ),
      icct_n_vessels_with_distance = total("Number of ships", reports_distance)
    )
  })

  gfw <- read_annual_ais_activity(gfw_activity_file) |>
    dplyr::select(
      year,
      gfw_co2_mt = emissions_co2_mt,
      gfw_distance_nm = distance_travelled_nm,
      gfw_n_vessels = n_unique_vessels
    )

  # inner_join keeps only the years both sources cover
  dplyr::inner_join(gfw, icct, by = "year") |>
    dplyr::transmute(
      year = .data$year,
      # Intensity, kg CO2 per nautical mile. ICCT's side uses only the classes
      # that report both emissions and distance, so both sides of the ratio
      # describe the same vessels.
      gfw_intensity_kg_nm = .data$gfw_co2_mt * 1000 / .data$gfw_distance_nm,
      icct_intensity_kg_nm = .data$icct_co2_mt_with_distance *
        1000 /
        .data$icct_distance_nm_with_distance,
      intensity_percent_difference = 100 *
        (.data$gfw_intensity_kg_nm / .data$icct_intensity_kg_nm - 1),
      # The vessels behind that intensity, for reference
      icct_co2_mt_with_distance = .data$icct_co2_mt_with_distance,
      icct_n_vessels_with_distance = .data$icct_n_vessels_with_distance,
      # Absolute emissions, tonnes
      gfw_co2_mt = .data$gfw_co2_mt,
      icct_co2_mt = .data$icct_co2_mt,
      co2_percent_difference = 100 * (.data$gfw_co2_mt / .data$icct_co2_mt - 1),
      # Distance, nautical miles
      gfw_distance_nm = .data$gfw_distance_nm,
      icct_distance_nm = .data$icct_distance_nm,
      distance_percent_difference = 100 *
        (.data$gfw_distance_nm / .data$icct_distance_nm - 1),
      # Vessels: ICCT reported both ways, since its Unknown class has no distance
      gfw_n_vessels = .data$gfw_n_vessels,
      icct_n_vessels = .data$icct_n_vessels,
      icct_n_vessels_identified = .data$icct_n_vessels_identified,
      vessels_percent_difference = 100 *
        (.data$gfw_n_vessels / .data$icct_n_vessels - 1),
      # Average CO2 per vessel, tonnes. Each model's own total CO2 over its own
      # vessel count; for ICCT that is the full count, including the Unknown
      # class, because its CO2 total covers those ships too. The two are not
      # like-for-like for the same reason the vessel counts are not: ours is
      # distinct ssvid across the whole AIS fleet, theirs is merchant ships.
      gfw_co2_per_vessel_t = .data$gfw_co2_mt / .data$gfw_n_vessels,
      icct_co2_per_vessel_t = .data$icct_co2_mt / .data$icct_n_vessels,
      co2_per_vessel_percent_difference = 100 *
        (.data$gfw_co2_per_vessel_t / .data$icct_co2_per_vessel_t - 1)
    ) |>
    dplyr::arrange(.data$year)
}

# The IMO's own global shipping CO2 totals, from the Fourth IMO GHG Study 2020
# (voyage-based totals). The study covers 2012-2018 but we only carry the years
# that overlap our analysis window, which is why this series stops at 2018.
# There is no machine-readable source to download, so the numbers are
# transcribed. This mirrors imo_data in qmd/quarto_notebook.qmd.
imo_ghg_study_co2 <- function() {
  tibble::tibble(
    data_source = "IMO",
    year = c(2016L, 2017L, 2018L),
    emissions_co2_mt = c(1.026e9, 1.064e9, 1.056e9)
  )
}

# Number of vessels each inventory covers, for comparing fleet coverage rather
# than emissions.
#
# The IMO counts are the "Total included" column of the Fourth IMO GHG Study
# 2020, transcribed from the report because there is no machine-readable source.
# They run 2012-2018, so they extend earlier than the study's emissions series
# carried above.
#
# The ICCT counts are summed over all 20 ship classes of the SAVE workbook, which
# is the headline fleet total. Note that slightly over half of those vessels sit
# in the "Unknown" ship class, which reports emissions but no distance, so this
# total is not the fleet behind the ICCT intensity figures - see
# compare_icct_to_gfw_ais() for the counts on that basis.
#
# The two counts are not strictly like for like: they come from different studies
# with different matching pipelines and coverage thresholds, so the column
# reports each inventory's own stated coverage rather than a harmonised fleet.
inventory_vessel_counts <- function(
  icct_years = 2016:2023,
  icct_url = "https://theicct.org/wp-content/uploads/2025/04/supplemental_vf.xlsx",
  gfw_activity_file = file.path(
    "data",
    "gfw",
    "annual_ais_activity_summary.csv"
  )
) {
  # Our own count is distinct ssvid, a broadcast identifier rather than a hull
  # identity: it undercounts vessels that change ssvid and overcounts ssvids
  # shared between hulls. It also spans the whole AIS fleet including small
  # fishing vessels, which is why it runs well above the merchant-fleet counts
  # the other inventories report.
  gfw <- read_annual_ais_activity(gfw_activity_file) |>
    dplyr::transmute(
      data_source = "GFW (AIS)",
      year = .data$year,
      n_vessels = as.numeric(.data$n_unique_vessels)
    )

  imo <- tibble::tibble(
    data_source = "IMO",
    year = 2012:2018,
    n_vessels = c(133334, 162503, 179784, 181005, 194059, 228134, 237505)
  )

  # OECD publishes its coverage as three groups, transcribed here in thousands:
  # vessels matched by IMO number, vessels matched by MMSI number instead, and
  # active vessels with no AIS data whose emissions are imputed from the monthly
  # median of their type category. The total is the sum of the three.
  #
  # This is the one inventory here that quantifies its imputed non-AIS fleet: it
  # is roughly 14 thousand vessels, and unlike the other two groups it shrinks
  # year on year, which the OECD attributes to improving AIS coverage.
  oecd <- tibble::tibble(
    year = 2019:2024,
    n_vessels_imo_matched = c(71.5, 72.6, 74.5, 75.6, 77.4, 80.3) * 1e3,
    n_vessels_mmsi_matched = c(26.3, 25.1, 25.6, 25.5, 27.5, 28.4) * 1e3,
    n_vessels_imputed = c(14.5, 14.3, 14.1, 14.0, 13.9, 13.8) * 1e3
  ) |>
    dplyr::mutate(
      data_source = "OECD",
      n_vessels = .data$n_vessels_imo_matched +
        .data$n_vessels_mmsi_matched +
        .data$n_vessels_imputed
    )

  download_dir <- file.path(tempdir(), "icct_vessel_counts")
  dir.create(download_dir, showWarnings = FALSE, recursive = TRUE)
  on.exit(unlink(download_dir, recursive = TRUE), add = TRUE)

  destination <- file.path(download_dir, basename(icct_url))
  utils::download.file(
    icct_url,
    destfile = destination,
    mode = "wb",
    quiet = TRUE
  )

  wanted_sheets <- intersect(
    as.character(icct_years),
    readxl::excel_sheets(destination)
  )

  icct <- purrr::map_dfr(wanted_sheets, function(sheet) {
    sheet_data <- readxl::read_excel(destination, sheet = sheet)
    class_column <- names(sheet_data)[1]
    classes <- !is.na(sheet_data[[class_column]]) &
      !grepl("^Note", sheet_data[[class_column]])

    tibble::tibble(
      data_source = "ICCT",
      year = as.integer(sheet),
      n_vessels = sum(
        suppressWarnings(as.numeric(sheet_data[["Number of ships"]][classes])),
        na.rm = TRUE
      )
    )
  })

  # One row per year, one column per model, holding the total vessel count. Years
  # a model does not cover are left empty rather than filled or dropped, so the
  # different spans stay visible.
  dplyr::bind_rows(gfw, imo, icct, oecd) |>
    dplyr::mutate(year = as.integer(.data$year)) |>
    dplyr::select(data_source, year, n_vessels) |>
    tidyr::pivot_wider(
      names_from = data_source,
      values_from = n_vessels
    ) |>
    dplyr::select(
      year,
      dplyr::any_of(c("GFW (AIS)", "ICCT", "IMO", "OECD"))
    ) |>
    dplyr::arrange(.data$year)
}

# Line plot of how many vessels each inventory covers over time.
#
# Takes the wide table written by inventory_vessel_counts() and pivots it back to
# long form for plotting, so the figure and the CSV cannot drift apart.
#
# The series are deliberately not drawn as a single comparable quantity: each
# inventory counts a different fleet on a different basis (see
# inventory_vessel_counts), so the figure shows each one's stated coverage. The
# axis starts at zero, since these are counts and the differences between the
# inventories are large enough not to need a truncated axis to be visible.
plot_inventory_vessel_counts <- function(
  inventory_vessel_counts,
  baseline_year = 2019L,
  ping_baseline_year = 2017L,
  gfw_activity_file = file.path(
    "data",
    "gfw",
    "annual_ais_activity_summary.csv"
  ),
  file_path = NULL,
  width = 8,
  height = 13
) {
  plot_data <- inventory_vessel_counts |>
    tidyr::pivot_longer(
      -year,
      names_to = "data_source",
      values_to = "n_vessels"
    ) |>
    dplyr::filter(!is.na(.data$n_vessels))

  # Order the legend by each inventory's most recent count, so the key reads
  # top-to-bottom in the same order the lines end on the right
  source_order <- plot_data |>
    dplyr::group_by(data_source) |>
    dplyr::filter(.data$year == max(.data$year)) |>
    dplyr::summarise(n_vessels = max(.data$n_vessels), .groups = "drop") |>
    dplyr::arrange(dplyr::desc(.data$n_vessels)) |>
    dplyr::pull(data_source)

  panel_a <- plot_vessel_count_levels(plot_data, source_order = source_order)
  panel_b <- plot_vessel_count_relative_change(
    plot_data,
    baseline_year = baseline_year,
    source_order = source_order
  )
  # Pings get their own panel rather than another line in panel B: they grow by
  # several hundred percent over the same period, so on a shared axis they would
  # flatten every vessel series into the zero line.
  panel_c <- plot_gfw_ping_relative_change(
    gfw_activity_file = gfw_activity_file,
    baseline_year = ping_baseline_year
  )

  # Panel A carries the legend and the others do not, so their plotting areas
  # would be different widths and the x-axes would not line up; align = "v" with
  # axis = "lr" pads the other panels out to match.
  vessel_plot <- cowplot::plot_grid(
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
      vessel_plot,
      width = width,
      height = height,
      dpi = 300,
      bg = "white"
    )
    return(file_path)
  }

  vessel_plot
}

# Panel A: vessel counts as published, on a zero baseline.
plot_vessel_count_levels <- function(plot_data, source_order) {
  plot_data <- plot_data |>
    dplyr::mutate(
      data_source = factor(.data$data_source, levels = source_order)
    )

  ggplot2::ggplot(
    plot_data,
    ggplot2::aes(x = year, y = n_vessels, color = data_source)
  ) +
    ggplot2::geom_line(linewidth = 1) +
    ggplot2::geom_point(size = 1.8) +
    ggplot2::scale_y_continuous(
      labels = scales::label_number(scale = 1e-3, suffix = "k"),
      limits = c(0, NA),
      expand = ggplot2::expansion(mult = c(0, 0.05))
    ) +
    ggplot2::scale_x_continuous(breaks = sort(unique(plot_data$year))) +
    ggplot2::scale_color_manual(
      name = "Inventory",
      # Reuse the emissions figure's palette so an inventory keeps one color
      # across both figures
      values = inventory_color_palette(source_order)
    ) +
    ggplot2::labs(x = "", y = "Vessels included") +
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
      legend.key.height = ggplot2::unit(0.9, "lines")
    )
}

# Panel C: change in the number of our AIS pings, relative to the baseline year.
#
# This is deliberately a single series on its own panel. Pings measure how often
# vessels are observed, not how much they do: over this period they grow several
# times faster than the vessels, distance or emissions behind them, because AIS
# reception has been densifying rather than because ships are sailing more. The
# separate panel keeps that scale from flattening the vessel series in panel B,
# and keeps the two quantities from being read as comparable trends.
plot_gfw_ping_relative_change <- function(
  gfw_activity_file = file.path(
    "data",
    "gfw",
    "annual_ais_activity_summary.csv"
  ),
  baseline_year = 2017L
) {
  activity <- read_annual_ais_activity(gfw_activity_file)

  baseline_pings <- activity$n_pings[activity$year == baseline_year]
  if (length(baseline_pings) != 1) {
    stop(
      "The activity summary has no ping count for baseline_year ",
      baseline_year,
      ", so there is nothing to normalize against."
    )
  }

  plot_data <- activity |>
    dplyr::filter(.data$year >= baseline_year) |>
    dplyr::mutate(relative_change = .data$n_pings / baseline_pings - 1)

  ggplot2::ggplot(
    plot_data,
    ggplot2::aes(x = year, y = relative_change)
  ) +
    ggplot2::geom_hline(yintercept = 0, linetype = 2) +
    ggplot2::geom_line(
      linewidth = 1,
      color = inventory_color_palette("GFW (AIS)")[[1]]
    ) +
    ggplot2::geom_point(
      size = 1.8,
      color = inventory_color_palette("GFW (AIS)")[[1]]
    ) +
    ggplot2::scale_x_continuous(breaks = sort(unique(plot_data$year))) +
    ggplot2::scale_y_continuous(labels = scales::percent) +
    ggplot2::labs(
      x = "",
      y = bquote(atop(
        Relative ~ change ~ "in" ~ AIS ~ pings,
        from ~ .(baseline_year) ~ baseline
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

# Panel B: change in coverage relative to the baseline year, so the inventories
# can be compared on growth rather than on level - the levels differ mostly
# because each counts a different fleet.
#
# Every series needs a value in the same baseline year for the changes to be
# comparable, so any inventory without one is dropped: with a 2019 baseline that
# is IMO, whose series ends in 2018. Years before the baseline are dropped too,
# so the panel starts at the line it is normalized to.
plot_vessel_count_relative_change <- function(
  plot_data,
  baseline_year,
  source_order
) {
  baseline <- plot_data |>
    dplyr::filter(.data$year == baseline_year) |>
    dplyr::select(data_source, baseline_n_vessels = n_vessels)

  if (nrow(baseline) == 0) {
    stop(
      "No inventory reports a vessel count for baseline_year ",
      baseline_year,
      ", so there is nothing to normalize against."
    )
  }

  normalized <- plot_data |>
    dplyr::filter(.data$year >= baseline_year) |>
    # inner_join drops any series with no baseline-year value
    dplyr::inner_join(baseline, by = "data_source") |>
    dplyr::mutate(
      relative_change = .data$n_vessels / .data$baseline_n_vessels - 1
    )

  included_sources <- intersect(source_order, unique(normalized$data_source))

  normalized <- normalized |>
    dplyr::mutate(
      data_source = factor(.data$data_source, levels = included_sources)
    )

  ggplot2::ggplot(
    normalized,
    ggplot2::aes(x = year, y = relative_change, color = data_source)
  ) +
    ggplot2::geom_hline(yintercept = 0, linetype = 2) +
    ggplot2::geom_line(linewidth = 1) +
    ggplot2::geom_point(size = 1.8) +
    ggplot2::scale_x_continuous(breaks = sort(unique(normalized$year))) +
    ggplot2::scale_y_continuous(labels = scales::percent) +
    ggplot2::scale_color_manual(
      name = "Inventory",
      values = inventory_color_palette(included_sources)
    ) +
    ggplot2::labs(
      x = "",
      y = bquote(atop(
        Relative ~ change ~ "in",
        vessels ~ from ~ .(baseline_year) ~ baseline
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

# The Type 1/2+3 subset of the IMO series above.
#
# The IMO study assigns each ship a calculation method by how well its activity
# is known: Types 1, 2 and 3 are the ships whose activity is tracked, while Type
# 4 covers those whose activity is inferred rather than observed. Our AIS
# estimate can only see the tracked population, so the full IMO total is not the
# like-for-like comparison - this series is.
#
# Two approximations, neither of which the published tables let us avoid:
#
#   * The study reports no CO2 table split by type. The split is only published
#     as the stacked bars of Figure 69, so the shares below are read off that
#     figure - reliable to about a percentage point, no better. They land within
#     half a point of each other across all three years, which is the main
#     reason to trust them.
#   * Figure 69 is CO2-equivalent, not CO2. We apply its shares to the CO2
#     totals in imo_ghg_study_co2(), which assumes Types 1/2+3 have the same
#     CO2-to-CO2e ratio as the fleet as a whole. Non-CO2 GHGs are a small part
#     of the total, so the error this introduces is well inside the error
#     already carried by reading the shares off a figure.
#
# Given both, treat this series as indicative of the level and trend, not as a
# published IMO number.
imo_ghg_study_type123_co2 <- function() {
  imo_total <- imo_ghg_study_co2()

  # Types 1/2+3 share of total CO2e, from Figure 69: top of the medium-blue
  # Type 3 band over the labelled bar total (2016: ~985/1045, 2017: ~1020/1083,
  # 2018: ~1012/1076). Only Type 4, the light-blue band above it, is excluded.
  type123_share <- c(0.943, 0.942, 0.941)

  imo_total |>
    dplyr::mutate(
      data_source = "IMO (Type 1/2+3)",
      emissions_co2_mt = .data$emissions_co2_mt * type123_share
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
  data_pull_store = file.path("_targets", "01_gfw_data_pull")
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
    dplyr::mutate(data_source = "EDGAR")

  dplyr::bind_rows(gfw_ais_s1, gfw_ais, edgar_marine) |>
    dplyr::mutate(year = as.integer(year)) |>
    dplyr::filter(year >= analysis_start_year, year <= analysis_end_year)
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
    imo_ghg_study_type123_co2(),
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
  start_year = 2017L,
  file_path = NULL,
  width = 9,
  height = 14
) {
  # Both panels start at start_year, which is also the panel B baseline: showing
  # earlier years would put IMO's 2016 point (the only pre-2017 data) on its own
  # off to the left of every other series, and leave panel B with a line
  # crossing the baseline it is normalized to.
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

# Colors for the inventory comparison. The four sources already in the notebook
# figure keep their Okabe-Ito colors from all_data_source_color_palette so the
# two figures stay readable side by side; the inventories added by this pipeline
# take the remaining Okabe-Ito hues.
# Line style per inventory. Everything is solid except the IMO Type 1/2+3
# subset, which is dashed: it shares IMO's hue by design, and two similar greens
# are hard to separate at line width, so the dash carries the distinction where
# color alone would not - including for readers who cannot separate the hues at
# all.
inventory_linetypes <- function(data_sources) {
  linetypes <- rep("solid", length(data_sources))
  names(linetypes) <- data_sources
  linetypes[names(linetypes) == "IMO (Type 1/2+3)"] <- "22"
  linetypes
}

inventory_color_palette <- function(data_sources) {
  okabe_ito <- paletteer::paletteer_d("colorblindr::OkabeIto")

  known <- c(
    "GFW (AIS + S1)" = okabe_ito[[5]],
    "GFW (AIS)" = okabe_ito[[1]],
    "EDGAR" = okabe_ito[[8]],
    "OECD" = okabe_ito[[6]],
    "IMO" = okabe_ito[[3]],
    # The subset shares IMO's hue, darkened, so the two read as the same source
    # at two scopes rather than as unrelated inventories
    "IMO (Type 1/2+3)" = "#1B7837",
    # Keyed on the display label set in plot_inventory_comparison(), not the
    # longer name carried in the data
    "STEAM" = okabe_ito[[2]],
    # Okabe-Ito's yellow is too low-contrast on white for a thin line, so SEIM
    # takes a darker hue from outside the palette
    "SEIM" = "#7B3294",
    "ICCT" = okabe_ito[[7]],
    "MariTEAM" = "grey30"
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
# each class's colour (see the palette note in plot_fleet_shares_by_year).
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

# The pies again, but as a year series: one 100 % stacked column per year, fleet
# size in panel A and CO2 in panel B. Same information as the pies for any single
# year, with the years side by side so a shifting composition is visible.
plot_fleet_shares_by_year <- function(
  fleet_data,
  file_path = NULL,
  # A class is folded into "Other" only if it is small in both panels in every
  # year, matching the pie version's rule; folding per year instead would let a
  # class appear and disappear from the legend between columns.
  min_share = 0.005,
  # Segments below this are left unlabelled: the slabs are too thin for the text
  # to sit inside them without overlapping their neighbours.
  min_label_share = 0.04,
  # The three refrigerated-cargo spellings, merged under one name. They are the
  # same kind of vessel in three labels of the source vocabulary, so drawn apart
  # each is a thin sliver that says less than the group does.
  grouped_as_reefer = c(
    "Specialized reefer",
    "Container reefer",
    "Cargo: refrigerated"
  ),
  reefer_label = "Reefer",
  # Support and service classes folded into "Other" whatever their share. Named
  # explicitly rather than caught by a share rule, because "is this a support
  # vessel" is not something the shares can answer.
  grouped_as_other = c(
    "Supply vessel",
    "Patrol vessel",
    "Bunker",
    "Dredge non fishing",
    "Other not fishing"
  ),
  # Fills brighter than this get grey text instead of white. Sits between
  # Cargo: container (~0.69) and the next fill down, Tanker: oil (~0.55), so it
  # covers the pale yellows near the top of the emissions columns while leaving
  # the saturated oranges and reds on white.
  light_fill_luminance = 0.62,
  width = 14,
  height = 7,
  # Near the full category width, so consecutive years read as a continuous
  # series rather than as nine separate charts. Kept below 1 so a hairline of
  # background still separates one year from the next.
  bar_width = 0.92
) {
  small <- fleet_data |>
    dplyr::group_by(vessel_class) |>
    dplyr::summarise(
      small = max(.data$share_emissions) < min_share &
        max(.data$share_vessels) < min_share,
      .groups = "drop"
    )

  # The class ordering as it stands before the support classes are folded away.
  # The palette is built from this rather than from the surviving classes, so
  # every class keeps the colour it had when the support vessels were still
  # drawn separately: a ramp spread over a shorter list would hand each class a
  # different colour and silently recolour the whole figure.
  palette_levels <- fleet_data |>
    dplyr::left_join(small, by = "vessel_class") |>
    dplyr::mutate(
      # Reefer is formed here too, so it takes the ramp position its members
      # occupied rather than being appended as a new colour; the support classes
      # are deliberately left unfolded so every other class keeps its original
      # place in the ramp.
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
    # Re-aggregated before ranking: the size fold collapses several classes into
    # "Other", and ranking the un-summed rows would order that group by whichever
    # fragment happened to come first.
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

  fleet_data <- fleet_data |>
    dplyr::left_join(small, by = "vessel_class") |>
    dplyr::mutate(
      # Reefers first, and before the size rule: each of the three spellings is
      # individually small enough that the threshold would sweep them into
      # "Other" before they ever became a group.
      vessel_class = ifelse(
        .data$vessel_class %in% grouped_as_reefer,
        reefer_label,
        .data$vessel_class
      ),
      # Folded regardless of size: these are service and support vessels rather
      # than the cargo-carrying classes the figure is about, so they are grouped
      # even where a share threshold would have kept them.
      vessel_class = ifelse(
        .data$vessel_class %in% grouped_as_other,
        "Other",
        .data$vessel_class
      ),
      # The size rule runs last and must not re-split the groups just formed:
      # `small` was computed per original class, so a reefer spelling still
      # carries small = TRUE even though the merged group may not be small.
      vessel_class = ifelse(
        .data$small & !.data$vessel_class %in% c(reefer_label, "Other"),
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

  latest <- max(fleet_data$year)
  class_levels <- stacked_class_levels(fleet_data)

  # Subset rather than regenerate, so each surviving class keeps exactly the
  # colour it was assigned over the unfolded list.
  palette <- full_palette[class_levels]

  # The columns are normalised, so the year-to-year magnitude is invisible in the
  # bars themselves. `total_col` is the raw quantity behind each column, summed
  # per year and printed above it, so the composition and the level can be read
  # off the same figure. `total_fmt` formats it: counts are plain integers, CO2
  # is converted from tonnes to Mt because the raw figure runs to nine digits.
  # `show_axis = FALSE` drops the percent axis on the right-hand panel: both
  # panels run 0-100 % on the same scale, so the second copy is redundant and
  # only widens the gap the connectors have to span.
  share_panel <- function(share_col, total_col, total_fmt, title, show_axis) {
    totals <- fleet_data |>
      dplyr::group_by(.data$year) |>
      dplyr::summarise(
        total = sum(.data[[total_col]], na.rm = TRUE),
        .groups = "drop"
      ) |>
      dplyr::mutate(label = total_fmt(.data$total))

    panel_data <- fleet_data |>
      dplyr::mutate(
        vessel_class = factor(.data$vessel_class, levels = class_levels),
        # geom_col stacks in reverse level order, so reversing here puts the
        # first level at the top of the column, matching the legend read
        # top-to-bottom and the pies read clockwise from twelve.
        stack_order = forcats::fct_rev(.data$vessel_class),
        share = .data[[share_col]],
        label = ifelse(
          .data$share >= min_label_share,
          paste0(round(.data$share * 100), " %"),
          ""
        ),
        # White text disappears on the pale end of the Spectral ramp, so the
        # lightest fills get grey instead. Chosen by the fill's own luminance
        # rather than by naming the classes: the ramp is generated from however
        # many classes survive the "Other" folding, so which colours are pale
        # depends on the data and would drift if hardcoded.
        light_fill = relative_luminance(
          palette[as.character(.data$vessel_class)]
        ) >
          light_fill_luminance,
        label_color = ifelse(.data$light_fill, "grey45", "white"),
        # Plain weight on the pale fills. Bold is there to hold white text
        # against a saturated colour; grey on a light fill does not need the
        # extra weight, and bolding it only makes the lighter tone look heavier
        # than the white labels around it.
        label_face = ifelse(.data$light_fill, "plain", "bold"),
        # A shade smaller on the pale fills. Bold white text on a saturated
        # colour tightens visually, so at one point size the plain grey reads
        # as the larger of the two; trimming it evens them out optically.
        label_size = ifelse(.data$light_fill, 3, 3.2)
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
      # Same position_stack as the bars, so a label always lands on its own
      # segment rather than on a hand-computed cumulative position. Colour and
      # weight are mapped, not set: both vary per segment (see label_color
      # above), and constants would apply one style to every label.
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
      # identity, so label_size is taken as the literal text size in mm rather
      # than as a value to be rescaled onto a size range.
      ggplot2::scale_size_identity() +
      # Its own data frame, one row per year: mapped through the stacked layer's
      # data it would be drawn once per class and print the total on top of
      # itself as many times as there are segments.
      ggplot2::geom_text(
        data = totals,
        ggplot2::aes(x = factor(.data$year), y = 1, label = .data$label),
        inherit.aes = FALSE,
        vjust = -0.6,
        size = 3,
        color = "grey25"
      ) +
      ggplot2::scale_fill_manual(values = palette, drop = FALSE, name = NULL) +
      # Padding is a fixed fraction of a category rather than half a bar width:
      # tying it to bar_width would widen the outer margins every time the bars
      # are widened, which is the opposite of what widening them is for.
      ggplot2::scale_x_discrete(
        expand = ggplot2::expansion(add = 0.375)
      ) +
      ggplot2::scale_y_continuous(
        labels = scales::label_percent(),
        # Headroom at the top for the totals; without it they are clipped at the
        # panel edge.
        expand = ggplot2::expansion(mult = c(0, 0.06))
      ) +
      ggplot2::labs(x = NULL, y = NULL, title = title) +
      ggplot2::theme_minimal() +
      ggplot2::theme(
        plot.title = ggplot2::element_text(hjust = 0.5, size = 13),
        axis.text.x = ggplot2::element_text(size = 9),
        axis.text.y = if (show_axis) {
          ggplot2::element_text()
        } else {
          ggplot2::element_blank()
        },
        # Ticks too, not just the text: leaving them reserves a strip of width
        # between the connector band and panel B's first column, so the ribbons
        # would stop short of the bars they point at.
        axis.ticks.y = if (show_axis) {
          ggplot2::element_line()
        } else {
          ggplot2::element_blank()
        },
        # The columns must reach the panel edges the band meets. The default
        # margin leaves a gutter on each side that the ribbons cannot cross.
        plot.margin = if (show_axis) {
          ggplot2::margin(5.5, 0, 5.5, 5.5)
        } else {
          ggplot2::margin(5.5, 5.5, 5.5, 0)
        },
        panel.grid.major.x = ggplot2::element_blank(),
        panel.grid.minor = ggplot2::element_blank()
      )
  }

  size_panel <- share_panel(
    "share_vessels",
    "n_unique_vessels",
    scales::label_comma(accuracy = 1),
    "AIS-broadcasting fleet size",
    show_axis = TRUE
  )
  # Tonnes to million tonnes: the source column is CO2 in tonnes despite the
  # _mt suffix, as the ~1.4e9 container-class figure in the totals makes plain.
  emissions_panel <- share_panel(
    "share_emissions",
    "emissions_co2_mt",
    function(x) paste0(round(x / 1e6), " Mt"),
    expression("AIS-broadcasting" ~ CO[2] ~ "emissions"),
    show_axis = FALSE
  )

  # Ribbons across the gap, tying each of the largest classes to itself in the
  # other panel. They anchor on the two columns that face the gap -- the last
  # year of A and the first year of B -- because those are the only ones whose
  # edges the band actually touches.
  #
  # The y extents must match where the panels actually draw each segment. Two
  # reversals compose to none: geom_col stacks in reverse factor-level order,
  # and the panels map `group` to fct_rev to undo that, so the drawn order is
  # plain level order with the first level at the bottom. The cumulative sum
  # therefore runs up the levels as given. Sorting descending instead flips the
  # band against the columns and every ribbon lands on the wrong segment.
  band_extent <- function(share_col, band_year) {
    fleet_data |>
      dplyr::filter(.data$year == band_year) |>
      dplyr::mutate(
        vessel_class = factor(.data$vessel_class, levels = class_levels)
      ) |>
      dplyr::arrange(as.integer(.data$vessel_class)) |>
      dplyr::mutate(
        upper = cumsum(.data[[share_col]]),
        lower = .data$upper - .data[[share_col]]
      ) |>
      dplyr::select(vessel_class, lower, upper)
  }

  earliest <- min(fleet_data$year)
  left_edge <- band_extent("share_vessels", latest)
  right_edge <- band_extent("share_emissions", earliest)

  # Every class gets a ribbon. Together they tile the band edge to edge, so the
  # gap reads as the whole fleet flowing from one panel to the other rather than
  # as a handful of selected classes over blank space.
  connectors <- dplyr::inner_join(
    left_edge,
    right_edge,
    by = "vessel_class",
    suffix = c("_left", "_right")
  )

  # Sankey ribbons rather than straight-edged quadrilaterals. Each edge follows a
  # logistic curve, so a ribbon leaves its column horizontally, turns through the
  # middle of the band and arrives horizontally at the other side. A straight
  # chord meets the columns at an angle instead, which reads as a wedge pointing
  # away from the bar rather than as a band flowing out of it.
  #
  # Drawn as a filled polygon traced along the top edge and back along the
  # bottom, so the ribbon's thickness varies smoothly between its two endpoint
  # widths. geom_curve would give only a line, with no width to carry the share.
  # The 0-1 curve is stretched over +/-`curve_steepness` because a logistic is
  # visually flat by then; a narrower window leaves a visible kink where the
  # ribbon meets the bars.
  curve_steepness <- 6

  sigmoid <- function(from, to, n = 80) {
    t <- seq(-curve_steepness, curve_steepness, length.out = n)
    from + (to - from) / (1 + exp(-t))
  }

  n_points <- 80

  ribbons <- connectors |>
    dplyr::rowwise() |>
    dplyr::reframe(
      vessel_class = .data$vessel_class,
      x = c(seq(0, 1, length.out = n_points), seq(1, 0, length.out = n_points)),
      y = c(
        sigmoid(.data$upper_left, .data$upper_right, n_points),
        rev(sigmoid(.data$lower_left, .data$lower_right, n_points))
      )
    )

  # Named ribbons, each anchored to the panel where that class is prominent:
  # the fleet-heavy classes read off panel A's edge, the emissions-heavy ones
  # off panel B's. Only these are labelled -- the remaining ribbons are too thin
  # to carry text, and the shared legend below still names every colour.
  #
  # The two lists are given explicitly rather than derived from which end of the
  # ribbon is thicker: they are an editorial choice about which classes the
  # figure calls out, and a derived rule would silently reassign a class the
  # moment its shares shifted between refreshes.
  left_labelled <- c("Passenger", "Fishing", "Cargo: general", "Tug")
  right_labelled <- c(
    "Cargo: bulk carrier",
    "Tanker: oil",
    "Cargo: container",
    "Tanker: chemical",
    "Cargo: ro ro",
    "Tanker: liquefied gas"
  )

  # Shorter names for the band only. The legend and the underlying data keep the
  # pipeline's own vocabulary, which is prefixed by group ("Cargo: ...") so the
  # classes sort together; inside the band that prefix is redundant and eats the
  # width the ribbons need.
  band_label <- c(
    # Wrapped: it is the longest of the left-hand names and the band is narrow
    # there, so on one line it runs past the ribbon it belongs to.
    "Cargo: general" = "General\ncargo",
    "Cargo: bulk carrier" = "Bulk carrier",
    "Tanker: oil" = "Oil tanker",
    "Cargo: container" = "Container",
    "Tanker: chemical" = "Chemical",
    "Cargo: ro ro" = "Ro ro cargo",
    "Tanker: liquefied gas" = "Liquified gas"
  )

  # `hjust` pins the text against the band's own edge, so a label sits just
  # inside the gap next to its panel rather than floating in the middle. The
  # small inset keeps it clear of the column border.
  label_inset <- 0.04

  # Each label sits on its own ribbon, at that ribbon's midpoint on the side it
  # is anchored to. Where neighbouring ribbons are too thin to hold their names
  # apart, the labels are pushed just far enough to stop overlapping and no
  # further: spacing the group evenly instead detaches every name from the band
  # it describes, which is worse than a little crowding.
  #
  # One upward pass: walk the labels in stacking order and lift any that falls
  # within `min_gap` of the one below it. Working bottom-up means each label is
  # only ever compared against a position already settled.
  declutter <- function(data, min_gap = 0.045) {
    n <- nrow(data)
    if (n < 2) {
      return(data)
    }
    data <- dplyr::arrange(data, .data$y)
    y <- data$y
    for (i in 2:n) {
      y[i] <- max(y[i], y[i - 1] + min_gap)
    }
    # The pass can push the top label past the band; shifting the whole group
    # down by the overshoot keeps the spacing while bringing it back inside.
    overshoot <- max(y) - 1
    if (overshoot > 0) {
      y <- y - overshoot
    }
    dplyr::mutate(data, y = y)
  }

  # Nudged off the exact midpoint, the left group downward and the right group
  # upward. Expressed as a fraction of each ribbon's own thickness rather than a
  # flat distance, so a thin ribbon gets a proportionally small shift and the
  # label stays on the band it names instead of drifting onto its neighbour.
  label_nudge <- 0.08

  connector_labels <- dplyr::bind_rows(
    connectors |>
      dplyr::filter(.data$vessel_class %in% left_labelled) |>
      dplyr::mutate(
        x = label_inset,
        hjust = 0,
        y = (.data$lower_left + .data$upper_left) /
          2 -
          label_nudge * (.data$upper_left - .data$lower_left)
      ) |>
      declutter(),
    connectors |>
      dplyr::filter(.data$vessel_class %in% right_labelled) |>
      dplyr::mutate(
        x = 1 - label_inset,
        hjust = 1,
        y = (.data$lower_right + .data$upper_right) /
          2 +
          label_nudge * (.data$upper_right - .data$lower_right)
      ) |>
      declutter()
  ) |>
    dplyr::mutate(
      label = dplyr::coalesce(
        band_label[as.character(.data$vessel_class)],
        as.character(.data$vessel_class)
      ),
      # Same rule as the percentages inside the bars, against the same palette:
      # white and bold on the saturated fills, plain grey on the pale ones. The
      # labels sit directly on their ribbons, so they face exactly the contrast
      # problem the bar labels do and should resolve it the same way.
      light_fill = relative_luminance(
        palette[as.character(.data$vessel_class)]
      ) >
        light_fill_luminance,
      label_color = ifelse(.data$light_fill, "grey45", "white"),
      label_face = ifelse(.data$light_fill, "plain", "bold"),
      label_size = ifelse(.data$light_fill, 3, 3.2)
    )

  connector_band <- ggplot2::ggplot() +
    ggplot2::geom_polygon(
      data = ribbons,
      ggplot2::aes(
        x = .data$x,
        y = .data$y,
        group = .data$vessel_class,
        fill = .data$vessel_class
      ),
      # Near-solid. The ribbons tile the whole gap, so a low alpha left the band
      # washed out against the columns and the thinner classes faded into the
      # background rather than tracking across. Held just below 1 so the band
      # still reads as a link between the panels rather than as a third panel of
      # its own. The hairline border is the same white separator the stacked
      # columns use, which keeps neighbouring thin ribbons from merging.
      alpha = 1,
      color = "white",
      linewidth = 0.2
    ) +
    # Placed outright rather than repelled: declutter has already resolved the
    # overlaps in y, and a repel pass would drift the labels off the ribbons it
    # deliberately kept them on.
    ggplot2::geom_text(
      data = connector_labels,
      ggplot2::aes(
        x = .data$x,
        y = .data$y,
        label = .data$label,
        hjust = .data$hjust,
        color = .data$label_color,
        fontface = .data$label_face,
        size = .data$label_size
      ),
      lineheight = 0.9
    ) +
    ggplot2::scale_color_identity() +
    ggplot2::scale_size_identity() +
    ggplot2::scale_fill_manual(values = palette, drop = FALSE, guide = "none") +
    # A placeholder break so the invisible x-axis row is actually rendered and
    # occupies the same height as the panels' year axis.
    ggplot2::scale_x_continuous(
      expand = ggplot2::expansion(0),
      breaks = 0.5,
      labels = " "
    ) +
    # Must match the panels' y expansion exactly, or the ribbons meet the
    # columns at an offset and appear to point between two bands.
    ggplot2::scale_y_continuous(
      limits = c(0, 1),
      expand = ggplot2::expansion(mult = c(0, 0.06))
    ) +
    # theme_minimal rather than theme_void, with everything drawn in blank: the
    # band needs the same title row and x-axis row as the panels for cowplot to
    # align their plotting regions. theme_void removes those rows entirely, so
    # the band's 0-1 range would be stretched over the panels' full height --
    # title and axis included -- and every ribbon would meet its column at an
    # offset. Kept invisible so the structure costs nothing visually.
    ggplot2::labs(x = NULL, y = NULL, title = " ") +
    ggplot2::theme_minimal() +
    ggplot2::theme(
      plot.title = ggplot2::element_text(hjust = 0.5, size = 13),
      axis.text.x = ggplot2::element_text(size = 9, color = NA),
      axis.text.y = ggplot2::element_blank(),
      axis.ticks = ggplot2::element_blank(),
      panel.grid = ggplot2::element_blank(),
      # No horizontal margin, so the ribbons run edge to edge and meet the
      # columns rather than stopping short in the gutter.
      plot.margin = ggplot2::margin(5.5, 0, 5.5, 0)
    )

  # A single horizontal key under both panels rather than one legend each: the
  # two panels share a palette, so repeating it would suggest they don't.
  legend <- cowplot::get_plot_component(
    size_panel +
      # One row: with the support classes folded away there are few enough
      # entries to sit on a single line at this figure width, which reads as one
      # ordered ramp from Passenger through to Other rather than as two lists.
      ggplot2::guides(fill = ggplot2::guide_legend(nrow = 1, byrow = TRUE)) +
      ggplot2::theme(
        legend.position = "bottom",
        legend.text = ggplot2::element_text(size = 9)
      ),
    "guide-box-bottom",
    return_all = TRUE
  )

  # align = "h" makes cowplot match the panels' plotting regions rather than
  # their outer boxes, so the band's 0-1 range lines up with the columns'
  # despite the title above and the year axis below. The band carries no title
  # or axis of its own, so without this it would float relative to the bars.
  panels <- cowplot::plot_grid(
    size_panel + ggplot2::theme(legend.position = "none"),
    connector_band,
    emissions_panel + ggplot2::theme(legend.position = "none"),
    nrow = 1,
    align = "h",
    axis = "tb",
    # Wider than when the ribbons were unlabelled: the band now has to hold a
    # column of class names against each of its edges.
    rel_widths = c(1, 0.52, 1),
    labels = c("A", "", "B")
  )

  fleet_plot <- cowplot::plot_grid(
    panels,
    legend,
    ncol = 1,
    # Half the previous share: the key is one row now rather than two, so the
    # old allowance left a band of empty space under the panels.
    rel_heights = c(1, 0.08)
  ) +
    ggplot2::theme(
      plot.background = ggplot2::element_rect(fill = "white", color = NA)
    )

  if (!is.null(file_path)) {
    dir.create(dirname(file_path), showWarnings = FALSE, recursive = TRUE)
    ggplot2::ggsave(
      file_path,
      fleet_plot,
      width = width,
      height = height,
      dpi = 300,
      bg = "white"
    )
    return(file_path)
  }

  fleet_plot
}


# The single-year Sankey and the two year-series columns in one figure: the
# Sankey down the whole left side as panel A, and the fleet-size and CO2 series
# stacked on the right as B and C.
#
# B and C are the same two charts that plot_fleet_shares_by_year() draws as its
# panels, but standalone rather than facing each other across a connector band.
# That changes what each needs: the band is gone, so neither has an edge to
# reach and both carry their own percent axis, and stacking them vertically
# means only the lower one needs the year labels.
#
# Built by re-running the panel construction here rather than by pulling the
# panels out of the existing figure. Its share_panel() is a closure over that
# function's own data prep and is shaped for a side-by-side pair -- margins
# collapsed toward the band, one shared axis between them -- so reaching into it
# would couple two published figures that should be free to diverge.
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


# Panel A mirrored: the fleet-size years run newest to oldest, so its most recent
# column sits against the connector band. Otherwise identical to
# plot_fleet_shares_by_year(), and kept as a separate function rather than a flag
# on that one so the published figure cannot change by accident.
plot_fleet_shares_by_year_mirrored <- function(
  fleet_data,
  file_path = NULL,
  # A class is folded into "Other" only if it is small in both panels in every
  # year, matching the pie version's rule; folding per year instead would let a
  # class appear and disappear from the legend between columns.
  min_share = 0.005,
  # Segments below this are left unlabelled: the slabs are too thin for the text
  # to sit inside them without overlapping their neighbours.
  min_label_share = 0.04,
  # The three refrigerated-cargo spellings, merged under one name. They are the
  # same kind of vessel in three labels of the source vocabulary, so drawn apart
  # each is a thin sliver that says less than the group does.
  grouped_as_reefer = c(
    "Specialized reefer",
    "Container reefer",
    "Cargo: refrigerated"
  ),
  reefer_label = "Reefer",
  # Support and service classes folded into "Other" whatever their share. Named
  # explicitly rather than caught by a share rule, because "is this a support
  # vessel" is not something the shares can answer.
  grouped_as_other = c(
    "Supply vessel",
    "Patrol vessel",
    "Bunker",
    "Dredge non fishing",
    "Other not fishing"
  ),
  # Fills brighter than this get grey text instead of white. Sits between
  # Cargo: container (~0.69) and the next fill down, Tanker: oil (~0.55), so it
  # covers the pale yellows near the top of the emissions columns while leaving
  # the saturated oranges and reds on white.
  light_fill_luminance = 0.62,
  width = 14,
  height = 7,
  # Near the full category width, so consecutive years read as a continuous
  # series rather than as nine separate charts. Kept below 1 so a hairline of
  # background still separates one year from the next.
  bar_width = 0.92
) {
  small <- fleet_data |>
    dplyr::group_by(vessel_class) |>
    dplyr::summarise(
      small = max(.data$share_emissions) < min_share &
        max(.data$share_vessels) < min_share,
      .groups = "drop"
    )

  # The class ordering as it stands before the support classes are folded away.
  # The palette is built from this rather than from the surviving classes, so
  # every class keeps the colour it had when the support vessels were still
  # drawn separately: a ramp spread over a shorter list would hand each class a
  # different colour and silently recolour the whole figure.
  palette_levels <- fleet_data |>
    dplyr::left_join(small, by = "vessel_class") |>
    dplyr::mutate(
      # Reefer is formed here too, so it takes the ramp position its members
      # occupied rather than being appended as a new colour; the support classes
      # are deliberately left unfolded so every other class keeps its original
      # place in the ramp.
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
    # Re-aggregated before ranking: the size fold collapses several classes into
    # "Other", and ranking the un-summed rows would order that group by whichever
    # fragment happened to come first.
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

  fleet_data <- fleet_data |>
    dplyr::left_join(small, by = "vessel_class") |>
    dplyr::mutate(
      # Reefers first, and before the size rule: each of the three spellings is
      # individually small enough that the threshold would sweep them into
      # "Other" before they ever became a group.
      vessel_class = ifelse(
        .data$vessel_class %in% grouped_as_reefer,
        reefer_label,
        .data$vessel_class
      ),
      # Folded regardless of size: these are service and support vessels rather
      # than the cargo-carrying classes the figure is about, so they are grouped
      # even where a share threshold would have kept them.
      vessel_class = ifelse(
        .data$vessel_class %in% grouped_as_other,
        "Other",
        .data$vessel_class
      ),
      # The size rule runs last and must not re-split the groups just formed:
      # `small` was computed per original class, so a reefer spelling still
      # carries small = TRUE even though the merged group may not be small.
      vessel_class = ifelse(
        .data$small & !.data$vessel_class %in% c(reefer_label, "Other"),
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

  class_levels <- stacked_class_levels(fleet_data)

  # Subset rather than regenerate, so each surviving class keeps exactly the
  # colour it was assigned over the unfolded list.
  palette <- full_palette[class_levels]

  # The columns are normalised, so the year-to-year magnitude is invisible in the
  # bars themselves. `total_col` is the raw quantity behind each column, summed
  # per year and printed above it, so the composition and the level can be read
  # off the same figure. `total_fmt` formats it: counts are plain integers, CO2
  # is converted from tonnes to Mt because the raw figure runs to nine digits.
  # `show_axis = FALSE` drops the percent axis on the right-hand panel: both
  # panels run 0-100 % on the same scale, so the second copy is redundant and
  # only widens the gap the connectors have to span.
  share_panel <- function(
    share_col,
    total_col,
    total_fmt,
    title,
    show_axis,
    # Panel A runs newest-to-oldest so its 2025 column sits against the
    # connector band, facing panel B's 2025. The x scale is reversed rather
    # than the data re-sorted: the year is a discrete axis, so the drawing
    # order follows the factor levels and reversing them is the whole change.
    reverse_years = FALSE
  ) {
    totals <- fleet_data |>
      dplyr::group_by(.data$year) |>
      dplyr::summarise(
        total = sum(.data[[total_col]], na.rm = TRUE),
        .groups = "drop"
      ) |>
      dplyr::mutate(label = total_fmt(.data$total))

    panel_data <- fleet_data |>
      dplyr::mutate(
        vessel_class = factor(.data$vessel_class, levels = class_levels),
        # geom_col stacks in reverse level order, so reversing here puts the
        # first level at the top of the column, matching the legend read
        # top-to-bottom and the pies read clockwise from twelve.
        stack_order = forcats::fct_rev(.data$vessel_class),
        share = .data[[share_col]],
        label = ifelse(
          .data$share >= min_label_share,
          paste0(round(.data$share * 100), " %"),
          ""
        ),
        # White text disappears on the pale end of the Spectral ramp, so the
        # lightest fills get grey instead. Chosen by the fill's own luminance
        # rather than by naming the classes: the ramp is generated from however
        # many classes survive the "Other" folding, so which colours are pale
        # depends on the data and would drift if hardcoded.
        light_fill = relative_luminance(
          palette[as.character(.data$vessel_class)]
        ) >
          light_fill_luminance,
        label_color = ifelse(.data$light_fill, "grey45", "white"),
        # Plain weight on the pale fills. Bold is there to hold white text
        # against a saturated colour; grey on a light fill does not need the
        # extra weight, and bolding it only makes the lighter tone look heavier
        # than the white labels around it.
        label_face = ifelse(.data$light_fill, "plain", "bold"),
        # A shade smaller on the pale fills. Bold white text on a saturated
        # colour tightens visually, so at one point size the plain grey reads
        # as the larger of the two; trimming it evens them out optically.
        label_size = ifelse(.data$light_fill, 3, 3.2)
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
      # Same position_stack as the bars, so a label always lands on its own
      # segment rather than on a hand-computed cumulative position. Colour and
      # weight are mapped, not set: both vary per segment (see label_color
      # above), and constants would apply one style to every label.
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
      # identity, so label_size is taken as the literal text size in mm rather
      # than as a value to be rescaled onto a size range.
      ggplot2::scale_size_identity() +
      # Its own data frame, one row per year: mapped through the stacked layer's
      # data it would be drawn once per class and print the total on top of
      # itself as many times as there are segments.
      ggplot2::geom_text(
        data = totals,
        ggplot2::aes(x = factor(.data$year), y = 1, label = .data$label),
        inherit.aes = FALSE,
        vjust = -0.6,
        size = 3,
        color = "grey25"
      ) +
      ggplot2::scale_fill_manual(values = palette, drop = FALSE, name = NULL) +
      # Padding is a fixed fraction of a category rather than half a bar width:
      # tying it to bar_width would widen the outer margins every time the bars
      # are widened, which is the opposite of what widening them is for.
      ggplot2::scale_x_discrete(
        limits = if (reverse_years) rev else identity,
        expand = ggplot2::expansion(add = 0.375)
      ) +
      ggplot2::scale_y_continuous(
        labels = scales::label_percent(),
        # Headroom at the top for the totals; without it they are clipped at the
        # panel edge.
        expand = ggplot2::expansion(mult = c(0, 0.06))
      ) +
      ggplot2::labs(x = NULL, y = NULL, title = title) +
      ggplot2::theme_minimal() +
      ggplot2::theme(
        plot.title = ggplot2::element_text(hjust = 0.5, size = 13),
        axis.text.x = ggplot2::element_text(size = 9),
        axis.text.y = if (show_axis) {
          ggplot2::element_text()
        } else {
          ggplot2::element_blank()
        },
        # Ticks too, not just the text: leaving them reserves a strip of width
        # between the connector band and panel B's first column, so the ribbons
        # would stop short of the bars they point at.
        axis.ticks.y = if (show_axis) {
          ggplot2::element_line()
        } else {
          ggplot2::element_blank()
        },
        # The columns must reach the panel edges the band meets. The default
        # margin leaves a gutter on each side that the ribbons cannot cross.
        plot.margin = if (show_axis) {
          ggplot2::margin(5.5, 0, 5.5, 5.5)
        } else {
          ggplot2::margin(5.5, 5.5, 5.5, 0)
        },
        panel.grid.major.x = ggplot2::element_blank(),
        panel.grid.minor = ggplot2::element_blank()
      )
  }

  size_panel <- share_panel(
    "share_vessels",
    "n_unique_vessels",
    scales::label_comma(accuracy = 1),
    "AIS-broadcasting fleet size",
    show_axis = TRUE,
    reverse_years = TRUE
  )
  # Tonnes to million tonnes: the source column is CO2 in tonnes despite the
  # _mt suffix, as the ~1.4e9 container-class figure in the totals makes plain.
  emissions_panel <- share_panel(
    "share_emissions",
    "emissions_co2_mt",
    function(x) paste0(round(x / 1e6), " Mt"),
    expression("AIS-broadcasting" ~ CO[2] ~ "emissions"),
    show_axis = FALSE
  )

  # Ribbons across the gap, tying each of the largest classes to itself in the
  # other panel. They anchor on the two columns that face the gap -- the last
  # year of A and the first year of B -- because those are the only ones whose
  # edges the band actually touches.
  #
  # The y extents must match where the panels actually draw each segment. Two
  # reversals compose to none: geom_col stacks in reverse factor-level order,
  # and the panels map `group` to fct_rev to undo that, so the drawn order is
  # plain level order with the first level at the bottom. The cumulative sum
  # therefore runs up the levels as given. Sorting descending instead flips the
  # band against the columns and every ribbon lands on the wrong segment.
  band_extent <- function(share_col, band_year) {
    fleet_data |>
      dplyr::filter(.data$year == band_year) |>
      dplyr::mutate(
        vessel_class = factor(.data$vessel_class, levels = class_levels)
      ) |>
      dplyr::arrange(as.integer(.data$vessel_class)) |>
      dplyr::mutate(
        upper = cumsum(.data[[share_col]]),
        lower = .data$upper - .data[[share_col]]
      ) |>
      dplyr::select(vessel_class, lower, upper)
  }

  # Each anchor is the year of the column physically touching the band, so a
  # ribbon always meets the bar it describes. Reversing panel A put its earliest
  # year against the gap, where the unmirrored figure has its latest, so the
  # left anchor moves with it; panel B is unchanged and still meets its earliest
  # column. Both sides therefore read the earliest year here.
  earliest <- min(fleet_data$year)
  latest <- max(fleet_data$year)
  left_edge <- band_extent("share_vessels", earliest)
  right_edge <- band_extent("share_emissions", earliest)

  # Every class gets a ribbon. Together they tile the band edge to edge, so the
  # gap reads as the whole fleet flowing from one panel to the other rather than
  # as a handful of selected classes over blank space.
  connectors <- dplyr::inner_join(
    left_edge,
    right_edge,
    by = "vessel_class",
    suffix = c("_left", "_right")
  )

  # Sankey ribbons rather than straight-edged quadrilaterals. Each edge follows a
  # logistic curve, so a ribbon leaves its column horizontally, turns through the
  # middle of the band and arrives horizontally at the other side. A straight
  # chord meets the columns at an angle instead, which reads as a wedge pointing
  # away from the bar rather than as a band flowing out of it.
  #
  # Drawn as a filled polygon traced along the top edge and back along the
  # bottom, so the ribbon's thickness varies smoothly between its two endpoint
  # widths. geom_curve would give only a line, with no width to carry the share.
  # The 0-1 curve is stretched over +/-`curve_steepness` because a logistic is
  # visually flat by then; a narrower window leaves a visible kink where the
  # ribbon meets the bars.
  curve_steepness <- 6

  sigmoid <- function(from, to, n = 80) {
    t <- seq(-curve_steepness, curve_steepness, length.out = n)
    from + (to - from) / (1 + exp(-t))
  }

  n_points <- 80

  ribbons <- connectors |>
    dplyr::rowwise() |>
    dplyr::reframe(
      vessel_class = .data$vessel_class,
      x = c(seq(0, 1, length.out = n_points), seq(1, 0, length.out = n_points)),
      y = c(
        sigmoid(.data$upper_left, .data$upper_right, n_points),
        rev(sigmoid(.data$lower_left, .data$lower_right, n_points))
      )
    )

  # Named ribbons, each anchored to the panel where that class is prominent:
  # the fleet-heavy classes read off panel A's edge, the emissions-heavy ones
  # off panel B's. Only these are labelled -- the remaining ribbons are too thin
  # to carry text, and the shared legend below still names every colour.
  #
  # The two lists are given explicitly rather than derived from which end of the
  # ribbon is thicker: they are an editorial choice about which classes the
  # figure calls out, and a derived rule would silently reassign a class the
  # moment its shares shifted between refreshes.
  left_labelled <- c("Passenger", "Fishing", "Cargo: general", "Tug")
  right_labelled <- c(
    "Cargo: bulk carrier",
    "Tanker: oil",
    "Cargo: container",
    "Tanker: chemical",
    "Cargo: ro ro",
    "Tanker: liquefied gas"
  )

  # Shorter names for the band only. The legend and the underlying data keep the
  # pipeline's own vocabulary, which is prefixed by group ("Cargo: ...") so the
  # classes sort together; inside the band that prefix is redundant and eats the
  # width the ribbons need.
  band_label <- c(
    # Wrapped: it is the longest of the left-hand names and the band is narrow
    # there, so on one line it runs past the ribbon it belongs to.
    "Cargo: general" = "General\ncargo",
    "Cargo: bulk carrier" = "Bulk carrier",
    "Tanker: oil" = "Oil tanker",
    "Cargo: container" = "Container",
    "Tanker: chemical" = "Chemical",
    "Cargo: ro ro" = "Ro ro cargo",
    "Tanker: liquefied gas" = "Liquified gas"
  )

  # `hjust` pins the text against the band's own edge, so a label sits just
  # inside the gap next to its panel rather than floating in the middle. The
  # small inset keeps it clear of the column border.
  label_inset <- 0.04

  # Each label sits on its own ribbon, at that ribbon's midpoint on the side it
  # is anchored to. Where neighbouring ribbons are too thin to hold their names
  # apart, the labels are pushed just far enough to stop overlapping and no
  # further: spacing the group evenly instead detaches every name from the band
  # it describes, which is worse than a little crowding.
  #
  # One upward pass: walk the labels in stacking order and lift any that falls
  # within `min_gap` of the one below it. Working bottom-up means each label is
  # only ever compared against a position already settled.
  declutter <- function(data, min_gap = 0.045) {
    n <- nrow(data)
    if (n < 2) {
      return(data)
    }
    data <- dplyr::arrange(data, .data$y)
    y <- data$y
    for (i in 2:n) {
      y[i] <- max(y[i], y[i - 1] + min_gap)
    }
    # The pass can push the top label past the band; shifting the whole group
    # down by the overshoot keeps the spacing while bringing it back inside.
    overshoot <- max(y) - 1
    if (overshoot > 0) {
      y <- y - overshoot
    }
    dplyr::mutate(data, y = y)
  }

  # Nudged off the exact midpoint, the left group downward and the right group
  # upward. Expressed as a fraction of each ribbon's own thickness rather than a
  # flat distance, so a thin ribbon gets a proportionally small shift and the
  # label stays on the band it names instead of drifting onto its neighbour.
  label_nudge <- 0.08

  connector_labels <- dplyr::bind_rows(
    connectors |>
      dplyr::filter(.data$vessel_class %in% left_labelled) |>
      dplyr::mutate(
        x = label_inset,
        hjust = 0,
        y = (.data$lower_left + .data$upper_left) /
          2 -
          label_nudge * (.data$upper_left - .data$lower_left)
      ) |>
      declutter(),
    connectors |>
      dplyr::filter(.data$vessel_class %in% right_labelled) |>
      dplyr::mutate(
        x = 1 - label_inset,
        hjust = 1,
        y = (.data$lower_right + .data$upper_right) /
          2 +
          label_nudge * (.data$upper_right - .data$lower_right)
      ) |>
      declutter()
  ) |>
    dplyr::mutate(
      label = dplyr::coalesce(
        band_label[as.character(.data$vessel_class)],
        as.character(.data$vessel_class)
      ),
      # Same rule as the percentages inside the bars, against the same palette:
      # white and bold on the saturated fills, plain grey on the pale ones. The
      # labels sit directly on their ribbons, so they face exactly the contrast
      # problem the bar labels do and should resolve it the same way.
      light_fill = relative_luminance(
        palette[as.character(.data$vessel_class)]
      ) >
        light_fill_luminance,
      label_color = ifelse(.data$light_fill, "grey45", "white"),
      label_face = ifelse(.data$light_fill, "plain", "bold"),
      label_size = ifelse(.data$light_fill, 3, 3.2)
    )

  connector_band <- ggplot2::ggplot() +
    ggplot2::geom_polygon(
      data = ribbons,
      ggplot2::aes(
        x = .data$x,
        y = .data$y,
        group = .data$vessel_class,
        fill = .data$vessel_class
      ),
      # Near-solid. The ribbons tile the whole gap, so a low alpha left the band
      # washed out against the columns and the thinner classes faded into the
      # background rather than tracking across. Held just below 1 so the band
      # still reads as a link between the panels rather than as a third panel of
      # its own. The hairline border is the same white separator the stacked
      # columns use, which keeps neighbouring thin ribbons from merging.
      alpha = 1,
      color = "white",
      linewidth = 0.2
    ) +
    # Placed outright rather than repelled: declutter has already resolved the
    # overlaps in y, and a repel pass would drift the labels off the ribbons it
    # deliberately kept them on.
    ggplot2::geom_text(
      data = connector_labels,
      ggplot2::aes(
        x = .data$x,
        y = .data$y,
        label = .data$label,
        hjust = .data$hjust,
        color = .data$label_color,
        fontface = .data$label_face,
        size = .data$label_size
      ),
      lineheight = 0.9
    ) +
    ggplot2::scale_color_identity() +
    ggplot2::scale_size_identity() +
    ggplot2::scale_fill_manual(values = palette, drop = FALSE, guide = "none") +
    # A placeholder break so the invisible x-axis row is actually rendered and
    # occupies the same height as the panels' year axis.
    ggplot2::scale_x_continuous(
      expand = ggplot2::expansion(0),
      breaks = 0.5,
      labels = " "
    ) +
    # Must match the panels' y expansion exactly, or the ribbons meet the
    # columns at an offset and appear to point between two bands.
    #
    # No `limits` here. A scale limit FILTERS the data: the stacked shares sum
    # to 1 through a cumsum, so the topmost ribbon's upper edge lands on
    # 1.0000000000000002 rather than exactly 1, and every such vertex was being
    # dropped before drawing. That silently decapitated the top polygon -- the
    # "Other" ribbon lost its upper edge and rendered hanging below the 100 %
    # line instead of filling to it. coord_cartesian clips the view without
    # discarding rows, which is what a fixed range should do here.
    ggplot2::scale_y_continuous(
      expand = ggplot2::expansion(mult = c(0, 0.06))
    ) +
    ggplot2::coord_cartesian(ylim = c(0, 1), clip = "off") +
    # theme_minimal rather than theme_void, with everything drawn in blank: the
    # band needs the same title row and x-axis row as the panels for cowplot to
    # align their plotting regions. theme_void removes those rows entirely, so
    # the band's 0-1 range would be stretched over the panels' full height --
    # title and axis included -- and every ribbon would meet its column at an
    # offset. Kept invisible so the structure costs nothing visually.
    ggplot2::labs(x = NULL, y = NULL, title = " ") +
    ggplot2::theme_minimal() +
    ggplot2::theme(
      plot.title = ggplot2::element_text(hjust = 0.5, size = 13),
      axis.text.x = ggplot2::element_text(size = 9, color = NA),
      axis.text.y = ggplot2::element_blank(),
      axis.ticks = ggplot2::element_blank(),
      panel.grid = ggplot2::element_blank(),
      # No horizontal margin, so the ribbons run edge to edge and meet the
      # columns rather than stopping short in the gutter.
      plot.margin = ggplot2::margin(5.5, 0, 5.5, 0)
    )

  # A single horizontal key under both panels rather than one legend each: the
  # two panels share a palette, so repeating it would suggest they don't.
  legend <- cowplot::get_plot_component(
    size_panel +
      # One row: with the support classes folded away there are few enough
      # entries to sit on a single line at this figure width, which reads as one
      # ordered ramp from Passenger through to Other rather than as two lists.
      ggplot2::guides(fill = ggplot2::guide_legend(nrow = 1, byrow = TRUE)) +
      ggplot2::theme(
        legend.position = "bottom",
        legend.text = ggplot2::element_text(size = 9)
      ),
    "guide-box-bottom",
    return_all = TRUE
  )

  # align = "h" makes cowplot match the panels' plotting regions rather than
  # their outer boxes, so the band's 0-1 range lines up with the columns'
  # despite the title above and the year axis below. The band carries no title
  # or axis of its own, so without this it would float relative to the bars.
  panels <- cowplot::plot_grid(
    size_panel + ggplot2::theme(legend.position = "none"),
    connector_band,
    emissions_panel + ggplot2::theme(legend.position = "none"),
    nrow = 1,
    align = "h",
    axis = "tb",
    # Wider than when the ribbons were unlabelled: the band now has to hold a
    # column of class names against each of its edges.
    rel_widths = c(1, 0.52, 1),
    labels = c("A", "", "B")
  )

  fleet_plot <- cowplot::plot_grid(
    panels,
    legend,
    ncol = 1,
    # Half the previous share: the key is one row now rather than two, so the
    # old allowance left a band of empty space under the panels.
    rel_heights = c(1, 0.08)
  ) +
    ggplot2::theme(
      plot.background = ggplot2::element_rect(fill = "white", color = NA)
    )

  if (!is.null(file_path)) {
    dir.create(dirname(file_path), showWarnings = FALSE, recursive = TRUE)
    ggplot2::ggsave(
      file_path,
      fleet_plot,
      width = width,
      height = height,
      dpi = 300,
      bg = "white"
    )
    return(file_path)
  }

  fleet_plot
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
