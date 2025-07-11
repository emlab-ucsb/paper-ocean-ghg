SELECT
  EXTRACT(YEAR FROM month) year,
  flag,
  receiver_type,
  SUM(emissions_co2_mt) emissions_co2_mt,
  COUNT(DISTINCT ssvid) n_distinct_ssvid
FROM
  `world-fishing-827.proj_ocean_ghg.monthly_spatial_vessel_emissions_by_receiver_type_{run_version_ais}`
JOIN(
  SELECT
  ssvid,
  flag
  FROM
  `world-fishing-827.proj_ocean_ghg.vessel_info_{run_version_ais}`
)
USING(ssvid)
WHERE EXTRACT(YEAR FROM month) BETWEEN {analysis_start_year} AND {analysis_end_year}
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
  `world-fishing-827.proj_ocean_ghg.monthly_spatial_vessel_emissions_by_receiver_type_{run_version_ais}`
  JOIN(
  SELECT
  ssvid,
  flag
  FROM
  `world-fishing-827.proj_ocean_ghg.vessel_info_{run_version_ais}`)
  USING(ssvid)
  WHERE EXTRACT(YEAR FROM month) BETWEEN {analysis_start_year} AND {analysis_end_year}
GROUP BY
  year,
  flag
)