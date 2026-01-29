SELECT
  MIN(hours) AS min_hours,
  AVG(hours) AS mean_hours,
  MAX(hours) AS max_hours,
  -- Median (50th Percentile)
  -- We split the data into 2 quantiles; the middle one (offset 1) is the median.
  APPROX_QUANTILES(hours, 2)[OFFSET(1)] AS median_hours,
FROM
  `world-fishing-827.proj_ocean_ghg.ping_level_emissions_{run_version_ais}`
WHERE
  EXTRACT(YEAR FROM timestamp) BETWEEN {analysis_start_year} and {analysis_end_year}