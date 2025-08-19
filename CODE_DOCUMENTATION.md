# Code Documentation Overview

This document provides a comprehensive overview of the code structure, data flow, and analytical methodology for the ocean greenhouse gas emissions research project.

## Project Architecture

### Data Pipeline Flow

```
BigQuery (GFW Data) → Data Extraction → Processing → Analysis → Outputs
                         ↓                ↓           ↓         ↓
                   _targets_01_       r/functions.R  model.R   figures/
                   gfw_data_pull.R         ↓           ↓      tables/
                         ↓            data/processed/  ↓      qmd/
                   CSV files            ↓         model_validation.R
                         ↓         _targets_02_        ↓
                   Analysis Pipeline  quarto_notebook.R ↓
                                         ↓         Validation
                                   Final Outputs
```

### Core Components

#### 1. Data Extraction Layer (`r/00_pull_gfw_data.R`, `_targets_01_gfw_data_pull.R`)
- **Purpose**: Extract raw data from Global Fishing Watch BigQuery datasets
- **Functions**: `run_gfw_query_and_save_table()`, `pull_gfw_data_locally()`
- **Outputs**: Raw CSV files in `data/gfw/` directory
- **Dependencies**: BigQuery permissions, GFW data access

#### 2. Data Processing Layer (`r/functions.R`)
- **Purpose**: Core utility functions for data transformation and analysis
- **Key Functions**:
  - `summarize_dark_fleet_ratios_spatial()`: Spatial aggregation of detection ratios
  - `summarize_dark_fleet_model_results_emissions()`: Emission data transformation
  - `download_gfw_data()`: Data extraction with local storage
- **Outputs**: Processed datasets for modeling

#### 3. Modeling Layer (`r/model.R`)
- **Purpose**: Machine learning models for emission prediction
- **Methodology**: Random Forest regression with tidymodels framework
- **Features**: Vessel characteristics (fishing status, size, operational hours, speed)
- **Target**: Total CO₂ emissions (AIS + dark fleet estimates)
- **Validation**: 80/20 train-test split with performance metrics

#### 4. Validation Layer (`r/model_validation.R`, `r/snp_validation.R`)
- **Purpose**: Model validation against independent datasets
- **Methods**: 
  - Cross-validation with vessel registry data
  - Energy consumption calculations with correction factors
  - Statistical performance assessment
- **Key Function**: `calculate_main_engine_energy_use_kwh()` with environmental corrections

#### 5. Analysis Layer (`_targets_02_quarto_notebook.R`, `qmd/quarto_notebook.qmd`)
- **Purpose**: Final analysis, visualization, and reporting
- **Outputs**: Publication-ready figures, tables, and analysis document
- **Dependencies**: All processed data from previous layers

## Data Sources and Formats

### Input Data
- **AIS Data**: Vessel tracking data from Global Fishing Watch BigQuery
- **Dark Fleet Data**: Satellite-based vessel detection results
- **Vessel Registry**: Ship characteristics and specifications
- **Emission Factors**: Regulatory databases (IMO, etc.)

### Intermediate Data
- **Processed CSV Files**: Located in `data/processed/`
- **Model Objects**: Stored in targets cache
- **Validation Results**: Statistical summaries and diagnostics

### Output Data
- **Figures**: Publication-quality plots in `figures/`
- **Tables**: Summary statistics in `tables/`
- **Reports**: Rendered Quarto documents

## Key Algorithms and Methods

### 1. Dark Fleet Estimation
- **Approach**: Combine AIS tracking with satellite-based dark vessel detection
- **Spatial Resolution**: 0.1° × 0.1° grid cells
- **Temporal Resolution**: Monthly and annual aggregations
- **Interpolation**: K-Nearest Neighbors for data-sparse regions

### 2. Emission Calculations
- **Energy Model**: `calculate_main_engine_energy_use_kwh()`
- **Correction Factors**:
  - Hull fouling: 1.07 (7% increase)
  - Draft conditions: 0.85 (15% reduction)
  - Weather conditions: 1.10-1.15 (10-15% increase)
- **Power Curves**: Cubic relationship between speed and power consumption

### 3. Machine Learning Pipeline
- **Algorithm**: Random Forest (1000 trees)
- **Cross-validation**: Spatial and temporal validation strategies
- **Feature Importance**: Permutation-based variable importance
- **Model Diagnostics**: Residual analysis and performance metrics

## Workflow Management

### Targets Pipeline Structure
The project uses the `targets` package for reproducible workflow management with two main pipelines:

1. **01_gfw_data_pull**: Data extraction and initial processing
2. **02_quarto_notebook**: Analysis and visualization

### Execution Order
```r
# 1. Setup environment
renv::restore()

# 2. Run data pipeline
targets::tar_make(names = "01_gfw_data_pull")

# 3. Run analysis pipeline
targets::tar_make(names = "02_quarto_notebook")

# 4. Check pipeline status
targets::tar_visnetwork()
```

## Testing and Validation Scripts

### Specialized Validation Scripts
- **`r/ais_validation_testing.R`**: AIS data quality assessment
- **`r/knn_performance_testing.R`**: Spatial interpolation validation
- **`r/snp_validation.R`**: S&P registry comparison

### Validation Metrics
- **Statistical**: R², RMSE, MAE, bias
- **Spatial**: Geographic distribution of residuals
- **Temporal**: Time-series validation
- **Cross-validation**: Independent dataset comparison

## Environment and Dependencies

### Package Management
- **System**: `renv` for reproducible package environments
- **Key Packages**: tidyverse, targets, bigrquery, tidymodels, sf, ggplot2

### System Requirements
- **R Version**: 4.5.1+
- **BigQuery Access**: Google Cloud Platform with appropriate permissions
- **Memory**: Sufficient RAM for large spatial datasets
- **Storage**: Space for processed CSV files and model outputs

## Error Handling and Debugging

### Common Issues
1. **BigQuery Permissions**: Ensure proper GCP setup and billing project access
2. **Memory Limitations**: Use chunked processing for large datasets
3. **Spatial Data**: Check coordinate system consistency across datasets
4. **Missing Data**: Implemented robust handling for sparse spatial data

### Debugging Tools
- **Targets**: `tar_outdated()`, `tar_progress()` for pipeline status
- **Logging**: Console output with informative messages
- **Validation**: Comprehensive checks at each processing stage

## Contributing Guidelines

### Code Style
- Follow R style guide conventions
- Use roxygen2 documentation for all functions
- Include meaningful comments for complex calculations
- Maintain consistent naming conventions

### Testing
- Run validation scripts before committing changes
- Verify pipeline execution from clean environment
- Check output consistency across different systems

### Documentation
- Update this document when adding new components
- Maintain function documentation with examples
- Document any changes to data schemas or methodologies