# Builds figures/fig-density-aggregate-fleet-trends.png
#
# Aggregate S1 detection density for fishing, non-fishing and all fleets, drawn
# three times under three different measures of observing effort. The point of
# the figure is that the same detections give opposite answers depending on the
# denominator, and that the fleet-level divergence survives the choice while the
# global total does not.
#
# Run from the project root:  Rscript r/si_aggregate_fleet_trends_figure.R
#
# The three panels, in the order drawn:
#
#   A  raw summed footprint area, exactly as recorded. Theoretically the exact
#      measure of observing effort, and the denominator the dark fleet model
#      uses -- but the recorded per-pass polygons change convention in May 2021,
#      so a trend fitted through them is an artifact.
#
#   B  the same exact per-pass effort with the pre-May-2021 values rescaled by a
#      measured factor k, splicing the two recording conventions onto a common
#      basis. Keeps exactness, removes the discontinuity.
#
#   C  union area x passes, built only from fields that do not depend on how the
#      footprint polygons are drawn. Overstates effort by a stable factor, so
#      levels are index values rather than physical densities, but trends and
#      ratios are unaffected. This is the denominator used for every result in
#      detection_density_normalisation.md.
#
# k is not hardcoded: it is computed here as the ratio of the mean per-pass
# coverage fraction either side of the convention change, so it stays correct if
# the underlying extract is regenerated.
#
# Input:  data/gfw/s1_detection_density_by_denominator.csv
#           (one-off extract; query kept at
#            sql/s1_detection_density_by_denominator.sql)

suppressMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
  library(ggplot2)
  library(broom)
})

S1B_FAILURE      <- as.Date("2021-12-01")  # constellation halves
CONVENTION_CHANGE <- as.Date("2021-05-01") # recorded footprint areas change
ERA_GAP_START    <- as.Date("2021-09-01")  # +/- 3 months excluded from era fits
ERA_GAP_END      <- as.Date("2022-04-01")

density <- read_csv(
  file.path("data", "gfw", "s1_detection_density_by_denominator.csv"),
  show_col_types = FALSE
) |>
  mutate(
    month = as.Date(time),
    fleet = ifelse(fishing, "Fishing", "Non-fishing")
  )

# Per-pass coverage fraction: the share of a cell's union footprint that each
# recorded pass covers. Denominator C assumes this is constant; it is, within
# each recording convention, but it halves at the convention change.
coverage_fraction <- density |>
  filter(dens_summed > 0, dens_union_scenes > 0) |>
  mutate(phi = dens_union_scenes / dens_summed) |>
  group_by(month) |>
  summarise(phi = median(phi), .groups = "drop")

k <- mean(coverage_fraction$phi[coverage_fraction$month <  CONVENTION_CHANGE]) /
     mean(coverage_fraction$phi[coverage_fraction$month >= CONVENTION_CHANGE])
cat(sprintf("splice factor k = %.3f\n", k))

density <- density |>
  mutate(dens_summed_harmonised = dens_summed * ifelse(month < CONVENTION_CHANGE, k, 1))

# Densities share a denominator within a month, so they are additive across
# length bins and fleets: the fleet and all-fleet series are plain sums.
aggregate_by <- function(column, panel_label) {
  bind_rows(
    density |>
      group_by(month, fleet) |>
      summarise(density = sum(.data[[column]]), .groups = "drop"),
    density |>
      group_by(month) |>
      summarise(density = sum(.data[[column]]), .groups = "drop") |>
      mutate(fleet = "All fleets")
  ) |>
    mutate(
      series = factor(fleet, levels = c("All fleets", "Fishing", "Non-fishing")),
      panel  = panel_label
    )
}

PANEL_A <- paste0(
  "A  -  RAW: detections / summed per-pass footprint area, exactly as recorded.\n",
  "Exact in principle, but the recorded areas change convention mid-record -> the growth here is an artifact. This is the dark-fleet model's denominator."
)
PANEL_B <- paste0(
  "A harmonised  -  REPAIRED: the same exact per-pass effort, with pre-May-2021 values rescaled by k = ",
  sprintf("%.2f", k), " to the later convention.\n",
  "Removes the bookkeeping step; keeps exactness. Serves as the independent cross-check on C."
)
PANEL_C <- paste0(
  "C  -  ADOPTED: detections / (union area x passes), built only from fields immune to how footprints are drawn.\n",
  "Level biased by 1/phi but stable over time; every result in this analysis uses it."
)

panels <- bind_rows(
  aggregate_by("dens_summed",            PANEL_A),
  aggregate_by("dens_summed_harmonised", PANEL_B),
  aggregate_by("dens_union_scenes",      PANEL_C)
) |>
  mutate(panel = factor(panel, levels = c(PANEL_A, PANEL_B, PANEL_C)))

significance <- function(p) {
  case_when(p < 0.001 ~ "***", p < 0.01 ~ "**", p < 0.05 ~ "*", TRUE ~ "ns")
}

# Full-period log-linear trend per series, for the labels at the right edge
trend_labels <- panels |>
  group_by(panel, series) |>
  group_modify(~ {
    d <- .x |> mutate(t_years = as.numeric(month - min(month)) / 365.25)
    fit <- lm(log(density) ~ t_years, data = d)
    slope <- tidy(fit) |> filter(term == "t_years")
    tibble(
      pct_per_year = 100 * (exp(slope$estimate) - 1),
      p_value      = slope$p.value,
      y_end        = exp(predict(fit, newdata = tibble(t_years = max(d$t_years))))
    )
  }) |>
  ungroup() |>
  mutate(label = sprintf("%+.1f%%/yr %s", pct_per_year, significance(p_value)))

# Nudge labels apart where two series converge, which they do by construction in
# the adopted panel
trend_labels <- trend_labels |>
  group_by(panel) |>
  arrange(y_end, .by_group = TRUE) |>
  mutate(y_label = {
    y <- y_end
    gap <- max(y) * 0.085
    for (i in 2:length(y)) if (y[i] - y[i - 1] < gap) y[i] <- y[i - 1] + gap
    y
  }) |>
  ungroup()

cat("\n=== Full-period trend by panel and series ===\n\n")
trend_labels |>
  transmute(
    panel  = substr(as.character(panel), 1, 14),
    series,
    slope  = sprintf("%+.2f%%/yr", pct_per_year),
    sig    = significance(p_value)
  ) |>
  as.data.frame() |>
  print(row.names = FALSE)

series_colours <- c(
  "All fleets"  = "grey20",
  "Fishing"     = "#d95f0e",
  "Non-fishing" = "#2c7fb8"
)

p <- ggplot(panels, aes(month, density, colour = series)) +
  annotate(
    "rect",
    xmin = ERA_GAP_START, xmax = ERA_GAP_END, ymin = -Inf, ymax = Inf,
    fill = "grey70", alpha = 0.30
  ) +
  geom_vline(xintercept = CONVENTION_CHANGE, linetype = "dotted", colour = "grey35", linewidth = 0.4) +
  geom_vline(xintercept = S1B_FAILURE,       linetype = "dashed", colour = "grey30", linewidth = 0.35) +
  geom_line(linewidth = 0.32, alpha = 0.42) +
  geom_smooth(method = "lm", se = FALSE, linewidth = 1.0) +
  geom_text(
    data = trend_labels,
    aes(x = as.Date("2026-03-01"), y = y_label, label = label, colour = series),
    hjust = 0, size = 2.8, fontface = "bold", show.legend = FALSE
  ) +
  facet_wrap(~panel, ncol = 1, scales = "free_y") +
  scale_colour_manual(NULL, values = series_colours) +
  scale_x_date(
    date_breaks = "1 year", date_labels = "%Y",
    limits = c(as.Date("2017-01-01"), as.Date("2027-08-01"))
  ) +
  scale_y_continuous(limits = c(0, NA), labels = scales::comma) +
  labs(
    x = "", y = "Detections per million km² of observing effort",
    title = "Same detections, three effort denominators: the fleet divergence is robust, the global total is not",
    subtitle = paste0(
      "Each panel divides the identical detection counts by a different measure of observing effort. Dotted line: May 2021 footprint\n",
      "bookkeeping change (recorded per-pass area halves). Dashed line + grey band: Sentinel-1B loss, Dec 2021 (±3 months excluded from era fits)."
    )
  ) +
  theme_bw(base_size = 9) +
  theme(
    legend.position  = "top",
    strip.background = element_rect(fill = "transparent", colour = NA),
    strip.text       = element_text(face = "bold", hjust = 0, size = 7.4,
                                    lineheight = 1.25, margin = margin(b = 3, t = 5)),
    panel.grid.minor = element_blank(),
    plot.title       = element_text(face = "bold", size = 10.5),
    plot.subtitle    = element_text(size = 8),
    plot.margin      = margin(6, 10, 6, 6)
  )

out_path <- file.path("figures", "fig-density-aggregate-fleet-trends.png")
ggsave(out_path, p, width = 10, height = 10.4, dpi = 200, bg = "white")
cat("\nwrote:", out_path, "\n")
