#' Execute GFW Query and Save to BigQuery Table
#'
#' This function runs a SQL query against Global Fishing Watch data and saves 
#' the results to a specified BigQuery destination table. This operation requires 
#' special permissions and can be expensive to run frequently.
#'
#' @param sql Character string containing the SQL query to execute
#' @param bq_table_name Character string specifying the destination table name
#' @param bq_dataset Character string specifying the BigQuery dataset name
#' @param billing_project Character string specifying the Google Cloud billing project
#' @param bq_project Character string specifying the BigQuery project
#' @param write_disposition Character string specifying write behavior. 
#'   'WRITE_TRUNCATE' (default) overwrites existing data, 
#'   'WRITE_APPEND' appends to existing data
#' @param ... Additional arguments passed to bigrquery functions
#'
#' @return BigQuery table metadata object for tracking changes
#'
#' @details This function is designed for large-scale data operations and should
#' be used sparingly due to cost considerations. It executes the query and stores
#' results directly in BigQuery without downloading locally.
#'
#' @examples
#' \dontrun{
#' # Save AIS vessel data to a new table
#' run_gfw_query_and_save_table(
#'   sql = "SELECT * FROM ais_vessel_data WHERE year = 2023",
#'   bq_table_name = "ais_2023",
#'   bq_dataset = "ocean_emissions",
#'   billing_project = "my-project",
#'   bq_project = "world-fishing-827"
#' )
#' }
run_gfw_query_and_save_table <- function(
  sql,
  bq_table_name,
  bq_dataset,
  billing_project,
  bq_project,
  write_disposition = 'WRITE_TRUNCATE',
  ...
) {
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
}

#' Pull GFW Data Locally from BigQuery Table
#'
#' Downloads all data from a specified Global Fishing Watch BigQuery table
#' to the local R environment for analysis.
#'
#' @param bq_table_name Character string specifying the source table name
#' @param bq_dataset Character string specifying the BigQuery dataset name  
#' @param billing_project Character string specifying the Google Cloud billing project
#' @param ... Additional arguments passed to bigrquery functions
#'
#' @return A tibble containing all data from the specified table
#'
#' @details This function constructs a simple SELECT * query and downloads
#' the complete table contents. Use with caution for large tables as it
#' downloads all rows without limit.
#'
#' @examples
#' \dontrun{
#' # Download vessel characteristics data
#' vessel_data <- pull_gfw_data_locally(
#'   bq_table_name = "vessel_characteristics",
#'   bq_dataset = "ocean_emissions", 
#'   billing_project = "my-project"
#' )
#' }
pull_gfw_data_locally <- function(
  bq_table_name,
  bq_dataset,
  billing_project,
  ...
) {
  bigrquery::bq_project_query(
    billing_project,
    glue::glue("SELECT * FROM world-fishing-827.{bq_dataset}.{bq_table_name}")
  ) |>
    bigrquery::bq_table_download(n_max = Inf)
}

#' Execute Custom BigQuery Query
#'
#' Runs a custom SQL query against BigQuery and downloads the results
#' to the local R environment.
#'
#' @param query Character string containing the SQL query to execute
#' @param billing_project Character string specifying the Google Cloud billing project
#' @param ... Additional arguments passed to bigrquery functions
#'
#' @return A tibble containing the query results
#'
#' @details This function provides a simple interface for executing arbitrary
#' SQL queries against BigQuery. Results are downloaded without row limits.
#'
#' @examples
#' \dontrun{
#' # Query vessel emissions for a specific year
#' emissions_2023 <- run_custom_bq_query(
#'   query = "SELECT vessel_id, co2_emissions FROM emissions WHERE year = 2023",
#'   billing_project = "my-project"
#' )
#' }
run_custom_bq_query <- function(
  query,
  billing_project,
  ...
) {
  job <- bigrquery::bq_project_query(
    billing_project,
    query
  )

  bigrquery::bq_table_download(job, n_max = Inf)
}

#' Summarize Spatial Dark Fleet Detection Ratios
#'
#' Calculates spatial ratios of dark vessel detections to AIS detections,
#' aggregated by geographic bins, year, vessel type, and size class.
#'
#' @param dark_fleet_model_results A data frame containing dark fleet model results
#'   with columns: time, fishing, length_size_class_percentile, lat_bin, lon_bin,
#'   number_dark_detections, number_ais_detections
#'
#' @return A tibble with columns:
#'   \describe{
#'     \item{year}{Year extracted from time}
#'     \item{fishing}{Fishing activity status ("Fishing" or "Non-fishing")}
#'     \item{length_size_class_percentile}{Vessel size class percentile}
#'     \item{lat_bin, lon_bin}{Geographic bin coordinates}
#'     \item{number_dark_detections}{Total dark vessel detections}
#'     \item{number_ais_detections}{Total AIS detections}
#'     \item{ratio_dark_to_ais_detections}{Ratio of dark to AIS detections}
#'     \item{fraction_tracked}{Fraction of vessels tracked by AIS}
#'   }
#'
#' @details This function aggregates detection data spatially and temporally,
#' computing key metrics for understanding dark fleet distribution patterns.
#' The fraction_tracked represents the proportion of total vessel activity 
#' that is captured by AIS tracking systems.
#'
#' @examples
#' \dontrun{
#' # Summarize detection ratios from model results
#' spatial_ratios <- summarize_dark_fleet_ratios_spatial(dark_fleet_results)
#' }
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

#' Summarize Dark Fleet Model Results by Emissions
#'
#' Aggregates dark fleet model results by time period, converting wide-format
#' emission data to long format and summarizing by spatial and temporal units.
#'
#' @param dark_fleet_model_results A data frame containing dark fleet model results
#'   with emission columns for different pollutants (both AIS and dark estimates)
#' @param time_extrapolation Character string specifying temporal aggregation.
#'   Either "YEAR" (default) or "MONTH"
#'
#' @return A tibble with emission data in long format, containing:
#'   \describe{
#'     \item{year}{Year (and month if time_extrapolation = "MONTH")}
#'     \item{lat_bin, lon_bin}{Geographic bin coordinates}
#'     \item{pollutant}{Pollutant type (CO2, CH4, N2O, etc.) in uppercase}
#'     \item{dark}{Logical indicating if emissions are from dark (untracked) vessels}
#'     \item{fishing}{Fishing activity status}
#'     \item{length_size_class_percentile}{Vessel size class (for yearly aggregation)}
#'     \item{emissions_mt}{Total emissions in metric tons}
#'   }
#'
#' @details This function processes emission estimates from both AIS-tracked and
#' dark fleet models, reshaping the data for analysis and visualization. The
#' 'dark' flag distinguishes between tracked vessel emissions and estimated
#' emissions from untracked vessels. Pollutant names are standardized to uppercase.
#'
#' @examples
#' \dontrun{
#' # Aggregate emissions by year
#' yearly_emissions <- summarize_dark_fleet_model_results_emissions(
#'   dark_fleet_results, 
#'   time_extrapolation = "YEAR"
#' )
#' 
#' # Aggregate emissions by month
#' monthly_emissions <- summarize_dark_fleet_model_results_emissions(
#'   dark_fleet_results,
#'   time_extrapolation = "MONTH"
#' )
#' }
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

#' Download GFW Data and Save to Local File
#'
#' Executes a BigQuery SQL query against Global Fishing Watch data and saves
#' the results to a local CSV file.
#'
#' @param sql Character string containing the SQL query to execute
#' @param bq_billing_project Character string specifying the Google Cloud billing project
#' @param file_path Character string specifying the local file path for saving results
#' @param ... Additional arguments passed to bigrquery functions
#'
#' @return Character string of the file path (for use with targets pipeline)
#'
#' @details This function combines query execution and local file saving in a
#' single operation. It's designed for use with the targets workflow system,
#' returning the file path to enable dependency tracking.
#'
#' @examples
#' \dontrun{
#' # Download vessel data and save locally
#' file_path <- download_gfw_data(
#'   sql = "SELECT * FROM vessel_emissions WHERE year = 2023",
#'   bq_billing_project = "my-project",
#'   file_path = "data/vessel_emissions_2023.csv"
#' )
#' }
download_gfw_data <- function(sql, bq_billing_project, file_path, ...) {
  bigrquery::bq_project_query(
    bq_billing_project,
    query = sql
  ) |>
    bigrquery::bq_table_download(n_max = Inf) |>
    readr::write_csv(file_path)
  return(file_path)
}
