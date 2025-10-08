#' Get the project directory path
#'
#' This function determines the appropriate base directory path based on the
#' operating system and machine name. It centralizes directory configuration
#' to avoid code duplication across multiple scripts.
#'
#' @return A string containing the full path to the project directory
#' @export
#' @examples
#' get_project_directory()
get_project_directory <- function() {
  data_directory_base <- if (Sys.info()["nodename"] %in% c("quebracho", "sequoia")) {
    "/home/emlab"
  } else if (Sys.info()["sysname"] == "Darwin") {
    "/Users/Shared/nextcloud/emLab"
  } else if (Sys.info()["sysname"] == "Windows") {
    "G:/Shared drives/nextcloud/emLab"
  } else {
    # For Linux machines, try to use an environment variable or default
    base_path <- Sys.getenv("EMLAB_DATA_DIR", "/home/your_username/Nextcloud")
    if (base_path == "/home/your_username/Nextcloud") {
      warning(
        "Using default Linux path. Please set EMLAB_DATA_DIR environment variable ",
        "or manually edit get_project_directory() in r/functions.R"
      )
    }
    base_path
  }
  
  glue::glue("{data_directory_base}/projects/current-projects/paper-ocean-ghg")
}

#' Run a BigQuery query and save results to a table
#'
#' This function executes a SQL query on BigQuery and saves the results to a
#' specified destination table. It requires special BigQuery permissions and
#' may incur significant costs for large queries.
#'
#' @param sql Character string containing the SQL query to execute
#' @param bq_table_name Name of the destination table
#' @param bq_dataset Name of the BigQuery dataset
#' @param billing_project Project ID for billing
#' @param bq_project Project ID where the table will be created
#' @param write_disposition How to handle existing tables. Default is 'WRITE_TRUNCATE'
#' @param ... Additional arguments (not currently used)
#'
#' @return BigQuery table metadata object
#' @export
run_gfw_query_and_save_table <- function(
  sql,
  bq_table_name,
  bq_dataset,
  billing_project,
  bq_project,
  # By default:  If the table already exists, BigQuery overwrites the table data
  # With "WRITE_APPEND": If the table already exists, BigQuery appends the data to the table.
  write_disposition = 'WRITE_TRUNCATE',
  ...
) {
  # Input validation
  if (missing(sql) || is.null(sql) || nchar(sql) == 0) {
    stop("Parameter 'sql' is required and cannot be empty")
  }
  if (missing(bq_table_name) || is.null(bq_table_name)) {
    stop("Parameter 'bq_table_name' is required")
  }
  
  tryCatch({
    # Specify table where query results will be saved
    bq_table <- bigrquery::bq_table(
      project = bq_project,
      table = bq_table_name,
      dataset = bq_dataset
    )

    # Run query and save on BQ. We don't pull this locally yet.
    bigrquery::bq_project_query(
      billing_project,
      sql,
      destination_table = bq_table,
      use_legacy_sql = FALSE,
      allowLargeResults = TRUE,
      write_disposition = write_disposition
    )

    # Return table metadata, for targets to know if something changed
    bigrquery::bq_table_meta(bq_table)
  }, error = function(e) {
    stop(sprintf(
      "BigQuery operation failed for table '%s':\n  %s",
      bq_table_name,
      conditionMessage(e)
    ))
  })
}

#' Pull GFW data locally from a BigQuery table
#'
#' Downloads all data from a specified BigQuery table to a local data frame.
#' Note: This loads the entire table into memory, which may cause issues with
#' very large tables.
#'
#' @param bq_table_name Name of the table to download
#' @param bq_dataset Name of the BigQuery dataset
#' @param billing_project Project ID for billing
#' @param ... Additional arguments (not currently used)
#'
#' @return A tibble containing the downloaded data
#' @export
pull_gfw_data_locally <- function(
  bq_table_name,
  bq_dataset,
  billing_project,
  ...
) {
  # Input validation
  if (missing(bq_table_name) || is.null(bq_table_name)) {
    stop("Parameter 'bq_table_name' is required")
  }
  
  tryCatch({
    bigrquery::bq_project_query(
      billing_project,
      glue::glue("SELECT * FROM world-fishing-827.{bq_dataset}.{bq_table_name}")
    ) |>
      bigrquery::bq_table_download(n_max = Inf)
  }, error = function(e) {
    stop(sprintf(
      "Failed to download table '%s' from dataset '%s':\n  %s",
      bq_table_name,
      bq_dataset,
      conditionMessage(e)
    ))
  })
}

#' Run a custom BigQuery query
#'
#' Executes a custom SQL query on BigQuery and downloads the results.
#'
#' @param query Character string containing the SQL query to execute
#' @param billing_project Project ID for billing
#' @param ... Additional arguments (not currently used)
#'
#' @return A tibble containing the query results
#' @export
run_custom_bq_query <- function(
  query,
  billing_project,
  ...
) {
  # Input validation
  if (missing(query) || is.null(query) || nchar(query) == 0) {
    stop("Parameter 'query' is required and cannot be empty")
  }
  
  tryCatch({
    job <- bigrquery::bq_project_query(
      billing_project,
      query
    )

    bigrquery::bq_table_download(job, n_max = Inf)
  }, error = function(e) {
    stop(sprintf(
      "BigQuery query execution failed:\n  %s\nQuery: %s",
      conditionMessage(e),
      substr(query, 1, 200)  # Show first 200 chars of query for debugging
    ))
  })
}

#' Summarize spatial dark fleet ratios
#'
#' Summarizes dark to AIS detection ratios by spatial bins (lat/lon), year,
#' vessel type, and size class.
#'
#' @param dark_fleet_model_results Data frame containing dark fleet model results
#'
#' @return A data frame with summarized ratios by spatial and temporal dimensions
#' @export
summarize_dark_fleet_ratios_spatial <- function(dark_fleet_model_results) {
  dark_fleet_model_results %>%
    # filter(null_ratio == FALSE) %>% # Only including those for which ratios could be calculated without using knn
    mutate(fishing = ifelse(fishing, "Fishing", "Non-fishing")) %>%
    mutate(year = lubridate::year(time)) %>%
    group_by(year, fishing, length_size_class_percentile, lat_bin, lon_bin) %>%
    summarize(across(
      c(number_dark_detections, number_ais_detections),
      ~ sum(., na.rm = TRUE)
    )) %>%
    ungroup() %>%
    mutate(
      ratio_dark_to_ais_detections = number_dark_detections /
        number_ais_detections,
      fraction_tracked = number_ais_detections /
        (number_ais_detections + number_dark_detections)
    )
}

#' Summarize dark fleet emissions by time and space
#'
#' Summarizes total emissions by time period (year or month), spatial location
#' (lat/lon), pollutant type, fishing status, and dark fleet status.
#'
#' @param dark_fleet_model_results Data frame containing dark fleet model results
#' @param time_extrapolation Time aggregation level: "YEAR" or "MONTH"
#'
#' @return A data frame with emissions summarized by specified dimensions
#' @export
summarize_dark_fleet_model_results_emissions <- function(
  dark_fleet_model_results,
  time_extrapolation = "YEAR"
) {
  if (time_extrapolation == "YEAR") {
    dark_fleet_model_results %>%
      mutate(year = lubridate::year(time)) %>%
      dplyr::select(
        -c(
          time,
          ratio_dark_to_ais_detections,
          global_time_ratio_dark_to_ais_detections,
          number_dark_detections,
          number_ais_detections,
          null_ratio
        )
      ) %>%
      pivot_longer(
        -c(year, lon_bin, lat_bin, fishing, length_size_class_percentile),
        names_to = "pollutant",
        values_to = "emissions_mt"
      ) %>%
      mutate(
        dark = ifelse(stringr::str_detect(pollutant, "dark"), TRUE, FALSE),
        pollutant = stringr::str_remove_all(pollutant, "emissions_") %>%
          stringr::str_remove_all("_mt") %>%
          stringr::str_remove_all("_dark") %>%
          stringr::str_to_upper()
      ) %>%
      group_by(
        year,
        lat_bin,
        lon_bin,
        pollutant,
        dark,
        fishing,
        length_size_class_percentile
      ) %>%
      summarize(emissions_mt = sum(emissions_mt, na.rm = TRUE)) %>%
      ungroup()
  } else if (time_extrapolation == "MONTH") {
    dark_fleet_model_results %>%
      mutate(
        year = lubridate::year(time),
        month = lubridate::month(time),
        year_month = lubridate::make_date(year = year, month = month, day = 1)
      ) %>%
      dplyr::select(
        -c(
          year,
          month,
          time,
          length_size_class_percentile,
          ratio_dark_to_ais_detections,
          global_time_ratio_dark_to_ais_detections,
          number_dark_detections,
          number_ais_detections,
          null_ratio
        )
      ) %>%
      pivot_longer(
        -c(year_month, lon_bin, lat_bin, fishing),
        names_to = "pollutant",
        values_to = "emissions_mt"
      ) %>%
      mutate(
        dark = ifelse(stringr::str_detect(pollutant, "dark"), TRUE, FALSE),
        pollutant = stringr::str_remove_all(pollutant, "emissions_") %>%
          stringr::str_remove_all("_mt") %>%
          stringr::str_remove_all("_dark") %>%
          stringr::str_to_upper()
      ) %>%
      group_by(year_month, lat_bin, lon_bin, pollutant, dark) %>%
      summarize(emissions_mt = sum(emissions_mt, na.rm = TRUE)) %>%
      ungroup()
  }
}

#' Download GFW data and save to a CSV file
#'
#' Executes a BigQuery query and saves the results to a CSV file in the
#' repository. Returns the file path for use with the targets package.
#'
#' @param sql Character string containing the SQL query to execute
#' @param bq_billing_project Project ID for billing
#' @param file_path Path where the CSV file should be saved
#' @param ... Additional arguments (not currently used)
#'
#' @return The file path where data was saved (for targets tracking)
#' @export
download_gfw_data <- function(sql, bq_billing_project, file_path, ...) {
  # Input validation
  if (missing(sql) || is.null(sql) || nchar(sql) == 0) {
    stop("Parameter 'sql' is required and cannot be empty")
  }
  if (missing(file_path) || is.null(file_path)) {
    stop("Parameter 'file_path' is required")
  }
  
  tryCatch({
    # Create directory if it doesn't exist
    dir.create(dirname(file_path), recursive = TRUE, showWarnings = FALSE)
    
    # Execute query and save results
    bigrquery::bq_project_query(
      bq_billing_project,
      query = sql
    ) |>
      bigrquery::bq_table_download(n_max = Inf) |>
      readr::write_csv(file_path)
    
    return(file_path)
  }, error = function(e) {
    stop(sprintf(
      "Failed to download and save data to '%s':\n  %s",
      file_path,
      conditionMessage(e)
    ))
  })
}

#' Combine EU Maritime Transport CO2 emissions data
#'
#' Accesses and combines annual CO2 emissions data from EU maritime transport.
#' Data is downloaded from https://mrv.emsa.europa.eu/ and each year (2018-2024)
#' is downloaded separately then combined.
#'
#' @param save_path Path where the combined CSV file should be saved
#'
#' @return NULL (function saves data to file as a side effect)
#' @export
combine_EU_data <- function(save_path) {
  all_files <- list.files(
    here::here("data/MRV/raw"),
    full.names = TRUE
  )

  combined <- purrr::map_df(all_files, function(year_tmp_file) {
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

  readr::write_csv(combined, save_path)
}
