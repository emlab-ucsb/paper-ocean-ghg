SELECT
  COUNT(DISTINCT ssvid) n_unique_vessels
FROM
  `world-fishing-827.proj_ocean_ghg.annual_emissions_by_vessel_{run_version_ais}`
WHERE year BETWEEN {analysis_start_year} and {analysis_end_year}