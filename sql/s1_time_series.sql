-- Monthly global S1 coverage statistics: detection counts, scene counts, and the
-- imaged area of those scenes.
--
-- NOTE ON THE AREA COLUMN. Scene areas must be aggregated over DISTINCT SCENES,
-- never over the detections table. Joining scene areas onto detections and
-- summing adds each scene's area once per detection inside it, which inflates
-- the result by orders of magnitude and makes it track detection counts rather
-- than coverage.
--
-- detect_foot_raw also repeats each scene's footprint row: 2.0 rows per scene in
-- 2017-2019, 1.4 in 2020, 1.3 in 2021, and 1.0 from 2022 on (the repeats are
-- byte-identical copies of one footprint_wkt). Summing per-row areas therefore
-- double-counts the early record and puts a step at May 2021, which is what
-- issue #10 found in the model's denominator. We collapse the repeats to one row
-- per scene_id the same way s1_ratios_rf does in
-- sql/s1/s1_pixel_area_imaged_by_scene.sql, and assert rather than assume that
-- the collapse is lossless: a scene_id carrying two genuinely different
-- footprints would quietly lose imaged area under ANY_VALUE, so the query errors
-- out instead. Keeping the dedupe identical to the upstream pipeline means this
-- figure's area panel and the model's summed_imaged_m2 are the same quantity.
--
-- The result is still revisit-weighted: areas are summed across scenes, so ocean
-- imaged by two scenes in a month is counted twice. It is a measure of S1
-- sampling effort in km2 x passes, not the union of ocean area imaged.
WITH
-- One footprint per scene. Filtering on `date` directly (not on an EXTRACT of
-- it) keeps BigQuery's partition pruning, which cuts the scan ~50x.
s1_scene_footprints_deduped AS (
  SELECT
    scene_id,
    IF(COUNT(DISTINCT footprint_wkt) > 1,
       ERROR(FORMAT(
         "detect_foot_raw: scene_id %s has %d distinct footprint_wkt values; deduping would silently drop imaged area",
         scene_id, COUNT(DISTINCT footprint_wkt))),
       ANY_VALUE(footprint_wkt)) AS footprint_wkt
  FROM
    `global-fishing-watch.pipe_sar_v1_published.detect_foot_raw`
  WHERE
    date BETWEEN DATE({analysis_start_year}, 1, 1) AND DATE({analysis_end_year}, 12, 31)
  GROUP BY
    scene_id
),
s1_scene_areas AS (
  SELECT
    scene_id,
    ST_AREA(SAFE.ST_GEOGFROMTEXT(footprint_wkt, make_valid => TRUE)) / 1e6 AS s1_scene_area_km2
  FROM
    s1_scene_footprints_deduped
),
-- Detection and scene counts per month.
monthly_detections AS (
  SELECT
    TIMESTAMP_TRUNC(detect_timestamp, MONTH) month,
    COUNT(DISTINCT detect_id) n_s1_detections,
    COUNT(DISTINCT CASE WHEN detect_ssvid IS NULL THEN detect_id END) n_s1_detections_unmatched,
    COUNT(DISTINCT scene_id) s1_scenes
  FROM
    `world-fishing-827.proj_ocean_ghg.rf_s1_detections_with_vessel_info_{run_version_dark}`
  WHERE
    EXTRACT(YEAR FROM detect_timestamp) BETWEEN {analysis_start_year} AND {analysis_end_year}
  GROUP BY
    month
),
-- The distinct scenes contributing to each month, so a scene counts once
-- regardless of how many detections it contains.
monthly_scenes AS (
  SELECT DISTINCT
    TIMESTAMP_TRUNC(detect_timestamp, MONTH) month,
    scene_id
  FROM
    `world-fishing-827.proj_ocean_ghg.rf_s1_detections_with_vessel_info_{run_version_dark}`
  WHERE
    EXTRACT(YEAR FROM detect_timestamp) BETWEEN {analysis_start_year} AND {analysis_end_year}
),
monthly_scene_area AS (
  SELECT
    month,
    SUM(s1_scene_area_km2) s1_scene_area_km2
  FROM
    monthly_scenes
  LEFT JOIN
    s1_scene_areas
  USING(scene_id)
  GROUP BY
    month
)
SELECT
  month,
  n_s1_detections,
  n_s1_detections_unmatched,
  s1_scenes,
  s1_scene_area_km2
FROM
  monthly_detections
LEFT JOIN
  monthly_scene_area
USING(month)
ORDER BY
  month
