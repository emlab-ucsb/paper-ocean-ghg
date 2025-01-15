SELECT
  EXTRACT(YEAR
  FROM
    time) year,
    lon_bin,
    lat_bin,
    SUM(emissions_co2_mt) emissions_co2_mt,
    SUM(emissions_co2_dark_mt) emissions_co2_dark_mt
FROM
  `{bq_project}.{bq_dataset}.s1_time_gridded_dark_fleet_model_{run_version_dark}`
GROUP BY
  year,
  lon_bin,
  lat_bin