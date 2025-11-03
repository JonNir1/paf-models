import os

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

import pylater

import enum_types as et


_COLUMNS = {
    "Subject": "subject",
    "Trial": "trial",
    "Block": "block",
    "trial_number": "trial_in_block",

    # trial information
    "search_difficulty": "search_difficulty",
    "is_valid_cue": "is_valid_cue",
    "target_location_idx": "target_location",
    "cue_location_idx": "cue_location",
    "cue_size": "cue_size",
    "location_distractor_map": "location_distractor_map",

    # first saccade parameters
    "fixation_offset_fix1": "saccade_onset",
    "fixation_onset_fix2": "saccade_offset",
    "saccade_duration": "saccade_duration",
    "fixation_location_fix2": "saccade_location",
    "distractor_type_fix2": "saccade_distractor_type",
    "first_fix_speed": "is_early_saccade",

    "RespRT": "response_time",
    "RespAC": "is_correct",

    # previous trial information
    "prev_tar_loc": "prev_target_location",
    "Sameloc": "is_repeated_location",      # exp1 only
    "cueatprev": "cue_at_prev",             # exp1 only     # TODO: find out what this means
    "eyeprevtar": "eye_at_prev_target",     # exp1 only     # TODO: find out what this means
}

exp1 = (
    pd.read_csv(os.path.join("data", "exp1", "Exp1_clean.csv"))
    .rename(columns=_COLUMNS)
    .assign(
        search_difficulty=lambda df: df["search_difficulty"].map(et.SearchDifficultyTypeEnum),
        is_valid_cue=lambda df: df["target_location"] == df["cue_location"],
        target_location=lambda df: df["target_location"].map(et.LocationTypeEnum),
        cue_location=lambda df: df["cue_location"].map(et.LocationTypeEnum),
        cue_size=lambda df: df["cue_size"].map(
            et.CueSizeTypeEnum) if "cue_size" in df.columns else et.CueSizeTypeEnum.UNKNOWN,
        location_distractor_map=lambda df: (
            df
            .loc[:, [col for col in df.columns if col.startswith("shapes_types_vec_")]]
            .apply(lambda row: {
                et.LocationTypeEnum(int(idx[-1])): et.DistractorTypeEnum(int(val)) for idx, val in row.items()
            }, axis=1)
        ),

        saccade_duration=lambda df: df["saccade_offset"] - df["saccade_onset"],
        saccade_location=lambda df: df["saccade_location"].map(
            lambda val: et.LocationTypeEnum(int(val)) if not pd.isna(val) else et.LocationTypeEnum.UNKNOWN
        ),
        saccade_distractor_type=lambda df: df["saccade_distractor_type"].map(
            lambda val: et.DistractorTypeEnum(int(val)) if not pd.isna(val) else et.DistractorTypeEnum.UNKNOWN
        ),
        is_early_saccade=lambda df: df["is_early_saccade"].map({"fast": True, "slow": False}),

        prev_target_location=lambda df: df["prev_target_location"].map(et.LocationTypeEnum),
        is_repeated_location=lambda df: df["is_repeated_location"].map({"valid": True, "invalid": False}),
        cue_at_prev=lambda df: df["cue_at_prev"].map({1: True, 0: False}) if "cue_at_prev" in df.columns else np.nan,
        eye_at_prev_target=lambda df: df["eye_at_prev_target"].map({1: True, 0: False}) if "eye_at_prev_target" in df.columns else np.nan,
    )
    .loc[:, _COLUMNS.values()]
    .sort_values(by=["subject", "block", "trial_in_block"])
    .reset_index(drop=True)
)


# %%
## WITHIN SUBJECT - split by early/late saccades
for subj_id in exp1["subject"].unique():
    subj_data = exp1.loc[exp1["subject"] == subj_id]
    plot = pylater.ReciprobitPlot()
    for is_early in subj_data["is_early_saccade"].unique():
        data = (subj_data.loc[subj_data["is_early_saccade"] == is_early, "saccade_onset"] / 1000.0).dropna()
        rt = pylater.Dataset(name=f"subj{subj_id}_{'early' if is_early else 'late'}", rt_s=data,)
        plot.plot_data(
            rt, plot_type="scatter", label=f"Subj{subj_id}/{'Early' if is_early else 'Late'}",
            c="cyan" if is_early else "magenta"
        )
        plot.min_rt_s = min(plot.min_rt_s, data.min())
        plot.max_rt_s = max(plot.max_rt_s, data.max())
    plt.show()


# %%
## WITHIN SUBJECT - split by early/late + cue validity
colors = {  # (is_early, is_valid) -> color
    (True, True): "lightblue", (True, False): "lightcoral",
    (False, True): "darkblue", (False, False): "darkred",
}
for subj_id in exp1["subject"].unique():
    subj_data = exp1.loc[exp1["subject"] == subj_id]
    plot = pylater.ReciprobitPlot()
    for is_early in subj_data["is_early_saccade"].unique():
        for validity in subj_data["is_valid_cue"].unique():
            name = f"subj{subj_id}/{'Early' if is_early else 'Late'}/{'valid' if validity else 'invalid'}"
            data = (
                subj_data
                .loc[
                    (subj_data["is_early_saccade"] == is_early) & (subj_data["is_valid_cue"] == validity),
                    "saccade_onset"
                ]
                .dropna()
            ) / 1000.0
            rt = pylater.Dataset(name=name, rt_s=data,)
            plot.plot_data(rt, plot_type="scatter", label=name, c=colors[(is_early, validity)])
            plot.min_rt_s = min(plot.min_rt_s, data.min())
            plot.max_rt_s = max(plot.max_rt_s, data.max())
    plt.show()


# %%
## WITHIN SUBJECT - split by early/late + search difficulty
colors = {  # (is_early, difficulty) -> color
    (True, et.SearchDifficultyTypeEnum.EASY): "lightgreen",
    (True, et.SearchDifficultyTypeEnum.MIXED): "gold",
    (True, et.SearchDifficultyTypeEnum.DIFFICULT): "lightcoral",
    (False, et.SearchDifficultyTypeEnum.EASY): "darkgreen",
    (False, et.SearchDifficultyTypeEnum.MIXED): "darkorange",
    (False, et.SearchDifficultyTypeEnum.DIFFICULT): "darkred",
}
for subj_id in exp1["subject"].unique():
    subj_data = exp1.loc[exp1["subject"] == subj_id]
    plot = pylater.ReciprobitPlot()
    for is_early in subj_data["is_early_saccade"].unique():
        for difficulty in subj_data["search_difficulty"].unique():
            name = f"subj{subj_id}/{'Early' if is_early else 'Late'}/{difficulty.name.capitalize()}"
            data = (
                subj_data
                .loc[
                    (subj_data["is_early_saccade"] == is_early) & (subj_data["search_difficulty"] == difficulty),
                    "saccade_onset"
                ]
                .dropna()
            ) / 1000.0
            rt = pylater.Dataset(name=name, rt_s=data,)
            plot.plot_data(rt, plot_type="scatter", label=name, c=colors[(is_early, difficulty)])
            plot.min_rt_s = min(plot.min_rt_s, data.min())
            plot.max_rt_s = max(plot.max_rt_s, data.max())
    plt.show()

