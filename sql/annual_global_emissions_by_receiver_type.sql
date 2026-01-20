WITH
all_data AS(
  SELECT
EXTRACT(YEAR FROM timestamp) year,
  receiver_type,
  ssvid,
  emissions_co2_mt
FROM
  `world-fishing-827.proj_ocean_ghg.ping_level_emissions_{run_version_ais}`
  WHERE
    DATE(timestamp) BETWEEN '{analysis_start_year}-01-01'
    AND '{analysis_end_year}-12-31'
)
SELECT
  year,
  receiver_type,
  COUNT(*) number_pings,
  SUM(emissions_co2_mt) emissions_co2_mt,
  COUNT(DISTINCT ssvid) n_distinct_ssvid
FROM
all_data
GROUP BY
  year,
  receiver_type
  UNION ALL(
  SELECT
  year,
  'total' receiver_type,
  COUNT(*) number_pings,
  SUM(emissions_co2_mt) emissions_co2_mt,
  COUNT(DISTINCT ssvid) n_distinct_ssvid
FROM
all_data
GROUP BY
  year)
ORDER BY
year,
receiver_type