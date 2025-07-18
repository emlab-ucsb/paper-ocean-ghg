node_info <- land |>
  sf::st_centroid() |>
  sf::st_transform(map_projection) |>
  dplyr::select(country_iso3, centroid = geometry) %>%
  dplyr::mutate(
    longitude = sf::st_coordinates(.)[, 1],
    latitude = sf::st_coordinates(.)[, 2]
  ) |>
  sf::st_drop_geometry()

edge_list <- trip_co2_emissions_by_from_to_countries |>
  dplyr::filter(from_country_iso3 != to_country_iso3) |>
  dplyr::filter(
    from_country_iso3 %in%
      node_info$country_iso3 &
      to_country_iso3 %in% node_info$country_iso3
  ) |>
  dplyr::slice_max(n = 500, order_by = emissions_co2_mt) |>
  dplyr::select(
    from = from_country_iso3,
    to = to_country_iso3,
    weight = emissions_co2_mt
  )

g <- tidygraph::tbl_graph(
  nodes = node_info,
  edges = edge_list
)

ggraph(g, "manual", x = node_info$longitude, y = node_info$latitude) +
  geom_sf(data = world_bbox_sf, fill = "grey90") +
  geom_sf(
    data = land |>
      sf::st_transform(map_projection)
  ) +
  geom_edge_fan(
    aes(color = weight, alpha = weight),
    arrow = arrow(type = "closed", length = unit(2, 'mm')),
    show.legend = TRUE
  ) +
  scale_edge_color_viridis(
    option = "A",
    begin = 0.2,
    end = 0.7,
    labels = scales::unit_format(unit = "M", scale = 1e-6)
  ) +
  theme_void() +
  theme(legend.position = "none")
