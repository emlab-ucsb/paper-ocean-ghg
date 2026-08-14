-- !! DOES NOT RUN AGAINST THE CURRENT SCHEMA. Kept as the target shape for a
-- !! length-resolved dark emissions product, not as a working extract.
-- !!
-- !! Schema checked 2026-08-13:
-- !!   rf_s1_time_gridded_dark_fleet_model_paper_v20260714
-- !!     time, lon_bin, lat_bin, fishing, inside_footprint, s1_imaged, <emissions>
-- !!   rf_s1_predicted_dark_emissions_paper_v20260714
-- !!     time, lon_bin, lat_bin, fishing, inside_footprint, s1_imaged, <emissions>
-- !!
-- !! Neither carries a length field, so the `length_size_bin` this query groups
-- !! by does not exist and the LEFT JOIN below has nothing to join on. Length is
-- !! collapsed before the dark predictions are stored.
-- !!
-- !! rf_model_features_paper_v20260714 DOES carry length_size_bin,
-- !! length_bin_min, length_bin_max alongside matched_s1_detections_per_km2_
-- !! area_imaged and unmatched_s1_detections_per_km2_area_imaged - so the
-- !! model's INPUTS are length-resolved and only its dark emissions OUTPUT is
-- !! not. Producing dark emissions by length bin therefore needs the prediction
-- !! step re-run retaining the length dimension. That is an R/model change, not
-- !! a query, and no SQL rewrite can substitute for it.
-- !!
-- !! The detection-side half of the question needs no query at all:
-- !! data/gfw/s1_detection_density_by_denominator.csv already carries matched
-- !! and unmatched counts per month x fleet x length bin together with all three
-- !! effort denominators. r/si_density_by_match_status.R uses it.
--
-- Monthly AIS and dark CO2, disaggregated by fleet AND vessel length bin.
--
-- Why this query exists. annual_spatial_co2_emissions_ais_dark_by_fleet.sql
-- carries both emissions components but resolves them only by fishing /
-- non-fishing, while annual_ais_activity_summary_cheap.sql resolves the AIS side
-- by length bin and carries no dark side. So AIS emissions by length bin exist
-- and dark emissions by length bin do not, and the reallocation question - does
-- dark emissions fall in a bin while AIS emissions rise in the same bin, as
-- vessels there start broadcasting - cannot be asked at size resolution.
--
-- The bin scheme matches by construction: annual_ais_activity_summary_cheap.sql
-- already states its length bins "follow the dark fleet model's non-fishing
-- scheme (10 bins)", so the two sides are directly comparable once this runs.
--
-- MONTHLY, NOT ANNUAL, and this is the point of the query rather than a detail.
-- Two hypotheses predict "dark emissions grow in the small non-fishing bins":
--
--   (a) real new small-vessel activity, part of which broadcasts and part of
--       which does not - the reading this query is meant to test; and
--   (b) the May 2021 footprint units change (issue #10 s18) inflating the dark
--       side, which is denominated in summed imaged area (s17) and therefore
--       not protected by the union-area-x-passes denominator that keeps the
--       detection-density analysis clean.
--
-- Both predict growth, so growth alone does not discriminate. The shape does: a
-- common multiplicative step at May 2021 across essentially every bin is (b),
-- whereas smooth bin-specific growth concentrated in particular bins is (a).
-- Annual aggregation cannot separate a mid-2021 step from a trend; monthly can,
-- and it makes each bin independently step-testable at May 2021 and Dec 2021 -
-- the per-bin version of the s20 test.
--
-- Spatial bins are dropped deliberately. Nothing here needs geography, and
-- lon_bin x lat_bin x month x length_bin would multiply the output for no gain.
--
-- SCHEMA CHECK REQUIRED BEFORE RUNNING. This assumes the gridded dark fleet
-- model table retains a `length_size_bin` field, which is the name that
-- rf_s1_detections_size_classified_* and rf_vessel_length_bins_* both use. Ver-
-- ify with:
--
--   bq show --schema --format=prettyjson \
--     world-fishing-827:proj_ocean_ghg.rf_s1_time_gridded_dark_fleet_model_paper_v20260714
--
-- If the field is absent, the gridded product has already summed over size and
-- this query cannot work as written. The fallback is to go back to the
-- detection-level tables and attribute modelled dark emissions to the detections
-- they were built from before binning:
--
--   rf_s1_detections_size_classified_<ver>  (detect_id, fishing, length_m)
--   rf_s1_predicted_dark_emissions_<ver>    (per issue #10 s20)
--
-- which is a materially bigger job and needs its own cost check.

SELECT
  TIMESTAMP_TRUNC(time, MONTH) month,
  fishing,
  length_size_bin,
  bins.length_bin_min,
  bins.length_bin_max,
  SUM(emissions_co2_mt) emissions_co2_mt,
  SUM(emissions_co2_dark_mt) emissions_co2_dark_mt
FROM
  `world-fishing-827.proj_ocean_ghg.rf_s1_time_gridded_dark_fleet_model_{run_version_dark}` model
LEFT JOIN
  `world-fishing-827.proj_ocean_ghg.rf_vessel_length_bins_{run_version_dark}` bins
USING
  (fishing, length_size_bin)
WHERE
  EXTRACT(YEAR FROM time) BETWEEN {analysis_start_year} AND {analysis_end_year}
GROUP BY
  month,
  fishing,
  length_size_bin,
  bins.length_bin_min,
  bins.length_bin_max
ORDER BY
  month,
  fishing,
  length_size_bin
