SELECT
  EXTRACT(YEAR from time) year,
    SUM(emissions_co2_mt) AS emissions_co2_mt,
    SUM(emissions_ch4_mt) AS emissions_ch4_mt,
    SUM(emissions_n2o_mt) AS emissions_n2o_mt,
    SUM(emissions_nox_mt) AS emissions_nox_mt,
    SUM(emissions_sox_mt) AS emissions_sox_mt,
    SUM(emissions_co_mt) AS emissions_co_mt,
    SUM(emissions_vocs_mt) AS emissions_vocs_mt,
    SUM(emissions_pm2_5_mt) AS emissions_pm2_5_mt,
    SUM(emissions_pm10_mt) AS emissions_pm10_mt,
  SUM(emissions_co2_dark_mt) emissions_co2_dark_mt,
    SUM(emissions_ch4_dark_mt) AS emissions_ch4_dark_mt,
    SUM(emissions_n2o_dark_mt) AS emissions_n2o_dark_mt,
    SUM(emissions_nox_dark_mt) AS emissions_nox_dark_mt,
    SUM(emissions_sox_dark_mt) AS emissions_sox_dark_mt,
    SUM(emissions_co_dark_mt) AS emissions_co_dark_mt,
    SUM(emissions_vocs_dark_mt) AS emissions_vocs_dark_mt,
    SUM(emissions_pm2_5_dark_mt) AS emissions_pm2_5_dark_mt,
    SUM(emissions_pm10_dark_mt) AS emissions_pm10_dark_mt,
  fishing
FROM
  `{bq_project}.{bq_dataset}.s1_time_gridded_dark_fleet_model_{run_version_dark}`
GROUP BY
  year,
  fishing