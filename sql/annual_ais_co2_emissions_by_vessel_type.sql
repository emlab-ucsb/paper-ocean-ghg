SELECT
year,
vessel_class,
SUM(emissions_co2_mt) emissions_co2_mt
FROM
`world-fishing-827.proj_ocean_ghg.annual_emissions_by_vessel_{run_version_ais}`
JOIN(
  SELECT
  ssvid,
  main_engine_power_kw,
  vessel_class
  FROM
  `world-fishing-827.proj_ocean_ghg.vessel_info_{run_version_ais}`
)
USING(ssvid)
WHERE year BETWEEN {analysis_start_year} and {analysis_end_year}
GROUP BY
year,
vessel_class