SELECT
year,
ssvid,
emissions_co2_mt
FROM
`{bq_project}.{bq_dataset}.annual_emissions_by_vessel_{run_version_ais}`