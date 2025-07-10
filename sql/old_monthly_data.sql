SELECT
time month,
SUM(emissions_co2_mt) emissions_co2_mt,
SUM(emissions_co2_dark_mt) emissions_co2_dark_mt
FROM
  `world-fishing-827.proj_ocean_ghg.s1_time_gridded_dark_fleet_model_append_v20250228`
GROUP BY month
