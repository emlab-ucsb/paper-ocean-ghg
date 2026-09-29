# paper-ocean-ghg

Reproducibility repository for:

**"Quantifying comprehensive marine vessel emissions using satellite data fusion"**

McDonald, G., Carbó-Mestre, P., Deschenes, O., Bone, J., Cagua, E.F., Hughes, A., Kroodsma, D., Paolo, F.S., Powell, M., Wei, Z., & Costello, C.

Environmental Markets Lab (emLab), UC Santa Barbara & Global Fishing Watch

## Overview

This repository contains the code and data needed to reproduce every figure, table, and in-text statistic in the manuscript and its Supplementary Information. The analysis quantifies global marine vessel emissions of CO₂ and eight other pollutants (CH₄, N₂O, CO, NOₓ, SOₓ, PM₂.₅, PM₁₀, VOCs) from 2017 through 2025 by fusing AIS vessel tracking data with Sentinel-1 (S1) SAR vessel detections.

## Where the models live

The two emissions models themselves are maintained in separate repositories. This repository consumes their outputs.

| Repository | What it does | What it needs to run |
|---|---|---|
| [`ocean-ghg`](https://github.com/emlab-ucsb/ocean-ghg) | The AIS-based emissions model: vessel characteristics, ping-level emissions for every AIS-broadcasting vessel, port visits and voyages | Authenticated access to Global Fishing Watch data on Google BigQuery (data-use permissions required), and high-performance computing |
| [`s1_ratios_rf`](https://github.com/pcarbomestre/s1_ratios_rf) | The machine learning models for S1-unmatched emissions: the emissions regression, the detection classification and detection regression models, and their performance tests | The same BigQuery access, and high-performance computing |
| `paper-ocean-ghg` (this repository) | Pulls aggregated outputs of both models from BigQuery, compares them with published inventories and validation data, and produces the manuscript's figures, tables, and statistics | Nothing beyond R and Quarto: every input is committed |

Pipeline 1 below is the only link to the upstream models: it queries the BigQuery tables they write and saves the results as CSVs in `data/gfw/`. Those CSVs are committed, so you can reproduce the whole manuscript without BigQuery access or either upstream repository.

## Repository structure

```
paper-ocean-ghg/
│
├── main.tex                          # Manuscript source (Nature journal format)
├── si.tex / si_content.tex          # Supplementary Information: wrapper / content
├── preamble.tex                      # Packages and cross-references shared by both
├── combined.tex                      # Manuscript + SI as one document, for latexdiff
├── latexmkrc                         # Lets main.tex and si.tex build each other's .aux
├── diff/, tools/make_diff.sh         # Tracked-changes comparison against the submission
├── bibliography.bib                  # BibTeX references
├── sn-jnl.cls / sn-nature.bst       # Nature journal LaTeX class and bibliography style
│
├── run.r                             # Entry point: runs pipeline 3 (1 and 2 are optional)
├── _targets.yaml                     # Configures three targets pipeline projects
├── _targets_01_gfw_data_pull.R       # Pipeline 1: download GFW data from BigQuery
├── _targets_02_inventories_comparison.R  # Pipeline 2: download + tidy published inventories
├── _targets_03_quarto_notebook.R     # Pipeline 3: load data + render Quarto notebook
│
├── r/
│   └── functions.R                   # Helper functions (BigQuery download, MRV data processing)
│
├── sql/                              # BigQuery SQL for pipeline 1, one query per pull (31 files)
│
├── qmd/
│   └── quarto_notebook.qmd          # Analysis notebook: generates all figures + tables
│
├── data/
│   ├── gfw/                         # Outputs of ocean-ghg and s1_ratios_rf, pulled from BigQuery by pipeline 1
│   │   ├── annual_emissions_all_pollutants.csv
│   │   ├── monthly_aggregated_time_series.csv
│   │   ├── total_spatial_emissions_by_pollutant.csv
│   │   ├── ... (41 CSV files total)
│   │   └── vessel_size_info.csv
│   ├── IEA_EDGAR_CO2_1970_2024/     # EDGAR v8.0 CO₂ emissions by sector (1970-2024)
│   │   └── IEA_EDGAR_CO2_1970_2024.xlsx
│   ├── MRV/                         # EU MRV emissions database (2018-2024)
│   │   ├── raw/                     # Raw annual Excel files from EMSA
│   │   ├── mrv_data_validation.csv  # Combined MRV data
│   │   └── trip_emissions_for_mrv_validation.csv
│   ├── oecd/                        # OECD experimental maritime transport emissions
│   │   └── annual_oecd_experimental_data.csv
│   ├── registered_validation_data/  # Vessel-level validation data from a proprietary vessel registry
│   │   └── registered_validation_data.csv
│   ├── gfw_s1_to_ais_matching_miss_rate/  # GFW hold-out test of S1-AIS matching (double counting)
│   ├── World_Countries_Generalized_Shapefile/  # ESRI country boundaries for maps
│   ├── inventories/                 # Tidy inventory series written by pipeline 2
│   ├── steam/ seim/ icct/ ceds/ edgar/  # Per-inventory extracts written by pipeline 2
│   └── data_sources.csv            # Model feature metadata table
│
├── figures/                         # Output PNG figures (all generated by the notebook except the Fig. 5 flowchart)
├── tables/                          # Output LaTeX tables, plus the three Supplementary Data CSVs
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

Downloads analysis-ready datasets from Google BigQuery. The tables it reads are written by the two upstream models, `ocean-ghg` (AIS-based emissions) and `s1_ratios_rf` (S1-unmatched emissions), on Global Fishing Watch's BigQuery project. This pipeline runs the queries in `sql/` and saves results as CSV files in `data/gfw/`. It requires authenticated access to the `emlab-gcp` BigQuery billing project and the `world-fishing-827` GFW data project.

Two targets at the top of the script pin which BigQuery table versions the queries read:

| Target | Drives |
|---|---|
| `run_version_ais` | AIS-side pulls: validation (MRV, registered), port and trip emissions, receiver type, vessel info, activity summaries |
| `run_version_dark` | Everything that reads a dark-fleet model output or the S1 detection and coverage tables: emissions totals and maps, monthly series, model performance, variable importance, detection counts, unmatched shares, scene footprints and imaged area, detection density |

`run_version_dark` points at the frozen `_paper_*` snapshot tables, so the manuscript's numbers only change when the dark-fleet model is deliberately rerun and re-snapshotted upstream (in `s1_ratios_rf`). Because a re-snapshot keeps the same table names, `targets` cannot see that the tables were rewritten: invalidate everything downstream of `run_version_dark` by hand before re-running (issue #13 has the snippet). The `s1_coverage_phi_ok` target guards the S1 effort denominator: it fails the pull if the per-pass coverage fraction leaves its historical band, which is how the footprint duplication that issue #10 found would show up if it ever came back.

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

Loads all CSV files from `data/gfw/` and external datasets (EDGAR, OECD, MRV), the tidy inventory CSVs from pipeline 2, then renders `qmd/quarto_notebook.qmd`. The Quarto notebook performs all data wrangling, generates every data figure (saved to `figures/`) and every generated table (saved to `tables/`), and computes every in-text statistic in the manuscript, the Supplementary Information and the response to reviewers. Its "In-line manuscript statistics" section mirrors the manuscript sentence by sentence, so each reported number can be traced to the code that computes it.

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
| AIS-based emissions (`ocean-ghg`) | Aggregated emissions of AIS-broadcasting vessels, activity summaries, vessel characteristics, port visits and voyages | `data/gfw/` |
| S1-unmatched emissions (`s1_ratios_rf`) | Emissions estimated from S1 detections unmatched to AIS, with S1 coverage, detection density and model performance | `data/gfw/` |
| S1-AIS matching hold-out test | Probability that a detection of a broadcasting vessel is missed by the matching, by AIS gap length | `data/gfw_s1_to_ais_matching_miss_rate/` |
| Published inventories | STEAM, SEIM, MariTEAM, OECD, SAVE (ICCT), the Fourth IMO GHG Study, EDGAR and CEDS | `data/inventories/`, `data/steam/`, `data/seim/`, `data/icct/`, `data/ceds/`, `data/edgar/`, `data/oecd/` |
| EDGAR | Global CO₂ emissions by sector (1970–2024) | `data/IEA_EDGAR_CO2_1970_2024/` |
| EU MRV | Published vessel-level annual emissions from the EU monitoring program (2018–2024) | `data/MRV/` |
| Registry validation data | Measured main engine fuel consumption from a major proprietary vessel registry, used to validate the AIS-based model | `data/registered_validation_data/` |
| ESRI Countries | Generalized world country boundaries | `data/World_Countries_Generalized_Shapefile/` |

## Outputs

All figures except Fig. 5 are generated by `qmd/quarto_notebook.qmd` and saved as PNGs in `figures/`. Fig. 5 is a conceptual flowchart of the methods; it contains no data and was drafted with the help of an AI design tool (see [AI disclosure](#ai-disclosure)).

### Main text

| Item | File | Description |
|------|------|-------------|
| Fig. 1 | `fig-emissions-by-data-source-and-maps` | Annual CO₂ by data source (AIS-based, S1-unmatched, fused), change since 2017, and 2025 maps |
| Fig. 2 | `fig-emissions-time-series-and-maps` | Monthly CO₂ by data source, S1-unmatched share, and maps of each component |
| Fig. 3 | `fig-ais-data-richness` | AIS-based CO₂ by vessel class, map by vessel family, and split by activity type |
| Fig. 4 | `fig-emissions-inventory-comparison` | Our estimates against bottom-up and top-down inventories |
| Fig. 5 | `fig-framework-flowchart-simpler` | Conceptual flowchart of the methods (not code-generated) |
| Fig. 6 | `fig-emissions-by-message-hour-threshold` | Cumulative AIS-based CO₂ by the interval each ping represents |
| Fig. 7 | `fig-registered-data-performance` | Validation against the proprietary registry's measured fuel consumption |
| Fig. 8 | `fig-mrv-performance` | Validation against EU MRV annual emissions |
| Fig. 9 | `fig-map-fraction-months-imaged` | Share of months each pixel was imaged by S1 |
| Fig. 10 | `fig-s1-coverage-time-series` | Monthly S1 scenes, imaged area, detections and unmatched share |
| Fig. 11 | `fig-s1-matching-double-counting` | Double counting between the AIS-based and S1-unmatched estimates |
| Fig. 12 | `fig-length-bin-distributions` | Length-bin distributions of AIS vessels and S1 detections |
| Fig. 13 | `fig-ais-length-power-relationship` | Main engine power against vessel length |
| Fig. 14 | `fig-offshore-outside-footprint-training-testing-map` | Training/testing pixels for the simulated outside-footprint test |
| Figs. 15–17 | `fig-pr-curves`, `fig-roc-curves`, `fig-conf-mat` | Detection classification model performance |
| Fig. 18 | `fig-feature-importance` | Feature importance for the three S1-unmatched models |
| Fig. 19 | `fig-spatial-coverage-footprint` | S1-unmatched emissions inside and outside the S1 footprint |
| Table 1 | `emissions_by_message_hour_threshold.tex` | AIS-based CO₂ by ping-interval threshold |
| Tables 2–3 | written in `main.tex` | Vessel characteristics model performance; characteristic availability by source |
| Table 4 | `mrv_performance_results.tex` | EU MRV validation by matching tolerance |
| Tables 5–6 | `s1_matching_double_counting_by_gap.tex`, `s1_matching_double_counting_summary.tex` | Double counting by gap length, and summary |
| Table 7 | `data_sources.tex` | S1-unmatched model features and data sources |
| Table 8 | `all_performance_metrics_table.tex` | S1-unmatched model performance |
| Table 9 | `lm_other_gases_tidy_fit_stats.tex` | Linear models converting CO₂ to other gases |

### Supplementary Information

| Item | File | Description |
|------|------|-------------|
| Supplementary Fig. 1 | `fig-spatial-temporal-richness-by-fleet-total-pseudolog` | Fig. 2 split into fishing and non-fishing vessels |
| Supplementary Figs. 2–3 | `fig-pollutant-maps-qlog10`, `fig-pollutant-time-series` | Maps and monthly series for every GHG and pollutant |
| Supplementary Fig. 4 | `fig-emissions-by-country-and-activity-type` | CO₂ by country and activity type |
| Supplementary Figs. 5–6 | `fig-emissions-marine-ocean-other`, `fig-annual-emissions-by-ocean-and-data-source` | CO₂ by ocean basin |
| Supplementary Figs. 7–10 | `figS-passenger-size-panels`, `figS-fleet-growth-by-year`, `figS-growth-timeline-by-family-length`, `figS-fleet-sankey-with-series-2025` | Fleet growth and composition by vessel class and length |
| Supplementary Figs. 11–13 | `fig-annual-emissions-by-ais-receiver-type`, `...-top-flags`, `fig-co2-emissions-change-map-by-receiver-type` | Trends by AIS receiver type (Supplementary Note 1) |
| Supplementary Figs. 14–16 | `figS-inventory-comparison-all-sources`, `figS-ais-carriage-saturation-by-size`, `figS-density-by-match-status` | Inventory comparison and S1 evidence on AIS carriage (Supplementary Note 3) |
| Supplementary Tables 1–7 | `total_percent_change_by_fleet.tex`, `growth_share_by_family_length.tex`, `growth_decomposition_by_family_length.tex`, `pollutant_ais_underestimation_overestimation_summary.tex`, `emissions_by_ocean_summary_tbl.tex`, `annual_sc_fishing_non_fishing_tbl.tex`, `top_countries_by_activity_type.tex` | Change by data source, growth by vessel segment, pollutants, oceans, social cost, top countries |
| Supplementary Tables 8–10 | `inventory_comparison_all_sources.tex`, `multisector_shipping_comparison.tex`, `inventory_growth_comparison.tex` | Inventory comparison (Supplementary Note 3) |
| Supplementary Data 1–3 | `bottom-up_inventory_comparison_{methods,inputs,outputs}.csv` | Attribute-by-attribute comparison with six bottom-up inventories (Supplementary Note 2) |

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

## AI disclosure

Much of the code in this repository was written with the assistance of a large language
model — Anthropic's Claude, used through the Claude Code command-line tool. That includes
the R analysis and plotting code in `qmd/quarto_notebook.qmd` and `r/functions.R`, the
BigQuery SQL in `sql/`, the `targets` pipeline definitions, and this README. Commits made
with that assistance carry a `Co-Authored-By: Claude` trailer, so `git log` records which
parts of the history it touched.

What that assistance did **not** do is decide anything. The models, the data sources, the
methodological choices and the conclusions are the authors'. Every number reported in the
manuscript is computed from the committed data by the code here rather than written by
hand, and every data figure is drawn from that data. The one exception is Fig. 5, a
conceptual flowchart of the methods that contains no data, which was drafted with the help
of an AI design tool (Anthropic's Claude Design) and reviewed and finalized by the authors. All code
was reviewed and run by the authors, who are responsible for its correctness.

The same disclosure appears in the manuscript under "Use of generative AI", following
[Nature Portfolio's policy on AI](https://www.nature.com/nature-portfolio/editorial-policies/ai):
a large language model cannot be an author, and its use must be documented.

## Licensing

This repository uses the [Creative Commons CC BY 4.0 license](https://creativecommons.org/licenses/by/4.0/deed.en).