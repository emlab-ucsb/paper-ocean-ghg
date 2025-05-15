SELECT 
    vi.*
FROM 
    `world-fishing-827.proj_ocean_ghg.vessel_info_v20241121` AS vi
WHERE 
    CAST(COALESCE(vi.imo_registry, vi.imo_ais) AS INT64) IN (
        SELECT DISTINCT imo 
        FROM `world-fishing-827.proj_ocean_ghg.snp_fuel_consumption_v20250404`
    )
