SELECT
lon_bin,
lat_bin,
COUNT(DISTINCT time) number_months,
COUNT(DISTINCT IF(pixel_area_imaged_m2>0,time,NULL)) number_months_imaged
FROM `world-fishing-827.proj_ocean_ghg.rf_model_features_{run_version_dark}`
GROUP BY
lon_bin,
lat_bin
