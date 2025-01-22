WITH
trip_emissions AS (
  SELECT
    trip_id,
    hours,
    distance_nm,
    distance_nm/hours AS avg_speed,
    emissions_co2_mt
  FROM world-fishing-827.proj_ocean_ghg.trip_level_emissions_v20241121
),

voyage_info AS (
  SELECT
    ssvid,
    trip_id,
    EXTRACT(YEAR FROM departure_timestamp) AS departure_year
  FROM world-fishing-827.proj_ocean_ghg.voyage_info_v20241121
),

trip_emissions_info AS (
  SELECT
    t.trip_id,
    v.ssvid,
    v.departure_year,
    t.hours,
    t.distance_nm,
    t.avg_speed,
    t.emissions_co2_mt
  FROM 
    trip_emissions t
  JOIN 
    voyage_info v
  ON 
    t.trip_id = v.trip_id
),

grouped_info AS (
  SELECT
    ssvid,
    departure_year AS year,
    SUM(hours) AS total_hours,
    SUM(distance_nm) AS total_distance_nm,
    AVG(avg_speed) AS avg_speed,
    SUM(emissions_co2_mt) AS total_emissions_co2_mt
  FROM 
    trip_emissions_info
  GROUP BY 
    ssvid, departure_year
  ORDER BY 
    ssvid, departure_year
)


SELECT *
FROM grouped_info
JOIN(
  SELECT
    ssvid,
    main_engine_power_kw,
    vessel_class,
    flag
  FROM
    world-fishing-827.proj_ocean_ghg.vessel_info_v20241121
)
USING(ssvid)