-- Filter those voyages occurring only with EEA countries
WITH voyage_info_filtered AS (
    SELECT 
        trip_id,
        departure_timestamp,
        TIMESTAMP_DIFF(arrival_timestamp, departure_timestamp, HOUR) AS total_time_spent_at_sea_hours,
        from_country_iso3,
        to_country_iso3,
        CASE
            WHEN from_country_iso3 IN ("AUT", "BEL", "BGR", "HRV", "CYP", "CZE", "DNK", "EST", "FIN", "FRA", 
                                       "DEU", "GRC", "HUN", "ISL", "IRL", "ITA", "LVA", "LIE", "LTU", "LUX", 
                                       "MLT", "NLD", "NOR", "POL", "PRT", "ROU", "SVK", "SVN", "ESP", "SWE") 
             AND to_country_iso3 IN ("AUT", "BEL", "BGR", "HRV", "CYP", "CZE", "DNK", "EST", "FIN", "FRA", 
                                     "DEU", "GRC", "HUN", "ISL", "IRL", "ITA", "LVA", "LIE", "LTU", "LUX", 
                                     "MLT", "NLD", "NOR", "POL", "PRT", "ROU", "SVK", "SVN", "ESP", "SWE") 
                THEN "between_EEA"
            WHEN from_country_iso3 IN ("AUT", "BEL", "BGR", "HRV", "CYP", "CZE", "DNK", "EST", "FIN", "FRA", 
                                       "DEU", "GRC", "HUN", "ISL", "IRL", "ITA", "LVA", "LIE", "LTU", "LUX", 
                                       "MLT", "NLD", "NOR", "POL", "PRT", "ROU", "SVK", "SVN", "ESP", "SWE")
                THEN "from_EEA"
            WHEN to_country_iso3 IN ("AUT", "BEL", "BGR", "HRV", "CYP", "CZE", "DNK", "EST", "FIN", "FRA", 
                                     "DEU", "GRC", "HUN", "ISL", "IRL", "ITA", "LVA", "LIE", "LTU", "LUX", 
                                     "MLT", "NLD", "NOR", "POL", "PRT", "ROU", "SVK", "SVN", "ESP", "SWE")
                THEN "to_EEA"
            ELSE NULL
        END AS trip_type
    FROM 
        `world-fishing-827.proj_ocean_ghg.voyage_info_v20241121`
    WHERE 
        from_country_iso3 IN ("AUT", "BEL", "BGR", "HRV", "CYP", "CZE", "DNK", "EST", "FIN", "FRA", 
                              "DEU", "GRC", "HUN", "ISL", "IRL", "ITA", "LVA", "LIE", "LTU", "LUX", 
                              "MLT", "NLD", "NOR", "POL", "PRT", "ROU", "SVK", "SVN", "ESP", "SWE")
        OR to_country_iso3 IN ("AUT", "BEL", "BGR", "HRV", "CYP", "CZE", "DNK", "EST", "FIN", "FRA", 
                               "DEU", "GRC", "HUN", "ISL", "IRL", "ITA", "LVA", "LIE", "LTU", "LUX", 
                               "MLT", "NLD", "NOR", "POL", "PRT", "ROU", "SVK", "SVN", "ESP", "SWE")
),

-- Get trips occurring with EEA
trip_level_filtered AS (
    SELECT 
        t.*,
        v.departure_timestamp,
        v.total_time_spent_at_sea_hours,
        v.trip_type
    FROM 
        `world-fishing-827.proj_ocean_ghg.trip_level_emissions_v20241121` AS t
    JOIN 
        voyage_info_filtered AS v
    ON 
        t.trip_id = v.trip_id
),

-- Get ssvid for vessels in EU dataset from IMO
valid_ssvid AS (
    SELECT 
        ssvid,
        imo_number,
        tonnage_gt,
        vessel_class
    FROM 
        `world-fishing-827.proj_ocean_ghg.vessel_info_v20241121` AS vi
    JOIN 
        `world-fishing-827.proj_ocean_ghg.eu_validation_data_v20241121` AS evd
    ON 
        COALESCE(vi.imo_registry, vi.imo_ais) = evd.imo_number
),

-- Filter out trips from vessels not available in the EU dataset and calculate totals by year and ssvid
trip_emissions AS (
    SELECT 
        tlf.ssvid,
        vs.imo_number,
        vs.tonnage_gt,
        vs.vessel_class,
        EXTRACT(YEAR FROM tlf.departure_timestamp) AS year,
        tlf.trip_type,
        SUM(tlf.total_time_spent_at_sea_hours) AS total_time_spent_at_sea_hours,
        SUM(tlf.distance_nm) AS total_distance_nm,
        SUM(tlf.emissions_co2_mt) AS total_emissions_co2_mt,
    FROM 
        trip_level_filtered AS tlf
    JOIN 
        valid_ssvid AS vs
    ON 
        tlf.ssvid = vs.ssvid
    GROUP BY 
        tlf.ssvid, 
        vs.imo_number,
        vs.tonnage_gt,
        vs.vessel_class,
        year,
        tlf.trip_type
)

-- Final result filtered by EU validation data
SELECT 
    te.*
FROM 
    trip_emissions AS te
JOIN 
    `world-fishing-827.proj_ocean_ghg.eu_validation_data_v20241121` AS evd
ON 
    te.imo_number = evd.imo_number
    AND te.year = FLOOR(evd.reporting_period)
;
