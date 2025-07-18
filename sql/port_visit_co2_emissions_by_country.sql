WITH
  port_visit_emissions AS(
  SELECT
    visit_id,
    emissions_co2_mt
  FROM
    `world-fishing-827.proj_ocean_ghg.port_visit_level_emissions_{run_version_ais}` ),
  port_visits AS(
  SELECT
    visit_id,
    # For port visits, from- and to-country are the same
    from_country_iso3 port_country_iso3
  FROM
    `world-fishing-827.proj_ocean_ghg.port_visit_info_{run_version_ais}`
  WHERE
    EXTRACT(YEAR
    FROM
      start_timestamp) BETWEEN {analysis_start_year}
    AND {analysis_end_year}
    AND EXTRACT(YEAR
    FROM
      end_timestamp) BETWEEN {analysis_start_year}
    AND {analysis_end_year} )
SELECT
port_country_iso3,
SUM(emissions_co2_mt) emissions_co2_mt
FROM
port_visit_emissions
JOIN
port_visits
USING(visit_id)
GROUP BY
port_country_iso3