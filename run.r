# This repo has three targets pipelines. They run in dependency order - 01 -> 02
# -> 03 - and nothing ever points backwards: 02 consumes what 01 wrote, 03
# consumes what 01 and 02 wrote, and neither 01 nor 02 reads anything produced
# downstream of it.
#
# Only pipeline 03 is uncommented, because it is the only one that needs no
# credentials. Both upstream pipelines commit their outputs to the repo, so a
# fresh clone can render the manuscript without running either of them.

# 01_gfw_data_pull downloads the GFW datasets from BigQuery into data/gfw/.
# Commented out: it needs access to the emlab-gcp billing project and the
# world-fishing-827 GFW tables. Its CSVs are committed, so you do not need it.
# Sys.setenv(TAR_PROJECT = "01_gfw_data_pull")
# targets::tar_make()

# 02_inventories_comparison downloads the published emissions inventories
# (CAMS/STEAM, SEIM, ICCT, CEDS, EDGAR, OECD), puts them on a common schema, and
# writes the tidy CSVs the notebook reads back in. It needs no BigQuery access,
# but it does need a Copernicus Atmosphere Data Store token for the CAMS targets
# and pulls roughly 6 GB over the network. Commented out for the same reason as
# 01: its CSVs are committed. See the header of
# _targets_02_inventories_comparison.R before enabling it.
# Sys.setenv(TAR_PROJECT = "02_inventories_comparison")
# targets::tar_make()

# 03_quarto_notebook loads all of the committed data and generates the figures
# and tables for the manuscript. This one needs no credentials.
Sys.setenv(TAR_PROJECT = "03_quarto_notebook")
targets::tar_make()
