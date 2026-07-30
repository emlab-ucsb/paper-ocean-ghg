-- Annual AIS activity and CO2 emissions, for comparing our AIS-based estimates
-- against published inventories (STEAM, SEIM, ICCT, OECD) on activity as well as
-- on emissions.
--
-- One row per year: total CO2, distance travelled, vessel time, unique vessels
-- and number of pings.
--
-- distance_nm is a column on the ping table rather than something derived here,
-- so no distance is reconstructed from consecutive positions and there is no AIS
-- gap to reason about. It is in nautical miles, matching the units the ICCT
-- inventory publishes.
--
-- `hours` is the duration each ping is taken to represent, which is the same
-- basis the emissions were computed on, so summing it gives vessel-hours rather
-- than wall-clock time.
--
-- ssvid is a broadcast identifier rather than a hull identity, so n_unique_vessels
-- counts distinct broadcasters in the year; it can undercount vessels that change
-- ssvid and overcount where an ssvid is shared or spoofed.

SELECT
  EXTRACT(YEAR FROM timestamp) AS year,
  SUM(emissions_co2_mt) AS emissions_co2_mt,
  SUM(distance_nm) AS distance_travelled_nm,
  SUM(hours) AS vessel_hours,
  COUNT(DISTINCT ssvid) AS n_unique_vessels,
  COUNT(*) AS n_pings
FROM
  `world-fishing-827.proj_ocean_ghg.ping_level_emissions_{run_version_ais}`
WHERE
  EXTRACT(YEAR FROM timestamp) BETWEEN {analysis_start_year} AND {analysis_end_year}
GROUP BY
  year
ORDER BY
  year
