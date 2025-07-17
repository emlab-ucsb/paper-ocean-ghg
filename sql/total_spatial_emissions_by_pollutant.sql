SELECT
    EXTRACT (YEAR FROM time) year,
    lon_bin,
    lat_bin,
    SUM(emissions_co2_mt + emissions_co2_dark_mt) emissions_co2_total_mt,
    SUM(emissions_ch4_mt + emissions_ch4_dark_mt) emissions_ch4_total_mt,
    SUM(emissions_n2o_mt + emissions_n2o_dark_mt) emissions_n2o_total_mt,
    SUM(emissions_nox_mt + emissions_nox_dark_mt) emissions_nox_total_mt,
    SUM(emissions_sox_mt + emissions_sox_dark_mt) emissions_sox_total_mt,
    SUM(emissions_co_mt + emissions_co_dark_mt) emissions_co_total_mt,
    SUM(emissions_vocs_mt + emissions_vocs_dark_mt) emissions_vocs_total_mt,
    SUM(emissions_pm2_5_mt + emissions_pm2_5_dark_mt) emissions_pm2_5_total_mt,
    SUM(emissions_pm10_mt + emissions_pm10_dark_mt) emissions_pm10_total_mt
FROM
  `world-fishing-827.proj_ocean_ghg.s1_time_gridded_dark_fleet_model_append_{run_version_dark}`
WHERE
  EXTRACT(YEAR
  FROM
    time) IN (2016,2024)
GROUP BY
  year,
  lon_bin,
  lat_bin