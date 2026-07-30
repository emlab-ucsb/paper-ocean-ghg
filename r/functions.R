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
summarize_cams_ship_co2 <- function(year, version, dataset_short_name = "cams-global-emission-inventories") {
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
  if (any(grepl("\\.(zip|tar|tar\\.gz|tgz)$", downloaded, ignore.case = TRUE))) {
    archive <- downloaded[grepl("\\.(zip|tar|tar\\.gz|tgz)$", downloaded, ignore.case = TRUE)][1]
    if (grepl("\\.zip$", archive, ignore.case = TRUE)) {
      utils::unzip(archive, exdir = download_dir)
    } else {
      utils::untar(archive, exdir = download_dir)
    }
  }

  nc_files <- list.files(download_dir, pattern = "\\.nc$", full.names = TRUE, recursive = TRUE)
  if (length(nc_files) == 0) {
    stop(
      "No NetCDF found for CAMS-GLOB-SHIP ", version, " ", year,
      ". Files returned: ", paste(basename(downloaded), collapse = ", ")
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
  dim_names <- vapply(nc$var[[emissions_variable]]$dim, function(d) d$name, character(1))
  time_axis <- which(dim_names == "time")
  lat_axis <- which(dim_names == lat_name)
  lon_axis <- which(dim_names == lon_name)

  if (length(lat_axis) != 1 || length(lon_axis) != 1) {
    stop("Could not locate lat/lon axes of ", emissions_variable, " in ", basename(nc_file))
  }

  n_slices <- if (length(time_axis) == 1) nc$var[[emissions_variable]]$dim[[time_axis]]$len else 1L
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
      "lat", "latitude", "lon", "longitude", "time",
      "lat_bnds", "lon_bnds", "time_bnds", "crs"
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
      "None of the expected axis names (", paste(options, collapse = ", "),
      ") found in ", basename(nc$filename)
    )
  }
  found[1]
}

# Area of each grid cell on a regular lat-lon grid, in m2. Cells are spherical
# zones, so area depends on latitude but not longitude. `lat_first` orients the
# result to match the slice being multiplied: lat x lon when TRUE, lon x lat
# otherwise.
cams_cell_area_m2 <- function(lat, lon, lat_first = FALSE, earth_radius_m = 6371007.181) {
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
  origin <- suppressWarnings(as.POSIXct(origin_text, tz = "UTC", tryFormats = c(
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%d %H:%M",
    "%Y-%m-%d"
  )))

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
  lat <- as.numeric(ncdf4::ncvar_get(nc, cams_axis_name(nc, c("lat", "latitude"))))
  lon <- as.numeric(ncdf4::ncvar_get(nc, cams_axis_name(nc, c("lon", "longitude"))))

  list(
    file = basename(nc_file),
    global_attributes = global_attributes,
    variables = names(nc$var),
    emissions_variable = emissions_variable,
    emissions_units = ncdf4::ncatt_get(nc, emissions_variable, "units")$value,
    emissions_long_name = ncdf4::ncatt_get(nc, emissions_variable, "long_name")$value,
    grid_resolution_deg = c(
      lon = abs(stats::median(diff(lon))),
      lat = abs(stats::median(diff(lat)))
    ),
    grid_dim = c(lon = length(lon), lat = length(lat)),
    n_time_slices = if ("time" %in% names(nc$dim)) nc$dim$time$len else NA_integer_
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
      "SEIM record ", record_id, " has no data for: ",
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
      paste(range(suppressWarnings(as.integer(available_sheets)), na.rm = TRUE), collapse = "-"),
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
  utils::download.file(query_url, destfile = destination, mode = "wb", quiet = TRUE)

  raw <- readr::read_csv(destination, show_col_types = FALSE)

  residence_total <- raw |>
    dplyr::filter(
      .data$METHODOLOGY == "EMISSIONS_SEEA",
      .data$VESSEL_EMISSIONS_SOURCE == "RES_TOTAL"
    )

  if (nrow(residence_total) == 0) {
    stop(
      "No EMISSIONS_SEEA / RES_TOTAL rows in the OECD response. The dataflow ",
      "dimensions may have changed; check ", query_url
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
  gfw_activity_file = file.path("data", "gfw", "annual_ais_activity_summary.csv"),
  icct_url = "https://theicct.org/wp-content/uploads/2025/04/supplemental_vf.xlsx"
) {
  download_dir <- file.path(tempdir(), "icct_comparison")
  dir.create(download_dir, showWarnings = FALSE, recursive = TRUE)
  on.exit(unlink(download_dir, recursive = TRUE), add = TRUE)

  destination <- file.path(download_dir, basename(icct_url))
  utils::download.file(icct_url, destfile = destination, mode = "wb", quiet = TRUE)

  icct <- purrr::map_dfr(readxl::excel_sheets(destination), function(sheet) {
    sheet_data <- readxl::read_excel(destination, sheet = sheet)
    class_column <- names(sheet_data)[1]
    classes <- !is.na(sheet_data[[class_column]]) &
      !grepl("^Note", sheet_data[[class_column]])
    identified <- classes & sheet_data[[class_column]] != "Unknown"
    total <- function(column, rows) {
      sum(suppressWarnings(as.numeric(sheet_data[[column]][rows])), na.rm = TRUE)
    }

    tibble::tibble(
      year = as.integer(sheet),
      icct_co2_mt = total("CO2 emissions (tonne)", classes),
      icct_distance_nm = total("Distance travelled (nm)", classes),
      icct_n_vessels = total("Number of ships", classes),
      icct_n_vessels_identified = total("Number of ships", identified)
    )
  })

  gfw <- readr::read_csv(gfw_activity_file, show_col_types = FALSE) |>
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
      # Intensity, kg CO2 per nautical mile
      gfw_intensity_kg_nm = .data$gfw_co2_mt * 1000 / .data$gfw_distance_nm,
      icct_intensity_kg_nm = .data$icct_co2_mt * 1000 / .data$icct_distance_nm,
      intensity_percent_difference = 100 *
        (.data$gfw_intensity_kg_nm / .data$icct_intensity_kg_nm - 1),
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
    purrr::map_dfr(hardcoded_series, dplyr::select, dplyr::all_of(inventory_columns))
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
normalize_inventory_series <- function(all_inventory_data, baseline_year = 2017L) {
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
  axis_max <- ceiling(max(all_inventory_data$emissions_co2_mt) / 0.25e9) * 0.25e9

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
