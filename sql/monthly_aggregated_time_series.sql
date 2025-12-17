SELECT
  time,
  fishing,
  inside_footprint,
  s1_imaged,
  SUM(emissions_co2_mt) emissions_co2_mt,
  SUM(emissions_co2_dark_mt) emissions_co2_dark_mt
FROM
  `world-fishing-827.proj_ocean_ghg.rf_s1_time_gridded_dark_fleet_model_{run_version_dark}`
GROUP BY
  time,
  fishing,
  inside_footprint,
  s1_imaged
