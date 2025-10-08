# Tests

This directory contains automated tests for the paper-ocean-ghg repository.

## Running Tests

To run all tests:

```r
# From the project root directory
testthat::test_dir("tests/testthat")
```

Or using devtools:

```r
devtools::test()
```

## Test Structure

- `testthat.R` - Main test runner file (required by R CMD check)
- `testthat/` - Directory containing individual test files
  - `test-functions.R` - Tests for core functions in `r/functions.R`

## Writing New Tests

When adding new functionality:

1. Create a new test file in `tests/testthat/` with the naming convention `test-*.R`
2. Use descriptive test names that explain what is being tested
3. Test both successful cases and error conditions
4. Include edge cases and boundary conditions

Example test structure:

```r
test_that("function_name does what it should", {
  result <- function_name(valid_input)
  expect_equal(result, expected_output)
})

test_that("function_name validates inputs", {
  expect_error(function_name(invalid_input), "error message pattern")
})
```

## Current Test Coverage

### Core Functions (`r/functions.R`)
- ✅ `get_project_directory()` - Basic functionality tests
- ✅ `run_custom_bq_query()` - Input validation tests
- ✅ `pull_gfw_data_locally()` - Input validation tests
- ✅ `download_gfw_data()` - Input validation tests
- ✅ `run_gfw_query_and_save_table()` - Input validation tests
- ✅ `summarize_dark_fleet_ratios_spatial()` - Basic functionality tests
- ✅ `summarize_dark_fleet_model_results_emissions()` - Basic functionality tests

### Not Yet Tested
- ❌ BigQuery integration tests (require credentials and test data)
- ❌ Data validation functions in `model_validation.R`
- ❌ Analysis scripts in other R files
- ❌ SQL query validation

## Future Improvements

1. Add integration tests with mock BigQuery responses
2. Add tests for data validation logic
3. Implement test coverage reporting
4. Add continuous integration testing with GitHub Actions
5. Create fixtures for common test data scenarios
