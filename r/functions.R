# This function pulls the necessary GFW data and stores it into a destination table
# This requires special permissions, and is also very expensive to run, so will not be done often
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

# This function pulls GFW data locally from a specific table
# This simply gets all data from the table
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

# Summarize spatial dark to AIS detection ratios by lat_bin, lon_bin, year, vessel type, and size class
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

# Summarize total emissions by time (year or month), lat, lon, pollutant, fishing/non-fishing and dark status
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

# Function to download GFW data and save it in repo
# Returns file path, for keeping track with targets
download_gfw_data <- function(sql, bq_billing_project, file_path, ...) {
  bigrquery::bq_project_query(
    bq_billing_project,
    query = sql
  ) |>
    bigrquery::bq_table_download(n_max = Inf) |>
    readr::write_csv(file_path)
  return(file_path)
}
