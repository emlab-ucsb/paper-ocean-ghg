CREATE TEMPORARY FUNCTION
  pixel_size() AS (1);
WITH
  vessel_size_class_info AS (
    -- Get info for whether each vessel is classified by GFW as fishing or not
    -- Also determine each vessel's size class
  SELECT
    ssvid,
    fishing,
    length_size_class_percentile
  FROM
    `world-fishing-827.proj_ocean_ghg.s1_ais_vessels_size_classified_v20250116` ),
  vessel_engine_power_info AS(
    -- Get main engine power for each vessel
  SELECT
    ssvid,
    main_engine_power_kw
  FROM
    `world-fishing-827.proj_ocean_ghg.vessel_info_v20241121` ),
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
    `world-fishing-827.proj_ocean_ghg.s1_time_gridded_dark_fleet_model_v20250116` ),
  ais_activity_summary AS (
    -- Summarize total hours and kW hours, and average speed, by fishing, pixel, month,and size class
  SELECT
    FLOOR(lon_bin / pixel_size()) * pixel_size() AS lon_bin,
    FLOOR(lat_bin / pixel_size()) * pixel_size() AS lat_bin,
    TIMESTAMP_TRUNC(TIMESTAMP(date), MONTH) AS time,
    fishing,
    length_size_class_percentile,
    SUM(hours) hours,
    SUM(hours * main_engine_power_kw) kw_hours,
    SUM(emissions_co2_mt) emissions_co2_mt,
    SUM(distance_nm) distance_nm,
    AVG(distance_nm/hours) speed_knots
  FROM
    `world-fishing-827.proj_ocean_ghg.daily_gridded_emissions_by_vessel_v20241121`
  JOIN
    vessel_size_class_info
  USING
    (ssvid)
  JOIN
    vessel_engine_power_info
  USING
    (ssvid)
  WHERE
  # Only use last full year of data
    EXTRACT(YEAR
    FROM
      date) <= 2024
  # Don't need 2015, since dark fleet wasn't available then
    AND
        EXTRACT(YEAR
    FROM
      date) >= 2016
  GROUP BY
    lon_bin,
    lat_bin,
    time,
    fishing,
    length_size_class_percentile ),
  spatiotemporal_extrapolations AS(
  SELECT
    time month,
    lon_bin,
    lat_bin,
    fishing,
    length_size_class_percentile,
    hours,
    hours * ratio_dark_to_ais hours_dark,
    kw_hours,
    kw_hours * ratio_dark_to_ais kw_hours_dark,
    emissions_co2_mt,
    emissions_co2_mt * ratio_dark_to_ais emissions_co2_mt_dark,
    distance_nm,
    distance_nm * ratio_dark_to_ais distance_nm_dark,
    speed_knots
  FROM
    ais_activity_summary
  LEFT JOIN
    dark_to_ais_ratios
  USING
    (time,
      lon_bin,
      lat_bin,
      fishing,
      length_size_class_percentile))
SELECT
  EXTRACT(YEAR FROM month) year,
  fishing,
  length_size_class_percentile,
  SUM(hours) hours,
  SUM(hours_dark) hours_dark,
  SUM(kw_hours) kw_hours,
  SUM(kw_hours_dark) kw_hours_dark,
  SUM(emissions_co2_mt) emissions_co2_mt,
  SUM(emissions_co2_mt_dark) emissions_co2_mt_dark,
  SUM(distance_nm) distance_nm,
  SUM(distance_nm_dark) distance_nm_dark,
  SUM(distance_nm) / SUM(hours) average_speed_knots,
  SUM(distance_nm_dark) / SUM(hours_dark) average_speed_knots_dark,
  AVG(speed_knots) avg_speed_knots
FROM
  spatiotemporal_extrapolations
GROUP BY
  year,
  fishing,
  length_size_class_percentile