WITH
vessels_2015 AS(
SELECT
ssvid
FROM
  `world-fishing-827.proj_ocean_ghg.annual_emissions_by_vessel_v20241121`
WHERE
year = 2015)
SELECT
year,
SUM(emissions_co2_mt) emissions_co2_mt
FROM
`world-fishing-827.proj_ocean_ghg.annual_emissions_by_vessel_v20241121`
JOIN
vessels_2015
USING(ssvid)
WHERE
year < 2024
GROUP BY
year