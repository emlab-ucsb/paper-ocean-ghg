# S1 detection to AIS matching miss rate by AIS message gap

`gfw_s1_to_ais_matching_miss_rate.csv`: the share of Sentinel-1 vessel detections
with a true AIS match that fall below the matching-score threshold, and so would be
classed as unmatched ("dark"), as a function of the gap in the vessel's AIS message
stream around the detection.

| ais_message_gap_duration_hours | s1_detection_matching_miss_rate |
|---:|---:|
| 0.5 | 0.016 |
| 1 | 0.032 |
| 2 | 0.068 |
| 4 | 0.144 |
| 8 | 0.274 |
| 18 | 0.454 |

## Provenance

Produced by Zihan Wei (Global Fishing Watch) and shared with the project over Slack
in September 2026. It is a synthetic hold-out experiment on the detection to AIS
matching used for `sentinel1_clean`: detections with high-confidence AIS matches
serve as ground truth, matching is re-run with the available AIS positions
restricted to within a window of each detection timestamp, and the miss rate is the
share of those true matches whose recomputed matching score falls below the
threshold. Withholding positions within 0.5, 1 and 2 hours of the detection
simulates message gaps of 1, 2 and 4 hours, with the detection at the centre of the
gap; the 0.5, 8 and 18 hour rows come from the same experiment at further windows.

Zihan's framing, from the same thread: matching considers AIS positions up to 12
hours before and after a detection, so in principle it can bridge gaps of up to 24
hours, but the success rate declines gradually with gap length, so one cannot say
that a broadcasting-but-unmatched vessel must have had a gap longer than some fixed
number of hours.

## Use

Read by `_targets_03_quarto_notebook.R` as `s1_matching_miss_rate`. The notebook
combines it with `data/gfw/emissions_by_message_hour_threshold.csv` (the share of
AIS-based CO2 emitted in message gaps of each length) to estimate how much of the
S1-unmatched emissions estimate duplicates emissions already counted for
AIS-broadcasting vessels.
