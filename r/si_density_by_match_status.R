# Builds figures/si_inventory_comparison/fig-density-by-match-status.png
#
# Sentinel-1 detection density per length bin, split three ways by whether a
# detection matched an AIS broadcast. Row A alone is TOTAL detected activity per
# length bin, which answers "is the fleet growing" - it is the series
# si_density_denominators_figure.R used to carry as its panel C, dropped there
# once this figure superseded it. A total cannot separate growth that lands in
# the AIS-observed fleet from growth that stays dark - and that separation is
# what the fused inventory's central claim rests on, because a vessel moving
# from dark to matched reallocates emissions between the two components rather
# than adding to the fused sum.
#
# Rows are the three series, columns the two fleets. The rows are lettered A, B,
# C down the left-hand column, so the caption can name them:
#
#   A Total     = matched + unmatched, and the AIS-INDEPENDENT measure of
#                 activity: a radar blip is a blip whether or not AIS explains
#                 it.
#   B Matched   = detections tied to an AIS broadcast.
#   C Unmatched = detections with no AIS match, i.e. the dark fleet, which is
#                 what the dark emissions model is built from.
#
# One trap when reading this against the emissions series reported elsewhere:
# compare emissions to the TOTAL row (A), never to the matched row (B). Matched
# detections require an AIS match, so they rise when reception and carriage
# improve - for the same reason the emissions do - and checking one against the
# other is checking a thermometer against itself. At 0-25m that produces a
# spurious agreement where the AIS-independent total grew only +1.8%/yr.
#
# What it shows. In small non-fishing bins matched density grows steeply while
# unmatched is flat to declining: the growth there enters the AIS-observed fleet
# and the dark component does not grow with it. Unmatched density falls in every
# non-fishing class except 225+m, at +2.9%/yr - the one place dark activity
# itself rises. Fishing declines on the unmatched side in every bin.
#
# Denominator is union area x passes throughout, for the reasons set out in
# issue #10: it is the only effort measure immune to both the May 2021 footprint
# convention change and the Dec 2021 S1B loss, and its linearity in passes is
# verified against AIS ground truth (issue #10 s12).
#
# Fits match si_density_denominators_figure.R exactly - log density on time, no
# calendar-month term - so its aggregate panels and the rows here are read on
# one specification rather than differing by it. Adding month-of-year dummies
# moves these slopes by <= 0.4 pp and changes no sign.
#
# Run from the project root:  Rscript r/si_density_by_match_status.R
#
# Input: data/gfw/s1_detection_density_by_denominator.csv
#          (query at sql/s1_detection_density_by_denominator.sql)

# --------------------------------------------------------------------------
# CAPTION - reference text for the SI. Not drawn on the figure.
#
#   Sentinel-1 detection density by vessel length bin, 2017-2025, split by
#   whether the detection matched an AIS broadcast. Density is detections per
#   million km2 of union footprint area x passes; axes are log scaled. Monthly
#   values are thin lines, thick lines are least-squares fits of log density on
#   time over the full period, and right-edge labels give the fitted trend as
#   percent per year with significance from the slope's two-sided t test
#   (*** p < 0.001, ** p < 0.01, * p < 0.05, ns otherwise). Dotted and dashed
#   verticals mark the May 2021 footprint convention change and the Dec 2021
#   Sentinel-1B failure; both are properties of the recorded footprints and the
#   constellation rather than of this denominator, which is immune to them.
#
#   Row A is total detected activity. Rows B and C decompose it: growth in the
#   small non-fishing bins is carried almost
#   entirely by matched detections, while unmatched density there is flat or
#   falling, so that growth enters the AIS-observed fleet rather than the dark
#   component. Only the 225+m non-fishing bin shows unmatched density rising.
#
#   Caveat carried from issue #10 s16.1: instrument stability below ~50m is
#   inferred rather than verified, so the two smallest bins are the least
#   reliable in the figure.
# --------------------------------------------------------------------------

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
  library(ggplot2)
  library(broom)
  library(forcats)
  library(cowplot)
})

CONVENTION_CHANGE <- as.Date("2021-05-01")
S1B_FAILURE       <- as.Date("2021-12-01")
X_LIMITS          <- c(as.Date("2017-01-01"), as.Date("2027-06-01"))
LABEL_X           <- as.Date("2026-03-01")

# From Oct 2025 the extract's last three months step up on the unmatched side
# only: mean non-fishing unmatched density rises 5.85 -> 8.11 (+39%) while
# matched moves 18.80 -> 18.98 (+1%). A change at sea, or a matching change,
# would move matched as well or move it the other way; a step confined to
# unmatched with matched flat is a property of the extract, not the fleet. Left
# visible on the figure but shaded and excluded from every fit, because three
# months at the end of a nine-year series carry heavy leverage on a slope:
# including them turns 200-225m unmatched from +0.1%/yr ns into +1.1%/yr * and
# 175-200m from -0.9%/yr * into +0.1%/yr ns.
FIT_EXCLUDE_FROM <- as.Date("2025-10-01")

COMPONENTS <- c("Total", "Matched (AIS)", "Unmatched (dark)")
Y_TITLES <- c(
  "Total"             = "All detections per million km²\nof union area × passes (log)",
  "Matched (AIS)"     = "Matched detections per million km²\nof union area × passes (log)",
  "Unmatched (dark)"  = "Unmatched detections per million km²\nof union area × passes (log)"
)

# Helpers lifted from si_density_denominators_figure.R so the two figures report
# trends identically.
significance <- function(p) {
  case_when(p < 0.001 ~ "***", p < 0.01 ~ "**", p < 0.05 ~ "*", TRUE ~ "ns")
}

trend_by_group <- function(data, ...) {
  data |>
    group_by(...) |>
    group_modify(~ {
      d <- .x |> mutate(t_years = as.numeric(month - min(month)) / 365.25)
      fit <- lm(log(density) ~ t_years, data = d)
      slope <- tidy(fit) |> filter(term == "t_years")
      tibble(
        pct_per_year = 100 * (exp(slope$estimate) - 1),
        p_value = slope$p.value,
        y_end = exp(predict(fit, newdata = tibble(t_years = max(d$t_years))))
      )
    }) |>
    ungroup() |>
    mutate(label = sprintf("%+.1f%%/yr %s", pct_per_year, significance(p_value)))
}

spread_labels <- function(y_end, gap_fraction, transform = identity,
                          inverse = identity) {
  y <- transform(y_end)
  order_index <- order(y)
  y <- y[order_index]
  gap <- gap_fraction * diff(range(y))
  if (length(y) > 1) {
    for (i in 2:length(y)) {
      if (y[i] - y[i - 1] < gap) y[i] <- y[i - 1] + gap
    }
  }
  inverse(y)[order(order_index)]
}

# Data ---------------------------------------------------------------------
raw <- read_csv(
  file.path("data", "gfw", "s1_detection_density_by_denominator.csv"),
  show_col_types = FALSE
) |>
  mutate(
    month = as.Date(time),
    fleet = ifelse(fishing, "Fishing", "Non-fishing"),
    bin_max = suppressWarnings(as.numeric(length_bin_max)),
    bin = ifelse(
      is.na(bin_max) | is.infinite(bin_max),
      sprintf("%.0f+m", as.numeric(length_bin_min)),
      sprintf("%.0f-%.0fm", as.numeric(length_bin_min), bin_max)
    ),
    bin = fct_reorder(bin, length_size_bin),
    effort_mkm2 = union_x_scenes_km2 / 1e6
  )

density <- raw |>
  transmute(
    month, fleet, length_size_bin, bin,
    `Total`            = (n_matched + n_unmatched) / effort_mkm2,
    `Matched (AIS)`    = n_matched / effort_mkm2,
    `Unmatched (dark)` = n_unmatched / effort_mkm2
  ) |>
  pivot_longer(all_of(COMPONENTS), names_to = "component", values_to = "density") |>
  mutate(component = factor(component, levels = COMPONENTS)) |>
  # Log fits need strictly positive values; a handful of bin-months have no
  # detections of one kind. Dropped rather than offset, and reported below.
  filter(is.finite(density), density > 0)

dropped <- raw |>
  transmute(
    n_zero_matched = sum(n_matched == 0),
    n_zero_unmatched = sum(n_unmatched == 0)
  ) |>
  slice(1)
cat(sprintf(
  "bin-months with zero matched: %d; zero unmatched: %d (excluded from log fits)\n",
  dropped$n_zero_matched, dropped$n_zero_unmatched
))

fit_data <- density |> filter(month < FIT_EXCLUDE_FROM)

trends <- trend_by_group(fit_data, fleet, component, length_size_bin, bin) |>
  group_by(fleet, component) |>
  mutate(
    y_label = spread_labels(
      y_end,
      gap_fraction = 0.05,
      transform = log10,
      inverse = function(x) 10^x
    )
  ) |>
  ungroup()

cat(sprintf(
  "\nfits exclude %s onward (%d of %d bin-months)\n",
  format(FIT_EXCLUDE_FROM, "%b %Y"),
  sum(density$month >= FIT_EXCLUDE_FROM), nrow(density)
))

cat("\n--- trends, %/yr (denominator: union area x passes) ---\n")
trends |>
  select(fleet, bin, component, pct_per_year, p_value) |>
  pivot_wider(
    names_from = component,
    values_from = c(pct_per_year, p_value)
  ) |>
  arrange(fleet, bin) |>
  mutate(across(starts_with("pct_"), ~ round(.x, 1))) |>
  select(fleet, bin,
         total = `pct_per_year_Total`,
         matched = `pct_per_year_Matched (AIS)`,
         unmatched = `pct_per_year_Unmatched (dark)`,
         p_unmatched = `p_value_Unmatched (dark)`) |>
  mutate(p_unmatched = signif(p_unmatched, 3)) |>
  as.data.frame() |>
  print()

length_palette <- viridisLite::turbo(10, end = 0.92)

# Plot ---------------------------------------------------------------------
# One plot per fleet x component rather than a facet grid, because each fleet
# needs its own length-bin legend (five bins vs ten, and the open top bin is a
# different length range in each) and each panel needs its own log range.
subpanel <- function(fleet_name, component_name, show_legend) {
  panel_data <- density |>
    filter(fleet == fleet_name, component == component_name)
  panel_bins <- panel_data |>
    distinct(length_size_bin, bin) |>
    arrange(length_size_bin)

  ggplot(panel_data, aes(month, density, colour = bin)) +
    annotate(
      "rect",
      xmin = FIT_EXCLUDE_FROM, xmax = max(panel_data$month),
      ymin = -Inf, ymax = Inf,
      fill = "grey70", alpha = 0.30
    ) +
    geom_vline(
      xintercept = CONVENTION_CHANGE,
      linetype = "dotted", colour = "grey35", linewidth = 0.4
    ) +
    geom_vline(
      xintercept = S1B_FAILURE,
      linetype = "dashed", colour = "grey30", linewidth = 0.35
    ) +
    geom_line(linewidth = 0.3, alpha = 0.45) +
    geom_smooth(
      data = panel_data |> filter(month < FIT_EXCLUDE_FROM),
      method = "lm", se = FALSE, linewidth = 0.9
    ) +
    geom_text(
      data = trends |>
        filter(fleet == fleet_name, component == component_name),
      aes(x = LABEL_X, y = y_label, label = label, colour = bin),
      hjust = 0, size = 2.4, fontface = "bold", show.legend = FALSE
    ) +
    scale_y_log10(
      labels = scales::comma,
      expand = expansion(mult = c(0.04, 0.10))
    ) +
    scale_x_date(
      date_breaks = "1 year", date_labels = "%Y", limits = X_LIMITS
    ) +
    scale_colour_manual(
      name = paste0(fleet_name, " length bin"),
      values = setNames(length_palette[seq_len(nrow(panel_bins))], panel_bins$bin)
    ) +
    guides(colour = guide_legend(nrow = 2, byrow = TRUE, title.position = "top")) +
    labs(x = "", y = Y_TITLES[[component_name]]) +
    theme_bw(base_size = 9) +
    theme(
      legend.position = if (show_legend) "top" else "none",
      legend.direction = "horizontal",
      legend.justification = "left",
      legend.key.height = unit(0.6, "lines"),
      legend.key.width = unit(1.1, "lines"),
      legend.title = element_text(size = 8, face = "bold"),
      legend.text = element_text(size = 7),
      legend.margin = margin(0, 0, 0, 0),
      legend.box.margin = margin(0, 0, 1, 0),
      legend.box.spacing = unit(3, "pt"),
      panel.grid.minor = element_blank(),
      plot.margin = margin(10, 6, 2, 6)
    )
}

# Legend only on the top row, so it is not repeated three times per fleet. Both
# columns carry it there, which keeps the two columns' row heights equal.
#
# The A/B/C labels go on the left column only: they name the row, not the panel,
# and repeating them on the right would read as six separately-lettered panels.
fleet_column <- function(fleet_name, labels = NULL) {
  plot_grid(
    subpanel(fleet_name, "Total", show_legend = TRUE),
    subpanel(fleet_name, "Matched (AIS)", show_legend = FALSE),
    subpanel(fleet_name, "Unmatched (dark)", show_legend = FALSE),
    ncol = 1,
    align = "v",
    axis = "lr",
    rel_heights = c(1.18, 1, 1),
    labels = labels,
    label_size = 15,
    label_fontface = "bold",
    label_x = 0.002,
    hjust = 0
  )
}

figure <- plot_grid(
  fleet_column("Non-fishing", labels = c("A", "B", "C")),
  fleet_column("Fishing"),
  ncol = 2,
  align = "h",
  axis = "tb"
)

out <- file.path("figures", "si_inventory_comparison",
                 "fig-density-by-match-status.png")
ggsave(out, figure, width = 13, height = 11, dpi = 200, bg = "white")
cat(sprintf("\nwrote %s\n", out))
