library(ggplot2)
data_directory_base <- ifelse(
  Sys.info()["nodename"] == "quebracho" | Sys.info()["nodename"] == "sequoia",
  "/home/emlab",
  # Otherwise, set the directory for local machines based on the OS
  # If using Mac OS, the directory will be automatically set as follows
  ifelse(
    Sys.info()["sysname"] == "Darwin",
    "/Users/Shared/nextcloud/emLab",
    # If using Windows, the directory will be automatically set as follows
    ifelse(
      Sys.info()["sysname"] == "Windows",
      "G:/Shared\ drives/nextcloud/emLab",
      # If using Linux, will need to manually modify the following directory path based on their user name
      # Replace your_username with your local machine user name
      "/home/your_username/Nextcloud"
    )
  )
)

project_directory <- glue::glue(
  "{data_directory_base}/projects/current-projects/paper-ocean-ghg"
)

knn_performance_testing <- glue::glue(
  "{project_directory}/data/processed/knn_performance_testing.csv"
) |>
  readr::read_csv()

# Define yardstick metrics we want to look at
multi_metric <- yardstick::metric_set(
  yardstick::rmse,
  yardstick::rsq,
  yardstick::rsq_trad,
  yardstick::mae
)

performance_by_k <- purrr::map_dfr(
  unique(knn_performance_testing$nearest_neighbor_rank),
  function(k) {
    knn_performance_testing |>
      dplyr::filter(nearest_neighbor_rank <= k) |>
      dplyr::select(-c(nearest_neighbor_rank, distance_m)) |>
      dplyr::group_by(dplyr::across(-c(ratio_dark_to_ais_detections_to))) |>
      dplyr::summarize(
        ratio_dark_to_ais_detections_to = mean(
          ratio_dark_to_ais_detections_to,
          na.rm = TRUE
        )
      ) |>
      dplyr::ungroup() |>
      multi_metric(
        truth = ratio_dark_to_ais_detections_from,
        estimate = ratio_dark_to_ais_detections_to
      ) |>
      dplyr::mutate(k = k)
  }
)

max_rsq_trad <- performance_by_k |>
  dplyr::filter(.metric == "rsq_trad") |>
  dplyr::slice_max(.estimate)

rsq_at_k_8 <- performance_by_k |>
  dplyr::filter(.metric == "rsq_trad", k == 8) |>
  dplyr::pull(.estimate) |>
  signif(3)

rsq_at_k_20 <- performance_by_k |>
  dplyr::filter(.metric == "rsq_trad", k == 20) |>
  dplyr::pull(.estimate) |>
  signif(3)

performance_by_k |>
  dplyr::filter(.metric == "rsq_trad") |>
  ggplot(aes(x = k, y = .estimate)) +
  geom_point() +
  scale_y_continuous(limits = c(0, NA)) +
  labs(
    x = "Number of neighbors (K)",
    y = "rsq_trad",
    title = glue::glue(
      "Max rsq_trad of {signif(max_rsq_trad$.estimate,3)} at K = {max_rsq_trad$k}\nrsq_trad of {rsq_at_k_8} at K = 8\nrsq_trad of {rsq_at_k_20} at K = 20"
    )
  ) +
  theme_minimal()

performance_by_k_and_vessel_type <- purrr::map_dfr(
  unique(knn_performance_testing$nearest_neighbor_rank),
  function(k) {
    knn_performance_testing |>
      dplyr::filter(nearest_neighbor_rank <= k) |>
      dplyr::select(-c(nearest_neighbor_rank, distance_m)) |>
      dplyr::group_by(dplyr::across(-c(ratio_dark_to_ais_detections_to))) |>
      dplyr::summarize(
        ratio_dark_to_ais_detections_to = mean(
          ratio_dark_to_ais_detections_to,
          na.rm = TRUE
        )
      ) |>
      dplyr::ungroup() |>
      dplyr::group_by(length_size_class_percentile, fishing) |>
      multi_metric(
        truth = ratio_dark_to_ais_detections_from,
        estimate = ratio_dark_to_ais_detections_to
      ) |>
      dplyr::mutate(k = k)
  }
)

max_rsq_trad_vessel_type <- performance_by_k_and_vessel_type |>
  dplyr::filter(.metric == "rsq_trad") |>
  dplyr::slice_max(.estimate)

performance_by_k_and_vessel_type |>
  dplyr::filter(.metric == "rsq_trad") |>
  dplyr::mutate(fishing = ifelse(fishing, "Fishing", "Non-fishing")) |>
  ggplot(aes(
    x = k,
    y = .estimate,
    color = as.factor(length_size_class_percentile)
  )) +
  geom_point() +
  scale_y_continuous(limits = c(0, NA)) +
  labs(
    x = "Number of neighbors (K)",
    y = "rsq_trad",
    color = "Length decile",
    title = glue::glue(
      "Max rsq_trad of {signif(max_rsq_trad_vessel_type$.estimate,3)} at K = {max_rsq_trad_vessel_type$k}\nat fishing = {max_rsq_trad_vessel_type$fishing} and length decile {max_rsq_trad_vessel_type$length_size_class_percentile}"
    )
  ) +
  theme_minimal() +
  facet_wrap(. ~ fishing) +
  paletteer::scale_colour_paletteer_d(
    palette = "ggthemes::Classic_Green_Orange_12"
  )
