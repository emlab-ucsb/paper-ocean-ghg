# Set the targets project, since this repo has multiple targets project pipelines
# 01_gfw_data_pull requires special BigQuery permissions, and just downloads necessary data
# These lines are commented out for reproducibility - they can only be run with special BigQuery permisisons
# Sys.setenv(TAR_PROJECT = "01_gfw_data_pull")
# targets::tar_make()
# 02_quarto_notebook loads in all data and generates the figures and tables for the manuscript
Sys.setenv(TAR_PROJECT = "02_quarto_notebook")
targets::tar_make()
