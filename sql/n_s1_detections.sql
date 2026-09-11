SELECT
  COUNT(DISTINCT detect_id)/1e6 n_million_s1_detections,
  COUNT(DISTINCT CASE WHEN detect_ssvid IS NULL  THEN detect_id END)/1e6 n_million_s1_detections_unmatched,
  COUNT(DISTINCT scene_id)/1e3 n_thousand_s1_scenes
FROM
  `world-fishing-827.proj_ocean_ghg.rf_s1_detections_with_vessel_info_{run_version_dark}`
WHERE
  EXTRACT(YEAR FROM detect_timestamp) BETWEEN {analysis_start_year} and {analysis_end_year}