SELECT
  COUNT(*)/1e9 n_billion_ais_messages
FROM
  `world-fishing-827.proj_ocean_ghg.ping_level_emissions_{run_version_ais}`
WHERE
  EXTRACT(YEAR FROM timestamp) BETWEEN {analysis_start_year} and {analysis_end_year}