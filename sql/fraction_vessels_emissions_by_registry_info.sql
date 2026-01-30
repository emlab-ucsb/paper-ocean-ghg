WITH
vessel_info AS(
  SELECT
  ssvid,
  CASE
    WHEN CONTAINS_SUBSTR(registries_listed, 'IMO') THEN 'imo'
    WHEN NOT registries_listed IS NULL THEN 'other_registry'
    ELSE 'no_registry'
    END registry_type
FROM `world-fishing-827.proj_ocean_ghg.vessel_info_{run_version_ais}`),
vessel_emissions AS(
   SELECT ssvid, SUM(emissions_co2_mt) emissions_co2_mt
    FROM
      `world-fishing-827.proj_ocean_ghg.annual_emissions_by_vessel_{run_version_ais}`
    WHERE year BETWEEN {analysis_start_year} and {analysis_end_year}
    GROUP BY ssvid
)
SELECT
registry_type,
COUNT(DISTINCT ssvid) n_unique_vessels,
SUM(emissions_co2_mt) emissions_co2_mt
FROM
vessel_info
JOIN
vessel_emissions
USING(ssvid)
GROUP BY
registry_type