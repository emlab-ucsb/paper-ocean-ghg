# paper-ocean-ghg

Reproducibility repository for:

**"Quantifying comprehensive marine vessel emissions using satellite data fusion"**

McDonald, G., Carbó-Mestre, P., Deschenes, O., Bone, J., Cagua, E.F., Hughes, A., Kroodsma, D., Paolo, F.S., Powell, M., Wei, Z., & Costello, C.

Environmental Markets Lab (emLab), UC Santa Barbara & Global Fishing Watch

## Overview

This repository contains the code and data pipeline to reproduce all figures, tables, and in-text statistics in the manuscript. The analysis quantifies global marine vessel emissions of CO₂ and eight other pollutants (CH₄, N₂O, CO, NOₓ, SOₓ, PM₂.₅, PM₁₀, VOCs) from 2017 through 2025 by fusing AIS vessel tracking data with Sentinel-1 SAR vessel detections.

## Repository structure

```
paper-ocean-ghg/
│
├── main.tex                          # Manuscript source (Nature journal format)
├── bibliography.bib                  # BibTeX references
├── sn-jnl.cls / sn-nature.bst       # Nature journal LaTeX class and bibliography style
│
├── run.r                             # Entry point: runs the full targets pipeline
├── _targets.yaml                     # Configures three targets pipeline projects
├── _targets_01_gfw_data_pull.R       # Pipeline 1: download GFW data from BigQuery
├── _targets_02_inventories_comparison.R  # Pipeline 2: download + tidy published inventories
├── _targets_03_quarto_notebook.R     # Pipeline 3: load data + render Quarto notebook
│
├── r/
│   └── functions.R                   # Helper functions (BigQuery download, MRV data processing)
│
├── sql/                              # BigQuery SQL queries, one per pull
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
│   ├── inventories/                 # Tidy inventory series written by pipeline 2
│   ├── steam/ seim/ icct/ ceds/     # Per-inventory extracts written by pipeline 2
│   └── data_sources.csv            # Model feature metadata table
│
├── figures/                         # Output PNG figures (24 total)
├── tables/                          # Output LaTeX tables (10 total)
│
├── _targets/                        # targets stores -- COMMITTED, see "Working across machines"
│   ├── 01_gfw_data_pull/            #   metadata + cached objects for pipeline 1
│   ├── 02_inventories_comparison/   #   metadata ONLY -- objects are not committed
│   └── 03_quarto_notebook/          #   metadata + cached objects for pipeline 3
│
├── renv/                            # renv package management
│   ├── activate.R
│   └── settings.json
├── renv.lock                        # Locked package versions for reproducibility
└── paper-ocean-ghg.Rproj           # RStudio/Positron project file
```

## Pipeline architecture

The analysis uses the [{targets}](https://docs.ropensci.org/targets/) pipeline framework with three sequential projects defined in `_targets.yaml`:

```
01_gfw_data_pull  ->  02_inventories_comparison  ->  03_quarto_notebook
   (BigQuery)            (public inventories)          (figures + tables)
```

Numbering follows the dependency order. Each pipeline only reads what the ones before it
wrote, so a single pass in order is enough and you never have to go back to an earlier one.

Handoff is through committed CSVs rather than through each other's `targets` stores, which is
what makes the upstream pipelines skippable. The exception is `analysis_start_year` and
`analysis_end_year`, which pipelines 2 and 3 pull from pipeline 1's store via
`tar_read(store = ...)`; pipeline 1's store objects are committed so that still works without
BigQuery access.

### Pipeline 1: `01_gfw_data_pull` (data acquisition)

**Script:** `_targets_01_gfw_data_pull.R`

Downloads analysis-ready datasets from Google BigQuery tables maintained by Global Fishing Watch. This pipeline runs the queries in `sql/` and saves results as CSV files in `data/gfw/`. It requires authenticated access to the `emlab-gcp` BigQuery billing project and the `world-fishing-827` GFW data project.

Three targets at the top of the script pin which BigQuery table versions the queries read:

| Target | Drives |
|---|---|
| `run_version_ais` | AIS-side pulls: validation (MRV, registered), port and trip emissions, receiver type, vessel info, activity summaries |
| `run_version_dark` | Everything that reads a dark-fleet model output: emissions totals and maps, monthly series, model performance, variable importance |
| `run_version_s1` | **Temporary.** The S1-descriptive pulls: detection counts, unmatched shares, scene footprints and imaged area, detection density |

`run_version_dark` points at the frozen `_paper_*` snapshot tables, so the manuscript's emissions numbers only change when the dark-fleet model is deliberately rerun and re-snapshotted upstream (in `s1_ratios_rf`). `run_version_s1` is a stopgap: the S1 detection and coverage tables were rebuilt on 2026-09-09 with deduplicated scene footprints and corrected 2025 detection-AIS matching, before the forests were retrained on them, and this target lets the S1 figures read the fixed base tables while the emissions figures stay on the snapshots. Once the model is rerun and the snapshots refreshed, delete `run_version_s1` and put the six S1 pulls back on `run_version_dark` (issue #13 has the checklist). The `s1_coverage_phi_ok` target guards the S1 effort denominator: it fails the pull if the per-pass coverage fraction leaves its historical band, which is how the footprint duplication would show up if it ever came back.

You can't run this without BigQuery access to those projects, and you don't need to: every output CSV is committed, along with this pipeline's store objects, so pipelines 2 and 3 run without any Google credentials.

### Pipeline 2: `02_inventories_comparison` (published inventories)

**Script:** `_targets_02_inventories_comparison.R`

Downloads the published marine emissions inventories the manuscript compares against — CAMS/STEAM, SEIM, ICCT, CEDS, EDGAR and OECD — puts them on a common schema, and writes tidy CSVs to `data/inventories/` (plus `data/steam/`, `data/seim/`, `data/icct/`, `data/ceds/`) that pipeline 3 reads back in.

No BigQuery access needed. It reads its GFW inputs as committed CSVs from `data/gfw/`, and takes `analysis_start_year` / `analysis_end_year` from pipeline 1's store.

Re-running it is expensive, for two reasons. The CAMS/STEAM targets need a free Copernicus ADS token (see below), and fail without one. And the source grids are big: each CAMS year is a ~885 MB zip, so a full re-run pulls about 6 GB and spends ~25 s aggregating per year. Each year is downloaded to a temp file, aggregated, and deleted in the same target, so only the processed CSVs stick around.

This is also the one store whose `objects/` aren't committed. No good reason — they're tiny (~44 KB for the whole pipeline), they just never got added. So `tar_outdated()` on a fresh clone flags the whole pipeline as stale even though its CSVs are present and current. Ignore it: pipeline 3 reads those CSVs from disk and never touches this store. Only run this pipeline if you're actually refreshing an inventory.

#### Getting a Copernicus ADS token

Free, and nothing to do with the BigQuery credentials pipeline 1 needs. Only relevant if you're re-running this pipeline.

1. Register for an ECMWF account at <https://ads.atmosphere.copernicus.eu/> and log in.
2. Accept the licence for the CAMS global emission inventories dataset at <https://ads.atmosphere.copernicus.eu/datasets/cams-global-emission-inventories>. Downloads fail until you do, even with a valid token.
3. Copy your personal access token from <https://ads.atmosphere.copernicus.eu/profile>.
4. Store it once, in R:

   ```r
   ecmwfr::wf_set_key()   # paste the token when prompted
   ```

That writes it to your system keyring under the service name `ecmwfr`, which is where `wf_request()` looks. Check it took with:

```r
ecmwfr::wf_get_key(user = "ecmwfr")
```

Note that `wf_get_key(service = "ads")` won't find it — `service` refers to an older storage layout. Use `user = "ecmwfr"`.

### Pipeline 3: `03_quarto_notebook` (analysis and figures)

**Script:** `_targets_03_quarto_notebook.R`

Loads all CSV files from `data/gfw/` and external datasets (EDGAR, OECD, MRV), the tidy inventory CSVs from pipeline 2, then renders `qmd/quarto_notebook.qmd`. The Quarto notebook performs all data wrangling, generates all 24 figures (saved to `figures/`), generates all 10 LaTeX tables (saved to `tables/`), and computes all in-text statistics referenced in the manuscript.

### Running without BigQuery permissions

This is the normal case. Only pipeline 1 touches BigQuery, and you don't need to run it.

| Pipeline | Credentials | Need to run it? |
|---|---|---|
| 1 `01_gfw_data_pull` | BigQuery (`emlab-gcp`, `world-fishing-827`) | No — CSVs and store objects are committed |
| 2 `02_inventories_comparison` | [Copernicus ADS token](#getting-a-copernicus-ads-token), CAMS targets only. No BigQuery | No — all 14 output CSVs are committed |
| 3 `03_quarto_notebook` | None | Yes — this is what `run.r` runs |

A fresh clone needs R 4.5.x, `renv::restore()`, and `quarto` on `PATH`. Run `source("run.r")`
and everything regenerates from committed data; nothing in pipeline 3 hits BigQuery or the
network.

To refresh an upstream pipeline, uncomment it in `run.r` and run 01, 02, 03 in order.

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
| S1 | `fig-pollutant-maps-qlog10` | Spatial maps of 2025 emissions for all pollutants |
| S2 | `fig-pollutant-time-series` | Monthly time series for all pollutants |
| S3 | `fig-annual-emissions-by-ocean-and-data-source` | Annual CO₂ by ocean and data source |
| S4 | `fig-inventory-comparison` | Comparison with other marine CO₂ emission inventories |
| S5 | `fig-annual-emissions-by-ais-receiver-type` | Annual emissions by AIS receiver type |
| S6 | `fig-annual-emissions-by-ais-receiver-type-top-flags` | Emissions by AIS receiver type for top 10 flags |
| S7 | `fig-co2-emissions-change-map-by-receiver-type` | Spatial change in CO₂ by AIS receiver type (2017–2025) |

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
| S1 | `total_percent_change_by_fleet.tex` | Percent change in emissions by fleet (2017–2025) |
| S2 | `pollutant_ais_underestimation_overestimation_summary.tex` | AIS underestimation/overestimation summary by pollutant |
| S3 | `emissions_by_ocean_summary_tbl.tex` | Emissions summary by ocean basin |
| S4 | `emissions_by_data_source_summary_tbl.tex` | Emissions summary by data source |
| S5 | `annual_sc_fishing_non_fishing_tbl.tex` | Annual social cost of emissions by fishing/non-fishing |
| S6 | `inventory_comparison.tex` | Marine CO₂ inventory comparison data |

## Reproducing the analysis

### Prerequisites

- **R 4.5.x** — not 4.6 or newer. `renv.lock` pins package versions from the R 4.5 era, and R 4.6 removed several legacy C API entry points (`Rf_allocSExp`, `SET_ENCLOS`, `Rf_findVarInFrame3`), so pinned sources such as `magrittr` 2.0.3 fail to compile. `renv::restore()` will not complete under R 4.6.
- **quarto** — must be on your `PATH`, not only inside your IDE. `targets` shells out to the `quarto` CLI, so `Rscript run.r` from a terminal fails with "Quarto CLI not found" if the IDE's bundled copy is the only one installed.
- [Positron](https://positron.posit.co/) or RStudio IDE (recommended)
- No credentials needed. `run.r` runs pipeline 3 only, off committed data. Credentials only come into play if you re-run an upstream pipeline: BigQuery for 1, a [Copernicus ADS token](#getting-a-copernicus-ads-token) for 2.

If you juggle multiple R versions, [rig](https://github.com/r-lib/rig) makes switching a one-liner:

```bash
rig list                    # show installed versions
rig default 4.5-arm64       # point R/Rscript at 4.5.x (no sudo needed for admin users)
```

> **macOS note:** the per-version launchers (`R-4.5-arm64`) only report the right version if rig has patched `R_HOME_DIR` in that version's startup script. If `R-4.5-arm64 --version` disagrees with the name, run `sudo rig system make-links`.

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

The entry point is `run.r`, and it needs no credentials. Pipelines 1 and 2 are commented out
there (1 needs BigQuery, 2 needs a Copernicus token and ~6 GB of downloads); neither is
required, since everything they produce is committed. So `run.r` runs pipeline 3 only:

```r
source("run.r")
```

This is equivalent to:

```r
Sys.setenv(TAR_PROJECT = "03_quarto_notebook")
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
Sys.setenv(TAR_PROJECT = "03_quarto_notebook")
targets::tar_outdated()
targets::tar_visnetwork()
```

## Working across machines

The `01_gfw_data_pull` and `03_quarto_notebook` stores under `_targets/` are committed to git,
both the metadata (`meta/meta`) and the target objects (`objects/`). That's on purpose: a fresh
clone is already up to date, so `tar_outdated()` comes back empty (or at most the Quarto
notebook) without anyone re-running the pipeline or holding BigQuery credentials.

`02_inventories_comparison` only commits `meta/meta`. Its output CSVs are committed instead,
which is all pipeline 3 needs, so that pipeline always shows as stale on a fresh clone.

`targets` does not set this up by default — it generates a `.gitignore` in each store that
commits only `meta/meta`. Those files have been edited to also include `objects/`, and each
one explains why. If you ever delete and recreate a store, `targets` will regenerate the
restrictive version and you will need to re-apply the change.

### The workflow

**Always pull before running the pipeline, and commit the store afterwards.**

```bash
git pull
Rscript run.r            # or source("run.r") in your IDE
git add -A && git commit -m "Re-run pipeline"
git push
```

`git add -A` picks up the changed objects and metadata along with any regenerated
`figures/` and `tables/`, because the store `.gitignore` files now allow them.

### Why the pull-first rule matters

`meta/meta` is rewritten on every run, and `objects/` files are binary. If two machines run
the pipeline from the same starting commit, both rewrite the same files and you get a
conflict that git cannot merge for you. `.gitattributes` marks these paths so git refuses to
auto-merge rather than splicing together a metadata file that misrepresents which targets are
current.

If you do hit a conflict in `_targets/`, don't hand-resolve it. Take one side wholesale and
let the pipeline reconcile:

```bash
git checkout --theirs _targets/    # or --ours
git add _targets/
Rscript run.r                      # rebuilds whatever is genuinely stale
```

### Keeping figures stable across platforms

`figures/` and `qmd/quarto_notebook.pdf` are committed, so the graphics backend has to be
the same everywhere or every machine switch rewrites all 24 PNGs and the PDF even when no
data changed.

`grDevices::png()` chooses its backend from `getOption("bitmapType")`, which is `quartz` on
macOS and `cairo` on Linux. Quartz writes RGBA, cairo writes RGB — different bytes for an
identical plot. The notebook's setup chunk therefore pins cairo on every platform:

```r
if (capabilities("cairo")) {
  options(bitmapType = "cairo")
}
```

Don't remove this. If you add a machine where `capabilities("cairo")` is `FALSE`, render on
a different machine rather than letting it fall back to a foreign backend.

**This is necessary but not sufficient.** Pinning cairo removes one whole class of
difference (color model), but it does not make renders byte-identical across machines. A
measured comparison of the same data rendered on the macOS laptop and the Linux HPC, both
using cairo, still showed:

| region of Figure 1 | pixels differing | mean absolute difference |
|---|---|---|
| panels A/B (line charts) | 15% | negligible — text rasterization |
| panel C (raster maps) | 61% | 0.20 on a 0–1 scale — visibly lighter |

The line charts differ only in text rasterization (font stacks differ). The raster maps
differ substantively, most likely because `sf` links against different GEOS/GDAL/PROJ
versions on each machine, which changes reprojection and tile rasterization. Check yours
with:

```r
sf::sf_extSoftVersion()[c("GEOS", "GDAL", "PROJ")]
```

**Practical consequence:** figures are not portable across machines even with the device
pinned. Decide which machine is authoritative for `figures/` and
`qmd/quarto_notebook.pdf` and render the final manuscript versions there. Rendering on the
other machine is fine for inspecting results, but expect it to rewrite every figure.

### What is intentionally *not* committed

- `meta/process` and `meta/progress` — process IDs, timestamps, and per-run target status.
  They change on every run and carry no reproducibility value.
- `renv/library/` — platform-specific. The macOS laptop and the Linux HPC each build their
  own library from `renv.lock` via `renv::restore()`.

### Repo size

Committing objects means every data refresh writes a new full copy of each changed binary,
on top of the ~156 MB of input data in `data/`. With the BigQuery pull now essentially
final, refreshes should be rare and this cost is a one-time one. Run `git gc` if `.git`
accumulates loose objects; check with `git count-objects -vH`.

## Helper functions

`r/functions.R` contains:

- `download_gfw_data()` — Executes a BigQuery SQL query and saves results in the repo as CSV. Note that this function can only be used by those who have special permissions to Global Fishing Watch data on BigQuery.
- `combine_EU_data()` — Reads and combines annual EU MRV Excel files (2018–2024) into a single tibble

## Licensing

This repo uses the[ Create Commons CC BY 4.0 license](https://creativecommons.org/licenses/by/4.0/deed.en).