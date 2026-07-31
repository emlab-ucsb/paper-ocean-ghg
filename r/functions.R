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
