# This file is part of the standard testthat testing infrastructure
# It runs all tests when R CMD check is run

library(testthat)
library(glue)

test_check("paper-ocean-ghg")
