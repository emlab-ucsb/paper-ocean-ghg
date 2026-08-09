-- Annual AIS activity and CO2 emissions by vessel class, registry status and
-- vessel length bin.
--
-- A cheaper counterpart to annual_ais_activity_summary.sql, reading the daily
-- gridded table instead of the ping table, and carrying the registry split that
-- fraction_vessels_emissions_by_registry_info.sql reports fleet-wide.
--
-- One row per year, vessel class, registry type and length bin: CO2, distance
-- travelled, vessel time and unique vessels.
--
-- Why the daily table: daily_gridded_emissions_by_vessel is a pre-aggregation of
-- the same ping-level emissions, at one row per ssvid, date and grid cell rather
-- than one row per AIS message -- 5.8 billion rows against 139 billion, and 0.7
-- TiB against 24.5 TiB. Summing emissions_co2_mt, distance_nm or hours over it
-- reproduces the ping-level totals exactly, because the aggregation preserves
-- those measures. Only the row count changes meaning, which is why n_pings is
-- absent here (see below).
--
-- What this query does NOT carry, relative to annual_ais_activity_summary.sql:
--
--   * n_pings. The daily table holds no message count, and COUNT(*) here counts
--     ssvid-date-cell combinations rather than AIS messages: a vessel crossing
--     three grid cells in a day contributes three rows whether it broadcast 50
--     pings or 5,000. Use n_ais_messages.sql for message counts, or the ping-level
--     query if pings are needed alongside the class split in one extract.
--
-- The registry classification is the one used by
-- fraction_vessels_emissions_by_registry_info.sql, kept identical so the two
-- extracts can be read against each other: a vessel whose registries_listed
-- contains 'IMO' is 'imo'; any other non-null registries_listed is
-- 'other_registry'; a null is 'no_registry'. It is a substring test on a text
-- column, so it inherits whatever registries_listed carries upstream in
-- vessel_info.
--
-- Note that fraction_vessels_emissions_by_registry_info.sql INNER JOINs
-- vessel_info, dropping pings whose ssvid is absent from it. This query LEFT
-- JOINs instead, matching annual_ais_activity_summary.sql, so no emissions are
-- dropped from the year totals; unmatched ssvids appear as vessel_class
-- 'unknown' and registry_type 'no_registry'. The registry totals here will
-- therefore exceed that query's for 'no_registry' -- they are the same
-- classification over a slightly larger fleet, not a different one.
--
-- distance_nm is a column on the source table rather than something derived
-- here, so no distance is reconstructed from consecutive positions and there is
-- no AIS gap to reason about. It is in nautical miles, matching the units the
-- ICCT inventory publishes.
--
-- `hours` is the duration each underlying ping was taken to represent, which is
-- the same basis the emissions were computed on, so summing it gives
-- vessel-hours rather than wall-clock time.
--
-- ssvid is a broadcast identifier rather than a hull identity, so
-- n_unique_vessels counts distinct broadcasters in the year; it can undercount
-- vessels that change ssvid and overcount where an ssvid is shared or spoofed.
--
-- Summing emissions_co2_mt, distance or hours over the class, registry and
-- length rows reproduces the year total exactly: every row of the source table
-- contributes to exactly one (class, registry, length bin) triple, and vessels
-- with no length in vessel_info fall in the 'unknown' bin rather than being
-- dropped. The vessel counts do not have that
-- property in general, because COUNT(DISTINCT ssvid) within a group counts an
-- ssvid once per group it appears under, so an ssvid whose class changed
-- mid-year would be counted twice. A fleet-wide count is safer taken as
-- COUNT(DISTINCT ssvid) over the year rather than as a sum of these rows.
--
-- The date filter is written as a range on the partitioning column rather than
-- as EXTRACT(YEAR FROM date), so BigQuery can prune partitions where the source
-- table is partitioned on date.

WITH
  daily AS(
  SELECT
    EXTRACT(YEAR FROM date) AS year,
    ssvid,
    emissions_co2_mt,
    distance_nm,
    hours
  FROM
    `world-fishing-827.proj_ocean_ghg.daily_gridded_emissions_by_vessel_{run_version_ais}`
  WHERE
    date BETWEEN DATE '{analysis_start_year}-01-01' AND DATE '{analysis_end_year}-12-31'),
  vessel_info AS(
  SELECT
    ssvid,
    vessel_class,
    CASE
      WHEN CONTAINS_SUBSTR(registries_listed, 'IMO') THEN 'imo'
      WHEN NOT registries_listed IS NULL THEN 'other_registry'
      ELSE 'no_registry'
    END AS registry_type,
    -- Length bins follow the dark fleet model's non-fishing scheme (10 bins,
    -- 25 m wide to 225 m, open above), so this extract can be read directly
    -- against the S1 detection size structure without re-binning either side.
    -- One scheme is applied to all vessels rather than the model's separate
    -- 5-bin fishing scheme: fishing vessels simply fall in the lower bins, and
    -- a single set of edges keeps the size axis comparable across classes.
    CASE
      WHEN length_m IS NULL THEN 'unknown'
      WHEN length_m <  25 THEN '0-25m'
      WHEN length_m <  50 THEN '25-50m'
      WHEN length_m <  75 THEN '50-75m'
      WHEN length_m < 100 THEN '75-100m'
      WHEN length_m < 125 THEN '100-125m'
      WHEN length_m < 150 THEN '125-150m'
      WHEN length_m < 175 THEN '150-175m'
      WHEN length_m < 200 THEN '175-200m'
      WHEN length_m < 225 THEN '200-225m'
      ELSE '225m+'
    END AS length_bin
  FROM
    `world-fishing-827.proj_ocean_ghg.vessel_info_{run_version_ais}`)
SELECT
  year,
  IFNULL(vessel_class, 'unknown') AS vessel_class,
  IFNULL(registry_type, 'no_registry') AS registry_type,
  IFNULL(length_bin, 'unknown') AS length_bin,
  SUM(emissions_co2_mt) AS emissions_co2_mt,
  SUM(distance_nm) AS distance_travelled_nm,
  SUM(hours) AS vessel_hours,
  COUNT(DISTINCT ssvid) AS n_unique_vessels
FROM
  daily
LEFT JOIN
  vessel_info
USING
  (ssvid)
GROUP BY
  year,
  vessel_class,
  registry_type,
  length_bin
ORDER BY
  year,
  vessel_class,
  registry_type,
  length_bin
