SELECT
  EXTRACT(YEAR FROM month) year,
  receiver_type,
  SUM(emissions_co2_mt) emissions_co2_mt,
  COUNT(DISTINCT ssvid) n_distinct_ssvid
FROM
  `{bq_project}.{bq_dataset}.monthly_spatial_vessel_emissions_by_receiver_type_{run_version_ais}`
GROUP BY
  year,
  receiver_type
UNION ALL(
  SELECT
  EXTRACT(YEAR FROM month) year,
  'total' receiver_type,
  SUM(emissions_co2_mt) emissions_co2_mt,
  COUNT(DISTINCT ssvid) n_distinct_ssvid
FROM
  `{bq_project}.{bq_dataset}.monthly_spatial_vessel_emissions_by_receiver_type_{run_version_ais}`
GROUP BY
  year
)