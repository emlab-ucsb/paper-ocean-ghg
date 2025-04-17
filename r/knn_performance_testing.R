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
      yardstick::rsq_trad(
        truth = ratio_dark_to_ais_detections_from,
        estimate = ratio_dark_to_ais_detections_to
      ) |>
      dplyr::mutate(k = k)
  }
)

max_rsq_trad <- performance_by_k |>
  dplyr::slice_max(.estimate)

performance_by_k |>
  ggplot(aes(x = k, y = .estimate)) +
  geom_point() +
  scale_y_continuous(limits = c(0, NA)) +
  labs(
    x = "Number of neighbors (K)",
    y = "rsq_trad",
    title = glue::glue(
      "Max rsq_trad of {signif(max_rsq_trad$.estimate,3)} at K = {max_rsq_trad$k}"
    )
  ) +
  theme_minimal()
