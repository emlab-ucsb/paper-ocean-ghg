-- Monthly global S1 coverage statistics: detection counts, scene counts, and the
-- imaged area of those scenes.
--
-- NOTE ON THE AREA COLUMN. Scene areas must be aggregated over DISTINCT SCENES,
-- never over the detections table. Joining scene areas onto detections and
-- summing adds each scene's area once per detection inside it, which inflates
-- the result by orders of magnitude and makes it track detection counts rather
-- than coverage. Per-scene rows are unioned rather than summed for the same
-- reason: `detect_foot_raw` can carry several overlapping along-track polygons
-- for one scene (notably before May 2021), and ST_UNION_AGG counts the area a
-- scene covers once whether those rows are exact duplicates or overlapping
-- pieces.
--
-- The result is still revisit-weighted: areas are summed across scenes, so ocean
-- imaged by two scenes in a month is counted twice. It is a measure of S1
-- sampling effort in km2 x passes, not the union of ocean area imaged.
WITH
-- One footprint area per scene.
s1_scene_areas AS (
  SELECT
    scene_id,
    ST_AREA(
      ST_UNION_AGG(SAFE.ST_GEOGFROMTEXT(footprint_wkt, make_valid => TRUE))
    ) / 1e6 AS s1_scene_area_km2
  FROM
    `global-fishing-watch.pipe_sar_v1_published.detect_foot_raw`
  WHERE
    EXTRACT(YEAR FROM date) BETWEEN {analysis_start_year} AND {analysis_end_year}
  GROUP BY
    scene_id
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
