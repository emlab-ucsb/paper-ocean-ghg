SELECT
   EXTRACT(YEAR FROM time) year,
   ocean,
    sum(emissions_co2_mt + emissions_co2_dark_mt) emissions_co2_mt
FROM
  `world-fishing-827.proj_ocean_ghg.rf_s1_time_gridded_dark_fleet_model_{run_version_dark}`
  JOIN
(SELECT DISTINCT lon_bin,lat_bin,ocean
FROM
  `world-fishing-827.proj_ocean_ghg.rf_model_features_{run_version_dark}`)
USING(lon_bin,lat_bin)
WHERE
  EXTRACT(YEAR FROM time) BETWEEN {analysis_start_year} AND {analysis_end_year}
GROUP BY
    year,
    ocean