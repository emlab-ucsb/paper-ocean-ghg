# Contributing to paper-ocean-ghg

Thank you for your interest in contributing to this project! This document provides guidelines and best practices for contributing to the codebase.

## Getting Started

1. Ensure you have R and RStudio installed
2. Clone the repository
3. Run `renv::restore()` to install all required packages
4. Set up your data directory path (see Configuration section below)

## Configuration

### Directory Paths

The repository uses a centralized configuration function for directory paths. To set up your local environment:

#### Option 1: Use Environment Variable (Recommended for Linux users)
```bash
export EMLAB_DATA_DIR="/path/to/your/data/directory"
```

Add this to your `~/.bashrc` or `~/.zshrc` for persistence.

#### Option 2: Use Default Paths
The code automatically detects your system and uses appropriate defaults:
- Mac OS: `/Users/Shared/nextcloud/emLab`
- Windows: `G:/Shared drives/nextcloud/emLab`
- Linux: Set `EMLAB_DATA_DIR` environment variable

### BigQuery Authentication

For scripts that access BigQuery:
1. Ensure you have the necessary GCP credentials
2. Authenticate using `bigrquery::bq_auth()`
3. Set your billing project appropriately

## Code Quality Standards

### R Code Style

1. **Use tidyverse style guide**: Follow the [tidyverse style guide](https://style.tidyverse.org/)
2. **Function naming**: Use `snake_case` for functions and variables
3. **Line length**: Keep lines under 80 characters when possible
4. **Documentation**: Add roxygen2 documentation to all functions

### Documentation Requirements

All functions must include roxygen2 documentation with:
- `@param` for each parameter
- `@return` describing the return value
- `@export` if the function should be exported
- A description of what the function does
- Examples if appropriate

Example:
```r
#' Calculate vessel emissions
#'
#' This function calculates CO2 emissions for a vessel based on
#' engine power and operating hours.
#'
#' @param power_kw Engine power in kilowatts
#' @param hours Operating hours
#' @param fuel_type Type of fuel used
#'
#' @return Numeric value of CO2 emissions in metric tons
#' @export
#' @examples
#' calculate_emissions(5000, 24, "diesel")
calculate_emissions <- function(power_kw, hours, fuel_type) {
  # Implementation
}
```

### Error Handling

All functions that interact with external systems (BigQuery, file I/O) must:
1. Validate input parameters
2. Use `tryCatch()` for error handling
3. Provide informative error messages

Example:
```r
my_function <- function(input_param) {
  # Input validation
  if (missing(input_param) || is.null(input_param)) {
    stop("Parameter 'input_param' is required")
  }
  
  # Error handling
  tryCatch({
    # Main logic
  }, error = function(e) {
    stop(sprintf("Operation failed: %s", conditionMessage(e)))
  })
}
```

## Testing

### Writing Tests

1. All new functions should have corresponding tests in `tests/testthat/`
2. Test file naming: `test-<module>.R` (e.g., `test-functions.R`)
3. Use descriptive test names with `test_that()`
4. Test both success and failure cases

Example test:
```r
test_that("function_name handles valid input correctly", {
  result <- function_name(valid_input)
  expect_equal(result, expected_output)
  expect_type(result, "numeric")
})

test_that("function_name validates inputs", {
  expect_error(function_name(NULL), "required")
  expect_error(function_name(""), "cannot be empty")
})
```

### Running Tests

```r
# Run all tests
testthat::test_dir("tests/testthat")

# Or use devtools
devtools::test()
```

## Workflow Guidelines

### Before Making Changes

1. Create a new branch for your work
2. Review existing code and tests
3. Understand the targets pipeline if your changes affect workflows

### Making Changes

1. **Keep changes minimal**: Make the smallest changes necessary to achieve your goal
2. **One logical change per commit**: Don't mix unrelated changes
3. **Remove debug code**: No `View()`, `browser()`, or similar debugging calls
4. **Test your changes**: Ensure existing tests pass and add new tests
5. **Update documentation**: Keep documentation in sync with code changes

### Code Review Checklist

Before submitting changes, verify:
- [ ] All tests pass
- [ ] New code has tests
- [ ] Functions have roxygen2 documentation
- [ ] No debug code (View(), browser(), print() statements)
- [ ] No commented-out code without explanation
- [ ] Input validation for all functions
- [ ] Error handling for external operations
- [ ] Code follows style guide
- [ ] No hardcoded paths or credentials

### Commit Messages

Write clear, descriptive commit messages:
```
Brief description of change (50 chars or less)

More detailed explanation if needed. Describe what changed and why,
not how (the code shows how). Wrap at 72 characters.

- Bullet points are okay
- Reference issues: Fixes #123
```

## Common Pitfalls to Avoid

1. **Don't use `setwd()`**: Use relative paths or the `here` package
2. **Don't hardcode paths**: Use the `get_project_directory()` function
3. **Don't load redundant packages**: `tidyverse` includes `dplyr`, `tidyr`, `ggplot2`, etc.
4. **Don't use `rm.na`**: The correct parameter is `na.rm`
5. **Don't leave `View()` in code**: It breaks non-interactive execution
6. **Don't ignore warnings**: Investigate and fix them

## File Organization

```
paper-ocean-ghg/
├── r/                      # R scripts
│   ├── functions.R         # Core shared functions
│   ├── model_validation.R  # Model validation code
│   └── ...
├── sql/                    # SQL queries
├── tests/                  # Test suite
│   ├── testthat/          # Individual test files
│   └── README.md          # Testing documentation
├── data/                   # Data files (not in git)
├── _targets_*.R           # Targets pipeline definitions
└── README.md              # Main documentation
```

## SQL Guidelines

1. **Use consistent formatting**: Uppercase keywords, consistent indentation
2. **Use meaningful table aliases**: Not just `a`, `b`, `c`
3. **Add comments**: Explain complex logic or business rules
4. **Use parameters**: Use `{variable}` syntax for template variables
5. **Avoid SELECT ***: Explicitly list needed columns

## Getting Help

- Check the [README.md](README.md) for setup instructions
- Review [CODE_REVIEW.md](CODE_REVIEW.md) for common issues and best practices
- Ask questions in issues or pull requests
- Review existing code for examples

## Additional Resources

- [tidyverse style guide](https://style.tidyverse.org/)
- [testthat documentation](https://testthat.r-lib.org/)
- [roxygen2 documentation](https://roxygen2.r-lib.org/)
- [targets package](https://docs.ropensci.org/targets/)
- [R packages book](https://r-pkgs.org/)

Thank you for contributing! 🎉
