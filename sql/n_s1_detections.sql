SELECT
    COUNT(DISTINCT detect_id)/1e6 n_million_s1_detections,
  COUNT(DISTINCT scene_id)/1e3 n_thousand_s1_scenes
FROM
  `world-fishing-827.proj_ocean_ghg.s1_detections_with_vessel_info_{run_version_dark}`
JOIN
(SELECT detect_id, scene_id FROM `world-fishing-827.proj_ocean_ghg.sentinel1_clean_v20250709`)
USING(detect_id)
WHERE
  EXTRACT(YEAR FROM detect_timestamp) BETWEEN {analysis_start_year} and {analysis_end_year}