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
    bigrquery::bq_table_download(n_max = Inf, bigint = "integer64") |>
    readr::write_csv(file_path)
  return(file_path)
}

# Function to access and combine CO2 emissions data from EU maritime transport
# Downloaded from https://mrv.emsa.europa.eu/# on July 10, 2025
# Each year is download separately for 2018-2024; we then combine them
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
