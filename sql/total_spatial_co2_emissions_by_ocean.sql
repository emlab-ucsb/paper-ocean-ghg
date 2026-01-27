WITH
ocean_emissions_info AS(
SELECT
   EXTRACT(YEAR FROM time) year,
   ocean,
    SUM(emissions_co2_mt) emissions_co2_mt,
    SUM(emissions_co2_dark_mt) emissions_co2_dark_mt
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
    ocean),
ocean_fraction_imaged_info AS(
  SELECT
ocean,
EXTRACT(YEAR FROM time) year,
COUNT(DISTINCT CONCAT(time,lon_bin,lat_bin)) number_observations,
COUNT(DISTINCT IF(pixel_area_imaged_m2>0,CONCAT(time,lon_bin,lat_bin),NULL)) number_observations_imaged
FROM `world-fishing-827.proj_ocean_ghg.rf_model_features_{run_version_dark}`
WHERE
  EXTRACT(YEAR FROM time) BETWEEN {analysis_start_year} AND {analysis_end_year}
GROUP BY
ocean,
year
)
SELECT
*
FROM
ocean_emissions_info
JOIN
ocean_fraction_imaged_info
USING(ocean,year)