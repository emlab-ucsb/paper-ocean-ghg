
WITH
ais_vessels AS(
  SELECT 
COUNT(*) n, 
fishing, 
length_size_bin,
'ais_vessels' type
FROM
  `world-fishing-827.proj_ocean_ghg.rf_s1_ais_vessels_size_classified_{run_version_dark}`
GROUP BY fishing, length_size_bin
ORDER BY fishing, length_size_bin),
s1_detections AS(
  SELECT 
COUNT(*) n, 
fishing, 
length_size_bin,
's1_detections' type
FROM
  `world-fishing-827.proj_ocean_ghg.rf_s1_detections_size_classified_{run_version_dark}`
GROUP BY fishing, length_size_bin
ORDER BY fishing, length_size_bin),
combined AS(
SELECT
*
FROM
ais_vessels
UNION ALL(SELECT * FROM s1_detections))
SELECT
*
FROM
combined
LEFT JOIN
(SELECT * FROM `world-fishing-827.proj_ocean_ghg.rf_vessel_length_bins_v20260126`)
USING(fishing,length_size_bin)
