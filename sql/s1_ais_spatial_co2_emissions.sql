SELECT
    EXTRACT (YEAR FROM time) year,
    lon_bin,
    lat_bin,
    fishing,
    SUM(emissions_co2_mt) emissions_co2_mt,
    SUM(emissions_co2_dark_mt) emissions_co2_dark_mt
FROM
  `world-fishing-827.proj_ocean_ghg.rf_s1_time_gridded_dark_fleet_model_{run_version_dark}`
WHERE
  EXTRACT(YEAR
  FROM
    time) IN ({analysis_start_year},{analysis_end_year})
GROUP BY
  year,
  lon_bin,
  lat_bin,
  fishing