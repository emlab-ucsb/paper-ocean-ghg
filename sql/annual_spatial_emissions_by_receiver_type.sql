SELECT
  EXTRACT(YEAR FROM month) year,
  receiver_type,
  lon_bin,
  lat_bin,
  SUM(emissions_co2_mt) emissions_co2_mt
FROM
  `world-fishing-827.proj_ocean_ghg.monthly_spatial_vessel_emissions_by_receiver_type_{run_version_ais}`
WHERE EXTRACT(YEAR FROM month) IN ({analysis_start_year},{analysis_end_year})
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
  `world-fishing-827.proj_ocean_ghg.monthly_spatial_vessel_emissions_by_receiver_type_{run_version_ais}`
WHERE EXTRACT(YEAR FROM month) IN ({analysis_start_year},{analysis_end_year})
GROUP BY
  year,
  lon_bin,
  lat_bin
)