-- Unique vessels and total AIS-based CO2 emissions over the analysis period, by
-- registry status and vessel class.
--
-- The same query as fraction_vessels_emissions_by_registry_info.sql with the
-- vessel class added to the grouping. The registry classification, the inner
-- join to vessel_info and the pooled analysis window are identical, so summing
-- the class rows within each registry type reproduces that extract exactly. It
-- gives the class composition of the vessels that could not be matched to any
-- registry, cited in the response to reviewers (R3.2).
--
-- Each ssvid carries a single vessel_class in vessel_info, so the class rows of
-- a registry type sum to that type's unique-vessel count.
WITH
vessel_info AS(
  SELECT
  ssvid,
  vessel_class,
  CASE
    WHEN CONTAINS_SUBSTR(registries_listed, 'IMO') THEN 'imo'
    WHEN NOT registries_listed IS NULL THEN 'other_registry'
    ELSE 'no_registry'
    END registry_type
FROM `world-fishing-827.proj_ocean_ghg.vessel_info_{run_version_ais}`),
vessel_emissions AS(
   SELECT ssvid, SUM(emissions_co2_mt) emissions_co2_mt
    FROM
      `world-fishing-827.proj_ocean_ghg.daily_gridded_emissions_by_vessel_{run_version_ais}`
    WHERE EXTRACT(YEAR FROM date) BETWEEN {analysis_start_year} and {analysis_end_year}
    GROUP BY ssvid
)
SELECT
registry_type,
IFNULL(vessel_class, 'unknown') AS vessel_class,
COUNT(DISTINCT ssvid) n_unique_vessels,
SUM(emissions_co2_mt) emissions_co2_mt
FROM
vessel_info
JOIN
vessel_emissions
USING(ssvid)
GROUP BY
registry_type,
vessel_class
ORDER BY
registry_type,
vessel_class
