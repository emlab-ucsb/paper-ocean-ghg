WITH
  trip_emissions AS(
  SELECT
    trip_id,
    ssvid,
    emissions_co2_mt
  FROM
    `world-fishing-827.proj_ocean_ghg.trip_level_emissions_{run_version_ais}` ),
  trip_info AS(
  SELECT
    trip_id,
    from_country_iso3,
    to_country_iso3
  FROM
    `world-fishing-827.proj_ocean_ghg.voyage_info_{run_version_ais}`
  WHERE
    EXTRACT(YEAR
    FROM
      departure_timestamp) BETWEEN {analysis_start_year}
    AND {analysis_end_year}
    AND EXTRACT(YEAR
    FROM
      arrival_timestamp) BETWEEN {analysis_start_year}
    AND {analysis_end_year}),
vessel_class_info AS(
  SELECT
  ssvid,
  vessel_class
  FROM
  `world-fishing-827.proj_ocean_ghg.vessel_info_{run_version_ais}`
)
SELECT
  from_country_iso3,
  to_country_iso3,
  vessel_class,
  SUM(emissions_co2_mt) emissions_co2_mt
FROM
  trip_emissions
JOIN
  trip_info
USING
  (trip_id)
  JOIN
  vessel_class_info
  USING
  (ssvid)
GROUP BY
  from_country_iso3,
  to_country_iso3,
  vessel_class