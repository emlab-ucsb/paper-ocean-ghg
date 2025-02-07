WITH 
dark_to_ais_detections AS (
  -- Get ratio of dark detections to AIS detections
  SELECT
    time,
    fishing,
    length_size_class_percentile,
    SUM(number_ais_detections) AS total_ais_detections,
    SUM(number_dark_detections) AS total_dark_detections,
    SUM(emissions_co2_mt) AS total_ais_emissions_co2_mt,
    SUM(emissions_co2_dark_mt) AS total_dark_emissions_co2_mt,
  FROM 
    `world-fishing-827.proj_ocean_ghg.s1_time_gridded_dark_fleet_model_v20250116`
  GROUP BY
    time,
    fishing,
    length_size_class_percentile
),

vessel_info AS (
  -- Get info for whether each vessel is classified by GFW as fishing or not
  -- Also determine each vessel's size class
  SELECT
    ssvid,
    fishing,
    length_size_class_percentile
  FROM
    `world-fishing-827.proj_ocean_ghg.s1_ais_vessels_size_classified_v20250116`
),

monthly_unique_vessels AS (
  SELECT DISTINCT
    TIMESTAMP_TRUNC(TIMESTAMP(date), MONTH) AS time, -- Ensure each vessel is counted only once per month
    ssvid,
    fishing,
    length_size_class_percentile
  FROM
    `world-fishing-827.proj_ocean_ghg.daily_gridded_emissions_by_vessel_v20241121`
  JOIN
    vessel_info
  USING (ssvid)
),

vessel_counts AS (
  -- Count unique vessels per month, fishing status, and size class
  SELECT
    time,
    fishing,
    length_size_class_percentile,
    COUNT(DISTINCT ssvid) AS unique_ais_vessels
  FROM
    monthly_unique_vessels
  GROUP BY
    time,
    fishing,
    length_size_class_percentile
)

SELECT 
  v.time,
  v.fishing,
  v.length_size_class_percentile,
  IF(d.total_ais_detections = 0 AND d.total_dark_detections >0, NULL, d.total_dark_detections / d.total_ais_detections) AS ratio_dark_to_ais_detections,
  v.unique_ais_vessels,
  d.total_ais_emissions_co2_mt,
  d.total_dark_emissions_co2_mt
FROM 
  vessel_counts v
LEFT JOIN 
  dark_to_ais_detections d
USING (time, fishing, length_size_class_percentile);

