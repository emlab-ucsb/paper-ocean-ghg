-- Annual AIS activity and CO2 emissions by vessel class, for comparing our
-- AIS-based estimates against published inventories (STEAM, SEIM, ICCT, OECD) on
-- activity as well as on emissions, and for the fleet-composition figures.
--
-- One row per year and vessel class: CO2, distance travelled, vessel time,
-- unique vessels and number of pings. Year totals are recovered by summing the
-- class rows (see the caveat on vessel counts below).
--
-- This absorbs the former n_vessels_by_year_and_class.sql, which read the same
-- ping table for the class split of the vessel count alone. Keeping the
-- emissions here and the class split there meant no extract carried
-- correctly-scoped emissions per class.
--
-- Why the class emissions come from here rather than from the trip and
-- port-visit extracts: those attribute emissions to completed voyages and port
-- visits, so they only count activity resolvable to a trip_id in voyage_info or
-- to a port visit, and they inner join vessel_info for the class. That excludes
-- activity the ping table includes -- their 2025 total (~1,027 Mt) falls about
-- 14% short of the annual figure the paper reports (~1,189 Mt), which derives
-- from this ping table. Grouping the pings directly keeps the class totals
-- consistent with the headline annual emissions.
--
-- Summing emissions_co2_mt, distance, hours or pings over the class rows
-- reproduces the year total exactly: every ping contributes to exactly one
-- class. The vessel counts do not have that property in general, because
-- COUNT(DISTINCT ssvid) within a class counts an ssvid once per class it appears
-- under, so an ssvid whose class changed mid-year would be counted twice. On the
-- current run version that does not occur -- the class rows sum exactly to the
-- year totals -- but a fleet-wide count is safer taken as COUNT(DISTINCT ssvid)
-- over the year rather than as a sum of these rows.
--
-- Adding the class split raises the bytes scanned: the join needs ssvid
-- alongside the measure columns, costing roughly 4.9 TiB against 2.2 TiB for the
-- year-level query this replaces.
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
--
-- vessel_class comes from the vessel_info table for the same run version, the
-- same source the trip and port-visit extracts use, so the classes here match
-- those figures. A LEFT JOIN keeps pings whose ssvid is absent from vessel_info
-- rather than dropping their emissions from the total; those rows are labelled
-- 'unknown'.

WITH
  pings AS(
  SELECT
    EXTRACT(YEAR FROM timestamp) AS year,
    ssvid,
    emissions_co2_mt,
    distance_nm,
    hours
  FROM
    `world-fishing-827.proj_ocean_ghg.ping_level_emissions_{run_version_ais}`
  WHERE
    EXTRACT(YEAR FROM timestamp) BETWEEN {analysis_start_year} AND {analysis_end_year}),
  vessel_class_info AS(
  SELECT
    ssvid,
    vessel_class
  FROM
    `world-fishing-827.proj_ocean_ghg.vessel_info_{run_version_ais}`)
SELECT
  year,
  IFNULL(vessel_class, 'unknown') AS vessel_class,
  SUM(emissions_co2_mt) AS emissions_co2_mt,
  SUM(distance_nm) AS distance_travelled_nm,
  SUM(hours) AS vessel_hours,
  COUNT(DISTINCT ssvid) AS n_unique_vessels,
  COUNT(*) AS n_pings
FROM
  pings
LEFT JOIN
  vessel_class_info
USING
  (ssvid)
GROUP BY
  year,
  vessel_class
ORDER BY
  year,
  vessel_class
