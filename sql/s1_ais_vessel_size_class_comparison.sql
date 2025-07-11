-- Compare vessel size class distributions of S1 data and AIS data
-- For each of unmatched S1 detections and AIS vessels, each vessel type (fishing and non-fishing), and each size class
-- Calculate the minimum, maximum, standard devation, and average length

WITH 
s1_size_distribution AS (
  SELECT
    fishing,
    length_size_class_percentile,
    MIN(length_m) AS min_length_m,
    AVG(length_m) AS average_length_m,
    MAX(length_m) AS max_length_m,
    STDDEV(length_m) AS sd_length_m,
    APPROX_QUANTILES(length_m, 100)[OFFSET(75)] iqr_upper_length_m,
    APPROX_QUANTILES(length_m, 100)[OFFSET(50)] median_length_m,
    APPROX_QUANTILES(length_m, 100)[OFFSET(25)] iqr_lower_length_m,
    's1' AS source
  FROM
    `world-fishing-827.proj_ocean_ghg.s1_detections_size_classified_{run_version_dark}`
  WHERE detect_ssvid IS NULL
  GROUP BY
    fishing,
    length_size_class_percentile
),

ais_size_distribution AS (
  SELECT
    fishing,
    length_size_class_percentile,
    MIN(length_m) AS min_length_m,
    AVG(length_m) AS average_length_m,
    MAX(length_m) AS max_length_m,
    STDDEV(length_m) AS sd_length_m,
    APPROX_QUANTILES(length_m, 100)[OFFSET(75)] iqr_upper_length_m,
    APPROX_QUANTILES(length_m, 100)[OFFSET(50)] median_length_m,
    APPROX_QUANTILES(length_m, 100)[OFFSET(25)] iqr_lower_length_m,
    'ais' AS source
  FROM
    `world-fishing-827.proj_ocean_ghg.s1_ais_vessels_size_classified_{run_version_dark}`
  GROUP BY
    fishing,
    length_size_class_percentile
)

SELECT
  *
FROM
  s1_size_distribution
UNION ALL
SELECT
  *
FROM
  ais_size_distribution
ORDER BY
  fishing,
  length_size_class_percentile;
