-- Number of AIS-broadcasting vessels and number of S1 detections in each of
-- the model's length bins, by fishing / non-fishing, with the bin edges.
--
-- The detections are restricted to the analysis years. The size-classified
-- table is not: it carries every detection in sentinel1_clean, which reaches
-- back to 2016 and forward past the analysis window, and grows whenever GFW
-- extends the table. Without the filter this figure would describe a different
-- (and moving) set of detections than the ones the model is trained on.
WITH
ais_vessels AS(
  SELECT
    COUNT(*) n,
    fishing,
    length_size_bin,
    'ais_vessels' type
  FROM
    `world-fishing-827.proj_ocean_ghg.rf_s1_ais_vessels_size_classified_{run_version_s1}`
  GROUP BY fishing, length_size_bin
),
s1_detections AS(
  SELECT
    COUNT(*) n,
    fishing,
    length_size_bin,
    's1_detections' type
  FROM
    `world-fishing-827.proj_ocean_ghg.rf_s1_detections_size_classified_{run_version_s1}`
  WHERE
    EXTRACT(YEAR FROM detect_timestamp) BETWEEN {analysis_start_year} AND {analysis_end_year}
  GROUP BY fishing, length_size_bin
),
combined AS(
  SELECT * FROM ais_vessels
  UNION ALL (SELECT * FROM s1_detections)
)
SELECT
  *
FROM
  combined
LEFT JOIN
  (SELECT * FROM `world-fishing-827.proj_ocean_ghg.rf_vessel_length_bins_{run_version_s1}`)
USING(fishing, length_size_bin)
ORDER BY type, fishing, length_size_bin
