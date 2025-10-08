# Tests for core functions in r/functions.R

library(testthat)

# Source the functions file
source(here::here("r/functions.R"))

# Test get_project_directory function ----

test_that("get_project_directory returns a valid path", {
  path <- get_project_directory()
  
  # Should return a character string
  expect_type(path, "character")
  
  # Should contain the project name
  expect_match(path, "paper-ocean-ghg")
  
  # Should not be empty
  expect_true(nchar(path) > 0)
})

test_that("get_project_directory adapts to different systems", {
  # This test verifies the function runs without error on current system
  expect_no_error(get_project_directory())
})

# Test input validation for BigQuery functions ----

test_that("run_custom_bq_query validates inputs", {
  # Missing query should throw error
  expect_error(
    run_custom_bq_query(billing_project = "test-project"),
    "query.*required"
  )
  
  # Empty query should throw error
  expect_error(
    run_custom_bq_query(query = "", billing_project = "test-project"),
    "query.*required.*cannot be empty"
  )
  
  # NULL query should throw error
  expect_error(
    run_custom_bq_query(query = NULL, billing_project = "test-project"),
    "query.*required"
  )
})

test_that("pull_gfw_data_locally validates inputs", {
  # Missing table name should throw error
  expect_error(
    pull_gfw_data_locally(
      bq_dataset = "test_dataset",
      billing_project = "test-project"
    ),
    "bq_table_name.*required"
  )
  
  # NULL table name should throw error
  expect_error(
    pull_gfw_data_locally(
      bq_table_name = NULL,
      bq_dataset = "test_dataset",
      billing_project = "test-project"
    ),
    "bq_table_name.*required"
  )
})

test_that("download_gfw_data validates inputs", {
  # Missing sql should throw error
  expect_error(
    download_gfw_data(
      bq_billing_project = "test-project",
      file_path = "/tmp/test.csv"
    ),
    "sql.*required"
  )
  
  # Empty sql should throw error
  expect_error(
    download_gfw_data(
      sql = "",
      bq_billing_project = "test-project",
      file_path = "/tmp/test.csv"
    ),
    "sql.*required.*cannot be empty"
  )
  
  # Missing file_path should throw error
  expect_error(
    download_gfw_data(
      sql = "SELECT * FROM table",
      bq_billing_project = "test-project"
    ),
    "file_path.*required"
  )
})

test_that("run_gfw_query_and_save_table validates inputs", {
  # Missing sql should throw error
  expect_error(
    run_gfw_query_and_save_table(
      bq_table_name = "test_table",
      bq_dataset = "test_dataset",
      billing_project = "test-billing",
      bq_project = "test-project"
    ),
    "sql.*required"
  )
  
  # Empty sql should throw error
  expect_error(
    run_gfw_query_and_save_table(
      sql = "",
      bq_table_name = "test_table",
      bq_dataset = "test_dataset",
      billing_project = "test-billing",
      bq_project = "test-project"
    ),
    "sql.*required.*cannot be empty"
  )
  
  # Missing bq_table_name should throw error
  expect_error(
    run_gfw_query_and_save_table(
      sql = "SELECT * FROM table",
      bq_dataset = "test_dataset",
      billing_project = "test-billing",
      bq_project = "test-project"
    ),
    "bq_table_name.*required"
  )
})

# Test summarize functions ----

test_that("summarize_dark_fleet_ratios_spatial handles valid input", {
  # Create minimal test data
  test_data <- data.frame(
    time = as.Date(c("2020-01-01", "2020-01-01", "2021-01-01")),
    fishing = c(TRUE, FALSE, TRUE),
    length_size_class_percentile = c(25, 50, 75),
    lat_bin = c(10, 10, 20),
    lon_bin = c(30, 30, 40),
    number_dark_detections = c(10, 20, 30),
    number_ais_detections = c(100, 200, 300)
  )
  
  result <- summarize_dark_fleet_ratios_spatial(test_data)
  
  # Should return a data frame
  expect_s3_class(result, "data.frame")
  
  # Should have expected columns
  expect_true("ratio_dark_to_ais_detections" %in% colnames(result))
  expect_true("fraction_tracked" %in% colnames(result))
  expect_true("year" %in% colnames(result))
})

test_that("summarize_dark_fleet_model_results_emissions handles YEAR aggregation", {
  # Create minimal test data
  test_data <- data.frame(
    time = as.Date(c("2020-01-01", "2020-06-01", "2021-01-01")),
    fishing = c(TRUE, FALSE, TRUE),
    length_size_class_percentile = c(25, 50, 75),
    lat_bin = c(10, 10, 20),
    lon_bin = c(30, 30, 40),
    emissions_co2_mt = c(100, 200, 300),
    emissions_co2_dark_mt = c(10, 20, 30),
    ratio_dark_to_ais_detections = c(0.1, 0.2, 0.3),
    global_time_ratio_dark_to_ais_detections = c(0.15, 0.25, 0.35),
    number_dark_detections = c(10, 20, 30),
    number_ais_detections = c(100, 200, 300),
    null_ratio = c(FALSE, FALSE, FALSE)
  )
  
  result <- summarize_dark_fleet_model_results_emissions(test_data, "YEAR")
  
  # Should return a data frame
  expect_s3_class(result, "data.frame")
  
  # Should have expected columns
  expect_true("year" %in% colnames(result))
  expect_true("pollutant" %in% colnames(result))
  expect_true("emissions_mt" %in% colnames(result))
  expect_true("dark" %in% colnames(result))
})

test_that("summarize_dark_fleet_model_results_emissions handles MONTH aggregation", {
  # Create minimal test data
  test_data <- data.frame(
    time = as.Date(c("2020-01-01", "2020-06-01", "2021-01-01")),
    fishing = c(TRUE, FALSE, TRUE),
    lat_bin = c(10, 10, 20),
    lon_bin = c(30, 30, 40),
    emissions_co2_mt = c(100, 200, 300),
    emissions_co2_dark_mt = c(10, 20, 30),
    length_size_class_percentile = c(25, 50, 75),
    ratio_dark_to_ais_detections = c(0.1, 0.2, 0.3),
    global_time_ratio_dark_to_ais_detections = c(0.15, 0.25, 0.35),
    number_dark_detections = c(10, 20, 30),
    number_ais_detections = c(100, 200, 300),
    null_ratio = c(FALSE, FALSE, FALSE)
  )
  
  result <- summarize_dark_fleet_model_results_emissions(test_data, "MONTH")
  
  # Should return a data frame
  expect_s3_class(result, "data.frame")
  
  # Should have expected columns
  expect_true("year_month" %in% colnames(result))
  expect_true("pollutant" %in% colnames(result))
  expect_true("emissions_mt" %in% colnames(result))
})
