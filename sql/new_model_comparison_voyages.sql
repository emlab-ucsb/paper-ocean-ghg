WITH
  new_table AS(
  SELECT
    EXTRACT(YEAR
    FROM
      arrival_timestamp) year,
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
    `world-fishing-827.proj_ocean_ghg.trip_level_emissions_v20250701`
  JOIN(SELECT trip_id, arrival_timestamp FROM `world-fishing-827.proj_ocean_ghg.voyage_info_v20250701`)
  USING(trip_id)
  GROUP BY
    year),
  old_table AS(
  SELECT
    EXTRACT(YEAR
    FROM
      arrival_timestamp) year,
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
    `world-fishing-827.proj_ocean_ghg.trip_level_emissions_v20241121`
  JOIN(SELECT trip_id, arrival_timestamp FROM `world-fishing-827.proj_ocean_ghg.voyage_info_v20241121`)
  USING(trip_id)
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