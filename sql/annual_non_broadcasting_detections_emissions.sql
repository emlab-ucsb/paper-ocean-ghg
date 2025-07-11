SELECT
  EXTRACT(YEAR
  FROM
    time) year,
    fishing,
    length_size_class_percentile,
    SUM(number_ais_detections) number_ais_detections,
    SUM(number_dark_detections) number_dark_detections,
    SUM(emissions_co2_dark_mt) emissions_co2_dark_mt,
    IF(ratio_dark_to_ais_detections IS NULL,TRUE,FALSE) ratio_inferred

FROM
  `world-fishing-827.proj_ocean_ghg.s1_time_gridded_dark_fleet_model_{run_version_dark}`
    WHERE EXTRACT(YEAR FROM time) BETWEEN {analysis_start_year} and {analysis_end_year}
GROUP BY
  year,
    fishing,
    length_size_class_percentile,
    ratio_inferred
