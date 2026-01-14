SELECT
    lon_bin,
    lat_bin,
    inside_footprint,
    s1_imaged,
    sum(emissions_co2_dark_mt) emissions_co2_dark_mt
FROM
  `world-fishing-827.proj_ocean_ghg.rf_s1_time_gridded_dark_fleet_model_{run_version_dark}`
WHERE
  EXTRACT(YEAR FROM time) BETWEEN {analysis_start_year} AND {analysis_end_year}
  AND emissions_co2_dark_mt > 0
GROUP BY
    lon_bin,
    lat_bin,
    inside_footprint,
    s1_imaged