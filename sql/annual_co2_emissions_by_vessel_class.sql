-- AIS-broadcasting CO2 emissions for the analysis end year, totalled by vessel
-- class. This is the same source table, join and year filter as
-- annual_spatial_co2_emissions_by_vessel_class_family.sql, only summed over all
-- pixels rather than gridded, so the Figure 3A bars sum exactly to the emissions
-- mapped in Figure 3B. The family roll-up is applied in the notebook, via
-- vessel_class_family() in r/functions.R.
SELECT
  vessel_class,
  SUM(emissions_co2_mt) emissions_co2_mt
FROM
  `world-fishing-827.proj_ocean_ghg.daily_gridded_emissions_by_vessel_{run_version_ais}`
JOIN
  `world-fishing-827.proj_ocean_ghg.vessel_info_{run_version_ais}`
USING
  (ssvid)
WHERE
  EXTRACT(YEAR
  FROM
    date) = {analysis_end_year}
GROUP BY
  vessel_class
