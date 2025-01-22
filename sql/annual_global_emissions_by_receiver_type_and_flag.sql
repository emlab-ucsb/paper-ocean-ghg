SELECT
  EXTRACT(YEAR FROM month) year,
  flag,
  receiver_type,
  SUM(emissions_co2_mt) emissions_co2_mt,
  COUNT(DISTINCT ssvid) n_distinct_ssvid
FROM
  `{bq_project}.{bq_dataset}.monthly_spatial_vessel_emissions_by_receiver_type_{run_version_ais}`
JOIN(
  SELECT
  ssvid,
  flag
  FROM
  `{bq_project}.{bq_dataset}.vessel_info_{run_version_ais}`
)
USING(ssvid)
GROUP BY
  year,
  flag,
  receiver_type
UNION ALL(
  SELECT
  EXTRACT(YEAR FROM month) year,
  flag,
  'total' receiver_type,
  SUM(emissions_co2_mt) emissions_co2_mt,
  COUNT(DISTINCT ssvid) n_distinct_ssvid
FROM
  `{bq_project}.{bq_dataset}.monthly_spatial_vessel_emissions_by_receiver_type_{run_version_ais}`
  JOIN(
  SELECT
  ssvid,
  flag
  FROM
  `{bq_project}.{bq_dataset}.vessel_info_{run_version_ais}`)
  USING(ssvid)
GROUP BY
  year,
  flag
)