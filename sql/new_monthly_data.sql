 SELECT
  DATE_TRUNC(date, MONTH) month,
  SUM(emissions_co2_mt) emissions_co2_mt
FROM
  `world-fishing-827.proj_ocean_ghg.daily_gridded_emissions_by_vessel_v20250701`
GROUP BY
  month