WITH
  pixels_from AS (
    SELECT
      lat_bin lat_bin_from,
      lon_bin lon_bin_from,
      time,
      fishing,
      length_size_class_percentile,
      ratio_dark_to_ais_detections ratio_dark_to_ais_detections_from
    FROM
      `world-fishing-827.proj_ocean_ghg.s1_time_gridded_detections_{run_version_dark}`
    WHERE
      ratio_dark_to_ais_detections >= 0
      AND EXTRACT(YEAR FROM time) = {year}
      AND EXTRACT(MONTH FROM time) = {month}
  ),
  pixels_from_location AS (
    SELECT
      lat_bin_from,
      lon_bin_from,
      ST_GEOGPOINT(lon_bin_from, lat_bin_from) geog_from
    FROM
      pixels_from
    GROUP BY
      lat_bin_from,
      lon_bin_from
  ),
  pixels_to AS (
    SELECT
      lat_bin lat_bin_to,
      lon_bin lon_bin_to,
      time,
      fishing,
      length_size_class_percentile,
      ratio_dark_to_ais_detections ratio_dark_to_ais_detections_to
    FROM
      `world-fishing-827.proj_ocean_ghg.s1_time_gridded_detections_{run_version_dark}`
    WHERE
      ratio_dark_to_ais_detections >= 0
      AND EXTRACT(YEAR FROM time) = {year}
      AND EXTRACT(MONTH FROM time) = {month}
  ),
  pixels_to_location AS (
    SELECT
      lat_bin_to,
      lon_bin_to,
      ST_GEOGPOINT(lon_bin_to, lat_bin_to) geog_to
    FROM
      pixels_to
    GROUP BY
      lat_bin_to,
      lon_bin_to
  ),
  pairwise_distance_table AS (
    SELECT
      lon_bin_from,
      lat_bin_from,
      lon_bin_to,
      lat_bin_to,
      ST_DISTANCE(geog_from, geog_to, TRUE) distance_m
    FROM
      pixels_from_location
    CROSS JOIN
      pixels_to_location
    WHERE NOT (lat_bin_to = lat_bin_from AND lon_bin_to = lon_bin_from)
  ),
  pairwise_distance_filtered AS (
    SELECT *
    FROM pairwise_distance_table
    -- WHERE distance_m < 1e7
  ),
  all_data AS (
    SELECT *
    FROM pixels_from
    LEFT JOIN pairwise_distance_filtered
      USING (lon_bin_from, lat_bin_from)
    JOIN pixels_to
      USING (lon_bin_to, lat_bin_to, time, fishing, length_size_class_percentile)
  )
SELECT 
  t.lon_bin_from,
  t.lat_bin_from,
  t.time,
  t.fishing,
  t.length_size_class_percentile,
  t.ratio_dark_to_ais_detections_from,
  t.ratio_dark_to_ais_detections_to,
  t.nearest_neighbor_rank
FROM (
  SELECT 
    all_data.*,
    ROW_NUMBER() OVER (
      PARTITION BY CAST(lon_bin_from AS STRING),
                   CAST(lat_bin_from AS STRING),
                   fishing,
                   time,
                   length_size_class_percentile
      ORDER BY distance_m ASC
    ) AS nearest_neighbor_rank
  FROM all_data
) t
WHERE nearest_neighbor_rank <= 25
