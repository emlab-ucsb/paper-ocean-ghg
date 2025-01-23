SELECT
  EXTRACT(YEAR FROM month) year,
  receiver_type,
  lon_bin,
  lat_bin,
  SUM(emissions_co2_mt) emissions_co2_mt
FROM
  `{bq_project}.{bq_dataset}.monthly_spatial_vessel_emissions_by_receiver_type_{run_version_ais}`
GROUP BY
  year,
  receiver_type,
  lon_bin,
  lat_bin
UNION ALL(
  SELECT
  EXTRACT(YEAR FROM month) year,
  'total' receiver_type,
  lon_bin,
  lat_bin,
  SUM(emissions_co2_mt) emissions_co2_mt
FROM
  `{bq_project}.{bq_dataset}.monthly_spatial_vessel_emissions_by_receiver_type_{run_version_ais}`
GROUP BY
  year,
  lon_bin,
  lat_bin
)