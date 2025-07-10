WITH
  new_table AS(
  SELECT
  year,
  SUM(emissions_co2_mt) emissions_co2_mt,
  SUM(emissions_ch4_mt) emissions_ch4_mt,
  SUM(emissions_n2o_mt) emissions_n2o_mt,
  SUM(emissions_nox_mt) emissions_nox_mt,
  SUM(emissions_sox_mt) emissions_sox_mt,
  SUM(emissions_pm_mt) emissions_pm_mt,
  SUM(emissions_co_mt) emissions_co_mt,
  SUM(emissions_vocs_mt) emissions_vocs_mt,
  SUM(emissions_pm2_5_mt) emissions_pm2_5_mt,
  SUM(emissions_pm10_mt) emissions_pm10_mt,
  'v20250701' model_version
FROM
  `world-fishing-827.proj_ocean_ghg.annual_emissions_by_vessel_v20250701`
GROUP BY
  year),
  old_table AS(
SELECT
  year,
  SUM(emissions_co2_mt) emissions_co2_mt,
  SUM(emissions_ch4_mt) emissions_ch4_mt,
  SUM(emissions_n2o_mt) emissions_n2o_mt,
  SUM(emissions_nox_mt) emissions_nox_mt,
  SUM(emissions_sox_mt) emissions_sox_mt,
  SUM(emissions_pm_mt) emissions_pm_mt,
  SUM(emissions_co_mt) emissions_co_mt,
  SUM(emissions_vocs_mt) emissions_vocs_mt,
  SUM(emissions_pm2_5_mt) emissions_pm2_5_mt,
  SUM(emissions_pm10_mt) emissions_pm10_mt,
  'v20241121' model_version
FROM
  `world-fishing-827.proj_ocean_ghg.annual_emissions_by_vessel_v20241121`
GROUP BY
  year)
SELECT
  *
FROM
  new_table
UNION ALL
  (SELECT
  *
FROM
  old_table)