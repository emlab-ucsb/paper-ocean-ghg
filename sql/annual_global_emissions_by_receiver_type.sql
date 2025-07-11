SELECT
  EXTRACT(YEAR FROM month) year,
  receiver_type,
  SUM(emissions_co2_mt) emissions_co2_mt,
  COUNT(DISTINCT ssvid) n_distinct_ssvid
FROM
  `world-fishing-827.proj_ocean_ghg.monthly_spatial_vessel_emissions_by_receiver_type_{run_version_ais}`
WHERE EXTRACT(YEAR FROM month) BETWEEN {analysis_start_year} AND {analysis_end_year}
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
  `world-fishing-827.proj_ocean_ghg.monthly_spatial_vessel_emissions_by_receiver_type_{run_version_ais}`
WHERE EXTRACT(YEAR FROM month) BETWEEN {analysis_start_year} AND {analysis_end_year}

GROUP BY
  year
)