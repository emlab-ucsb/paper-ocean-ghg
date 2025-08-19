# paper-ocean-ghg

Code for the paper on quantifying ocean greenhouse gas emissions from the global fishing fleet, including both AIS-tracked and dark (untracked) vessels.

## Project Overview

This repository contains the complete analysis pipeline for estimating global maritime greenhouse gas emissions, with a focus on fishing vessels. The study combines Automatic Identification System (AIS) data with satellite-based dark vessel detection to provide comprehensive emission estimates.

### Key Features

- **AIS Data Processing**: Analysis of Global Fishing Watch vessel tracking data
- **Dark Fleet Modeling**: Estimation of emissions from untracked vessels using machine learning
- **Emission Calculations**: Comprehensive GHG emission estimates (CO₂, CH₄, N₂O, etc.)
- **Spatial Analysis**: Global mapping of maritime emissions at high resolution
- **Model Validation**: Comparison with vessel registry data and emission factors

### Methodology

1. **Data Integration**: Combines AIS vessel tracking data with satellite-based dark vessel detections
2. **Emission Modeling**: Uses Random Forest models to predict vessel characteristics and emissions
3. **Spatial Extrapolation**: Estimates total emissions including dark fleet contributions
4. **Validation**: Validates results against vessel registry and operational data

## Repository Structure

```
paper-ocean-ghg/
├── r/                          # R analysis scripts
│   ├── functions.R             # Core utility functions
│   ├── model.R                 # Machine learning model development
│   ├── model_validation.R      # Model validation and testing
│   ├── 00_pull_gfw_data.R     # Data extraction scripts
│   └── ...                     # Additional analysis scripts
├── qmd/                        # Quarto documents and notebooks
│   ├── quarto_notebook.qmd     # Main analysis notebook
│   └── .vdoc.r                 # Document processing script
├── sql/                        # BigQuery SQL scripts
├── data/                       # Data storage (processed datasets)
├── figures/                    # Generated figures and plots
├── _targets_01_gfw_data_pull.R # Data pipeline workflow
├── _targets_02_quarto_notebook.R # Analysis pipeline workflow
└── _targets.yaml               # Pipeline configuration
```

## Data Sources

- **Global Fishing Watch (GFW)**: AIS vessel tracking and vessel characteristics
- **Satellite Data**: Dark vessel detection from various satellite sources
- **Vessel Registries**: Ship specifications and operational parameters
- **Emission Factors**: IMO and other regulatory emission factor databases

## Reproducibility  

### Package Management  

To manage package dependencies, we use the `renv` package. When you first clone this repo onto your machine, run `renv::restore()` to ensure you have all correct package versions installed in the project. Please see the [renv website](https://rstudio.github.io/renv/articles/renv.html) for more information. Also, ensure that you have R Studio set up to use the Posit Public Package Manager (see [here](https://packagemanager.posit.co/client/#/repos/cran/setup) for instructions, and [here](https://www.pipinghotdata.com/posts/2024-09-16-ease-renvrestore-by-updating-your-repositories-to-p3m/) for why this is important).

### Workflow Execution

This project uses the `targets` package for reproducible workflow management with two main pipelines:

1. **Data Pipeline** (`01_gfw_data_pull`): Extracts and processes raw data from BigQuery
2. **Analysis Pipeline** (`02_quarto_notebook`): Performs analysis and generates outputs

To run the complete analysis:

```r
# Install dependencies
renv::restore()

# Run data pipeline
targets::tar_make(names = "01_gfw_data_pull")

# Run analysis pipeline  
targets::tar_make(names = "02_quarto_notebook")
```

### BigQuery Setup

This project requires access to Global Fishing Watch data stored in BigQuery. You'll need:

- Google Cloud Platform account with BigQuery access
- Appropriate billing project setup
- Permissions to access GFW datasets

Set your billing project in the pipeline configuration files.
