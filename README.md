# paper-ocean-ghg

Reproducibility repository for:

**"Quantifying comprehensive marine vessel emissions using satellite data fusion"**

McDonald, G., Carbó-Mestre, P., Deschenes, O., Bone, J., Cagua, E.F., Hughes, A., Kroodsma, D., Paolo, F.S., Powell, M., Wei, Z., & Costello, C.

Environmental Markets Lab (emLab), UC Santa Barbara & Global Fishing Watch

## Overview

This repository contains the code and data pipeline to reproduce all figures, tables, and in-text statistics in the manuscript. The analysis quantifies global marine vessel emissions of CO₂ and eight other pollutants (CH₄, N₂O, CO, NOₓ, SOₓ, PM₂.₅, PM₁₀, VOCs) from 2017 through 2024 by fusing AIS vessel tracking data with Sentinel-1 SAR vessel detections.

## Repository structure

```
paper-ocean-ghg/
│
├── main.tex                          # Manuscript source (Nature journal format)
├── bibliography.bib                  # BibTeX references
├── sn-jnl.cls / sn-nature.bst       # Nature journal LaTeX class and bibliography style
│
├── run.r                             # Entry point: runs the full targets pipeline
├── _targets.yaml                     # Configures two targets pipeline projects
├── _targets_01_gfw_data_pull.R       # Pipeline 1: download data from BigQuery
├── _targets_02_quarto_notebook.R     # Pipeline 2: load data + render Quarto notebook
│
├── r/
│   └── functions.R                   # Helper functions (BigQuery download, MRV data processing)
│
├── sql/                              # BigQuery SQL queries (23 queries)
│   ├── n_unique_vessels.sql          # Count of unique AIS-broadcasting vessels
│   ├── n_ais_messages.sql            # Count of AIS messages with emissions data
│   ├── annual_emissions_all_pollutants.sql  # Annual emissions by pollutant and fleet
│   ├── monthly_aggregated_time_series.sql   # Monthly CO₂ by fleet, fishing, footprint
│   ├── total_spatial_emissions_by_pollutant.sql  # Spatial 1x1° emissions by pollutant
│   ├── annual_spatial_co2_emissions_ais_dark_by_fleet.sql  # Spatial CO₂ by fleet
│   ├── total_spatial_co2_emissions_by_ocean.sql  # CO₂ by ocean basin
│   ├── total_spatial_co2_emissions_dark_by_footprint.sql  # Dark emissions by S1 coverage
│   ├── total_monthly_emissions_by_pollutant.sql  # Monthly total emissions all pollutants
│   ├── annual_global_emissions_by_receiver_type.sql  # Emissions by AIS receiver type
│   ├── annual_global_emissions_by_receiver_type_and_flag.sql  # By receiver type + flag
│   ├── annual_spatial_emissions_by_receiver_type.sql  # Spatial by receiver type
│   ├── port_visit_co2_emissions_by_country.sql  # Port stay emissions by country
│   ├── trip_co2_emissions_by_from_to_countries.sql  # Trip emissions by origin/destination
│   ├── fraction_vessels_emissions_by_registry_info.sql  # Vessels by registry status
│   ├── ping_level_hours_distribution.sql  # AIS ping interval statistics
│   ├── n_s1_detections.sql           # Count of S1 vessel detections
│   ├── s1_time_series.sql            # Monthly S1 scene and detection statistics
│   ├── length_size_bin_distributions.sql  # Vessel length bins for AIS and S1
│   ├── number_s1_imaged_months_by_pixel.sql  # S1 imaging frequency per pixel
│   ├── registered_data_validation.sql  # Registered vessel validation data
│   ├── trip_emissions_for_mrv_validation.sql  # Trip emissions for EU MRV comparison
│   └── vessel_size_info.sql          # Vessel length and engine power data
│
├── qmd/
│   └── quarto_notebook.qmd          # Analysis notebook: generates all figures + tables
│
├── data/
│   ├── gfw/                         # GFW data (downloaded from BigQuery via pipeline 1)
│   │   ├── annual_emissions_all_pollutants.csv
│   │   ├── monthly_aggregated_time_series.csv
│   │   ├── total_spatial_emissions_by_pollutant.csv
│   │   ├── ... (27 CSV files total)
│   │   └── vessel_size_info.csv
│   ├── IEA_EDGAR_CO2_1970_2024/     # EDGAR v8.0 CO₂ emissions by sector (1970-2024)
│   │   └── IEA_EDGAR_CO2_1970_2024.xlsx
│   ├── MRV/                         # EU MRV emissions database (2018-2024)
│   │   ├── raw/                     # Raw annual Excel files from EMSA
│   │   ├── mrv_data_validation.csv  # Combined MRV data
│   │   └── trip_emissions_for_mrv_validation.csv
│   ├── oecd/                        # OECD experimental maritime transport emissions
│   │   └── annual_oecd_experimental_data.csv
│   ├── registered_validation_data/  # Registered vessel validation data (Taiwan, 2014)
│   │   └── registered_validation_data.csv
│   ├── World_Countries_Generalized_Shapefile/  # ESRI country boundaries for maps
│   └── data_sources.csv            # Model feature metadata table
│
├── figures/                         # Output PNG figures (24 total)
├── tables/                          # Output LaTeX tables (10 total)
│
├── renv/                            # renv package management
│   ├── activate.R
│   └── settings.json
├── renv.lock                        # Locked package versions for reproducibility
└── paper-ocean-ghg.Rproj           # RStudio/Positron project file
```

## Pipeline architecture

The analysis uses the [{targets}](https://docs.ropensci.org/targets/) pipeline framework with two sequential projects defined in `_targets.yaml`:

### Pipeline 1: `01_gfw_data_pull` (data acquisition)

**Script:** `_targets_01_gfw_data_pull.R`

Downloads analysis-ready datasets from Google BigQuery tables maintained by Global Fishing Watch. This pipeline executes 23 SQL queries and saves results as CSV files in `data/gfw/`. It requires authenticated access to the `emlab-gcp` BigQuery billing project and the `world-fishing-827` GFW data project.

**⚠️ This pipeline cannot be run without special BigQuery permissions.** All output CSV files are included in the repository so that Pipeline 2 can be run independently.

### Pipeline 2: `02_quarto_notebook` (analysis and figures)

**Script:** `_targets_02_quarto_notebook.R`

Loads all CSV files from `data/gfw/` and external datasets (EDGAR, OECD, MRV), then renders `qmd/quarto_notebook.qmd`. The Quarto notebook performs all data wrangling, generates all 24 figures (saved to `figures/`), generates all 10 LaTeX tables (saved to `tables/`), and computes all in-text statistics referenced in the manuscript.

## Key data sources

| Source | Description | Location |
|--------|-------------|----------|
| GFW AIS emissions | Vessel-level emissions from AIS tracking data | `data/gfw/` |
| GFW S1 dark fleet | Non-broadcasting vessel emissions from S1 SAR detections | `data/gfw/` |
| EDGAR v8.0 | Global CO₂ emissions by sector and country (1970-2024) | `data/IEA_EDGAR_CO2_1970_2024/` |
| OECD | Experimental maritime transport CO₂ estimates | `data/oecd/` |
| EU MRV | Published vessel-level emissions from EU monitoring program | `data/MRV/` |
| Registered data | Validation dataset from proprietary vessel registry | `data/registered_validation_data/` |
| ESRI Countries | Generalized world country boundaries shapefile | `data/World_Countries_Generalized_Shapefile/` |

## Outputs

### Figures (24 total)

All figures are generated by `qmd/quarto_notebook.qmd` and saved as PNGs in `figures/`.

**Results (Figures 1–4):**

| Figure | Label | Description |
|--------|-------|-------------|
| 1 | `fig-emissions-by-data-source-and-maps` | Annual CO₂ emissions time series by data source with spatial maps |
| 2 | `fig-spatial-temporal-richness-by-fleet-total-pseudolog` | Monthly CO₂ time series and spatial distribution by fleet and fishing/non-fishing |
| 3 | `fig-ais-data-richness` | CO₂ emissions by vessel type, country, and activity type |
| 4 | `fig-emissions-marine-ocean-other` | Emissions by ocean basin and comparison to EDGAR inventories |

**Methods (Figures 5–17):**

| Figure | Label | Description |
|--------|-------|-------------|
| 5 | `fig-framework-flowchart` | Conceptual flowchart for emissions estimation (static PNG, not code-generated) |
| 6 | `fig-registered-data-performance` | Registered vessel database validation (model vs observed daily CO₂) |
| 7 | `fig-mrv-performance` | EU MRV validation (model vs published annual CO₂) |
| 8 | `fig-map-fraction-months-imaged` | S1 imaging coverage map (% months imaged per pixel) |
| 9 | `fig-length-bin-distributions` | Vessel length bin distributions for AIS and S1 detections |
| 10 | `fig-ais-length-power-relationship` | Relationship between main engine power and vessel length |
| 11 | `fig-s1-coverage-time-series` | Monthly S1 scene, detection, and unmatched detection statistics |
| 12 | `fig-offshore-outside-footprint-training-testing-map` | Training/testing pixel split for simulated outside-footprint tests |
| 13 | `fig-pr-curves` | Precision-recall curves for detection classification model |
| 14 | `fig-roc-curves` | ROC curves for detection classification model |
| 15 | `fig-conf-mat` | Confusion matrices for detection classification model |
| 16 | `fig-feature-importance` | Feature importance for classification and regression models |
| 17 | `fig-spatial-coverage-footprint` | Spatial coverage of the non-broadcasting emissions model |

**Supplementary (Figures S1–S7):**

| Figure | Label | Description |
|--------|-------|-------------|
| S1 | `fig-pollutant-maps-qlog10` | Spatial maps of 2024 emissions for all pollutants |
| S2 | `fig-pollutant-time-series` | Monthly time series for all pollutants |
| S3 | `fig-annual-emissions-by-ocean-and-data-source` | Annual CO₂ by ocean and data source |
| S4 | `fig-inventory-comparison` | Comparison with other marine CO₂ emission inventories |
| S5 | `fig-annual-emissions-by-ais-receiver-type` | Annual emissions by AIS receiver type |
| S6 | `fig-annual-emissions-by-ais-receiver-type-top-flags` | Emissions by AIS receiver type for top 10 flags |
| S7 | `fig-co2-emissions-change-map-by-receiver-type` | Spatial change in CO₂ by AIS receiver type (2017–2024) |

### Tables (10 total)

LaTeX table files are generated by `qmd/quarto_notebook.qmd` and saved to `tables/` for inclusion in `main.tex`.

**Main text (Tables 1–4):**

| Table | File | Description |
|-------|------|-------------|
| 1 | `mrv_performance_results.tex` | EU MRV validation performance metrics |
| 2 | `data_sources.tex` | Model feature data sources |
| 3 | `all_performance_metrics_table.tex` | Non-broadcasting model performance metrics |
| 4 | `lm_other_gases_tidy_fit_stats.tex` | Non-CO₂ linear model coefficients |

**Supplementary (Tables S1–S6):**

| Table | File | Description |
|-------|------|-------------|
| S1 | `total_percent_change_by_fleet.tex` | Percent change in emissions by fleet (2017–2024) |
| S2 | `pollutant_ais_underestimation_overestimation_summary.tex` | AIS underestimation/overestimation summary by pollutant |
| S3 | `emissions_by_ocean_summary_tbl.tex` | Emissions summary by ocean basin |
| S4 | `emissions_by_data_source_summary_tbl.tex` | Emissions summary by data source |
| S5 | `annual_sc_fishing_non_fishing_tbl.tex` | Annual social cost of emissions by fishing/non-fishing |
| S6 | `inventory_comparison.tex` | Marine CO₂ inventory comparison data |

## Reproducing the analysis

### Prerequisites

- **R ≥ 4.5.1**
- **quarto** (for rendering the notebook)
- [Positron](https://positron.posit.co/) or RStudio IDE (recommended)

### Step 1: Clone the repository

```bash
git clone https://github.com/emlab-ucsb/paper-ocean-ghg.git
cd paper-ocean-ghg
```

### Step 2: Restore R packages

We use [{renv}](https://rstudio.github.io/renv/) for package management. On first use, restore all dependencies:

```r
renv::restore()
```

> **Tip:** Ensure your R session is configured to use the [Posit Public Package Manager](https://packagemanager.posit.co/client/#/repos/cran/setup) for faster binary package installation. See [this guide](https://www.pipinghotdata.com/posts/2024-09-16-ease-renvrestore-by-updating-your-repositories-to-p3m/) for why this is important.

### Step 3: Run the analysis

The entry point is `run.r`. Since Pipeline 1 (BigQuery data pull) requires special permissions, it is commented out. Pipeline 2 loads the pre-downloaded CSV data and renders the notebook:

```r
source("run.r")
```

This is equivalent to:

```r
Sys.setenv(TAR_PROJECT = "02_quarto_notebook")
targets::tar_make()
```

This will:
1. Load all CSV datasets from `data/gfw/` and other external sources
2. Render `qmd/quarto_notebook.qmd`
3. Save all figures to `figures/`
4. Save all LaTeX tables to `tables/`

## Checking pipeline status

To see which targets are up to date or not:

```r
Sys.setenv(TAR_PROJECT = "02_quarto_notebook")
targets::tar_outdated()
targets::tar_visnetwork()
```

## Helper functions

`r/functions.R` contains:

- `download_gfw_data()` — Executes a BigQuery SQL query and saves results in the repo as CSV. Note that this function can only be used by those who have special permissions to Global Fishing Watch data on BigQuery.
- `combine_EU_data()` — Reads and combines annual EU MRV Excel files (2018–2024) into a single tibble

## Licensing

This repo uses the[ Create Commons CC BY 4.0 license](https://creativecommons.org/licenses/by/4.0/deed.en).