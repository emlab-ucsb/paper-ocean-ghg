CREATE TEMPORARY FUNCTION pixel_size() AS (1);

WITH vessel_info AS (
  -- Get info for whether each vessel is classified by GFW as fishing or not
  -- Also determine each vessel's size class
  SELECT
    ssvid,
    fishing,
    length_size_class_percentile
  FROM
    `world-fishing-827.proj_ocean_ghg.s1_ais_vessels_size_classified_v20250116`
),

dark_to_ais_ratios AS (
  -- Get ratio of dark detections to AIS detections
  SELECT
    time,
    lon_bin,
    lat_bin,
    fishing,
    length_size_class_percentile,
    COALESCE(ratio_dark_to_ais_detections, global_time_ratio_dark_to_ais_detections) AS ratio_dark_to_ais
  FROM 
    `world-fishing-827.proj_ocean_ghg.s1_time_gridded_dark_fleet_model_v20250116`
),

vessel_counts AS (
  -- Count unique vessels per pixel, time, fishing status, and size class
  SELECT
    FLOOR(lon_bin / pixel_size()) * pixel_size() AS lon_bin,
    FLOOR(lat_bin / pixel_size()) * pixel_size() AS lat_bin,
    TIMESTAMP_TRUNC(TIMESTAMP(date), MONTH) AS time,
    fishing,
    length_size_class_percentile,
    COUNT(DISTINCT ssvid) AS unique_ais_vessels
  FROM
    `world-fishing-827.proj_ocean_ghg.daily_gridded_emissions_by_vessel_v20241121`
  JOIN
    vessel_info
  USING
    (ssvid)
  GROUP BY
    lon_bin,
    lat_bin,
    time,
    fishing,
    length_size_class_percentile
)

SELECT 
  time,
  lon_bin,
  lat_bin,
  fishing,
  length_size_class_percentile,
  ratio_dark_to_ais,
  unique_ais_vessels
FROM 
  vessel_counts
LEFT JOIN 
  dark_to_ais_ratios 
USING (time, lon_bin, lat_bin, fishing, length_size_class_percentile)

