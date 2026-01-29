WITH
s1_scene_areas AS(
  SELECT
  scene_id,
  date,
  ST_AREA(SAFE.ST_GEOGFROMTEXT(footprint_wkt, make_valid => TRUE))/(1e6) AS s1_scene_area_km2
FROM
  `global-fishing-watch.pipe_sar_v1_published.detect_foot_raw`
WHERE
    EXTRACT(YEAR FROM date) BETWEEN {analysis_start_year} and {analysis_end_year}
)
SELECT
  TIMESTAMP_TRUNC(detect_timestamp,MONTH) month,
  COUNT(DISTINCT detect_id) n_s1_detections,
  COUNT(DISTINCT CASE WHEN detect_ssvid IS NULL  THEN detect_id END) n_s1_detections_unmatched,
  COUNT(DISTINCT scene_id) s1_scenes,
  SUM(s1_scene_area_km2) s1_scene_area_km2
FROM
  `world-fishing-827.proj_ocean_ghg.rf_s1_detections_with_vessel_info_{run_version_dark}`
LEFT JOIN
s1_scene_areas
USING(scene_id)
WHERE
  EXTRACT(YEAR FROM detect_timestamp) BETWEEN {analysis_start_year} and {analysis_end_year}

GROUP BY
month
