WITH
  # Get ratio info for the "from"/target pixel. 
  # ratio_dark_to_ais_detections_from will be our "truth" column for testing
  pixels_from AS(
  SELECT
    lat_bin lat_bin_from,
    lon_bin lon_bin_from,
    EXTRACT(YEAR FROM time) year,
    fishing,
    length_size_class_percentile,
    SUM(number_dark_detections)/SUM(number_ais_detections) ratio_dark_to_ais_detections_from
  FROM
    `world-fishing-827.proj_ocean_ghg.s1_time_gridded_detections_{run_version_dark}`
  WHERE number_ais_detections > 0
  GROUP BY
  lat_bin_from,
  lon_bin_from,
  year,
  fishing,
  length_size_class_percentile),
  # Now get the distinct lat/lon info and point geographies for the the "from"/target pixels
  pixels_from_location AS(
  SELECT
    lat_bin_from,
    lon_bin_from,
    ST_GEOGPOINT(lon_bin_from, lat_bin_from) geog_from
  FROM
    pixels_from
  GROUP BY
    lat_bin_from,
    lon_bin_from),
  # Get ratio info for the "to"/neighbor pixel. 
  # ratio_dark_to_ais_detections_to will be averaged across K nearest neighbors
  # And then this average will serve as our KNN "prediction" column that we will use for texting
  pixels_to AS(
  SELECT
    lat_bin lat_bin_to,
    lon_bin lon_bin_to,
    EXTRACT(YEAR FROM time) year,
    fishing,
    length_size_class_percentile,
    SUM(number_dark_detections)/SUM(number_ais_detections) ratio_dark_to_ais_detections_to
  FROM
    `world-fishing-827.proj_ocean_ghg.s1_time_gridded_detections_{run_version_dark}`
   WHERE number_ais_detections > 0
  GROUP BY
  lat_bin_to,
  lon_bin_to,
  year,
  fishing,
  length_size_class_percentile),
    # Now get the distinct lat/lon info and point geographies for the the "to"/neighbor pixels
  pixels_to_location AS(
  SELECT
    lat_bin_to,
    lon_bin_to,
    ST_GEOGPOINT(lon_bin_to, lat_bin_to) geog_to
  FROM
    pixels_to
  GROUP BY
    lat_bin_to,
    lon_bin_to),
  # Now, for all unique combintations of from and to pixels, find the distance between them
  pairwise_distance_table AS(
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
  # Only care about pixels that are actually different than each other
  WHERE NOT(lat_bin_to = lat_bin_from AND lon_bin_to = lon_bin_from)),
pairwise_distance_filtered AS(
    SELECT
    *
    FROM
    pairwise_distance_table
    # For 2023, all distances were less than this
    # (max distance was 8722985m)
    WHERE
    distance_m < 1e7
),
# Now put it all together - we'll later filter down to just the minimum distances for each observation
all_data AS(
# Now, start with our from pixels and ratio
SELECT
  *
FROM
  pixels_from
# Add all of the distances associated with the from pixels
LEFT JOIN
  pairwise_distance_filtered
USING
  (lon_bin_from,
    lat_bin_from)
# Now add the ratios associated with the "to" pixels
# This will give us lots of rows of "to" ratios and their associated distances
# We'll then take the average across the ratios for some set of K neighbors
JOIN
  pixels_to
USING
  (lon_bin_to,
    lat_bin_to,
    year,
    fishing,
    length_size_class_percentile))
# Now rank nearest neighbors for each observation
# https://stackoverflow.com/a/44680505
select t.lon_bin_from,
 t.lat_bin_from,
  t.year,
   t.fishing,
   t.length_size_class_percentile,
   t.ratio_dark_to_ais_detections_from,
   t.ratio_dark_to_ais_detections_to,
   t.nearest_neighbor_rank
from (select all_data.*,
             ROW_NUMBER() over (PARTITION BY CAST(lon_bin_from AS STRING),CAST(lat_bin_from AS STRING),fishing,year,length_size_class_percentile ORDER BY distance_m ASC) as nearest_neighbor_rank
      from all_data
     ) t
# Only select 25 nearest neighbors for each observation
# Then we can test performance from K = 1 through K = 25
where nearest_neighbor_rank <= 25