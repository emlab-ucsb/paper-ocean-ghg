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

Main text figures (Figures 1–16) and supplementary figures (Figures S1–S7, S4) are generated by `qmd/quarto_notebook.qmd` and saved as PNGs in `figures/`. Key figures include:

- **Figure 1:** Annual CO₂ emissions time series by data source with spatial map
- **Figure 2:** Monthly time series and spatial distribution by fleet and vessel type
- **Figure 3:** AIS data richness — emissions by vessel type, country, and activity type
- **Figure 4:** Emissions by ocean basin and comparison to EDGAR inventories
- **Figure 5:** Registered data validation (model vs observed emissions)
- **Figure 6:** EU MRV validation
- **Figures 7–16:** Non-broadcasting vessel model methods and diagnostics

### Tables (10 total)

LaTeX table files are written to `tables/` and included in `main.tex`:

- Inventory comparison, social cost of GHG emissions, model performance metrics, emissions by fleet/pollutant, AIS underestimation summary, emissions by ocean, emissions by data source, MRV validation, non-CO₂ linear model coefficients, and model feature data sources.

## Reproducing the analysis

### Prerequisites

- **R ≥ 4.5.1**
- **Quarto** (for rendering the notebook)
- A LaTeX distribution (for compiling `main.tex`)
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
1. Load all CSV datasets from `data/gfw/` and external sources
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