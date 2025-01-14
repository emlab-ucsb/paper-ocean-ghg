SELECT
year,
ssvid,
emissions_co2_mt,
hours,
main_engine_power_kw,
distance_nm/hours speed_knots
FROM
`{bq_project}.{bq_dataset}.annual_emissions_by_vessel_{run_version_ais}`
JOIN(
  SELECT
  ssvid,
  main_engine_power_kw
  FROM
  `{bq_project}.{bq_dataset}.vessel_info_{run_version_ais}`
)
USING(ssvid)