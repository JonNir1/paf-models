import os
from typing import Literal

import pandas as pd

import enum_types as et

DATA_DIR = os.path.join(os.getcwd(), "data")
_COLUMNS = {
    "Subject": "subject",
    "Block": "block",           # exp1
    "block_number": "block",    # exp2
    "trial_number": "trial_in_block",
    "Trial": "trial",

    # trial information
    "search_difficulty": "search_difficulty",
    "target_location_idx": "target_location",
    "cue_location_idx": "cue_location",
    "is_valid_cue": "is_valid_cue",
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
    "reploc": "is_target_repeated",  # True if the target was in the same location in this and 1-back trial
    # "reploc_2": "is_target_repeated2",   # True if the target was in the same location in this and 2-back trial
    # "cueatprev": "is_cue_at_prev_target",   # is cue in the same location as previous target (exp1 only)
    "ReplocCue": "is_cue_at_prev_target",  # is cue in the same location as previous target (exp1 & exp2)
}


def load_and_prepare_experiments(
        data_dir=DATA_DIR, min_condition_size: int = 0, allow_target_repeats: bool = True, verbose: bool = False,
) -> pd.DataFrame:
    data = pd.concat(
        [load_experiment(1, data_dir), load_experiment(2, data_dir)],
        keys=["exp_1", "exp_2"], names=["experiment"], axis=0,
    )
    if verbose:
        print(f"Loaded {len(data)} trials from {data['subject'].nunique()} subjects.")
    data = data.dropna(subset=["saccade_onset"])
    data = (
        data
        .reset_index(level="experiment")
        .groupby(["experiment", "subject", "is_early_saccade"])
        .filter(lambda grp: len(grp) >= min_condition_size)
    )
    data = data if allow_target_repeats else data.loc[~data["is_target_repeated"]]
    data = (
        data
        .sort_values(["experiment", "subject", "block", "trial_in_block"])
        .reset_index(drop=True)
    )
    if verbose:
        print(f"After filtering, {len(data)} trials remain from {data['subject'].nunique()} subjects.")
    return data


def load_experiment(exp_id: Literal[1, 2], data_dir: str = DATA_DIR) -> pd.DataFrame:
    exp_id = int(exp_id)
    if exp_id not in [1, 2]:
        raise FileExistsError(f"Invalid Experiment ID: {exp_id}")
    path = os.path.join(data_dir, f"exp{exp_id}", f"Exp{exp_id}_clean.csv")
    if not os.path.isdir(os.path.dirname(path)):
        raise FileNotFoundError(f"Data directory not found: {os.path.dirname(path)}")
    if not os.path.exists(path):
        raise FileNotFoundError(f"Data file not found: {path}")
    data = (
        pd.read_csv(path)
        .rename(columns=_COLUMNS)
        .assign(
            search_difficulty=lambda df: df["search_difficulty"].map(et.SearchDifficultyTypeEnum),
            target_location=lambda df: df["target_location"].map(et.LocationTypeEnum),
            cue_location=lambda df: df["cue_location"].map(et.LocationTypeEnum),
            is_valid_cue=lambda df: df["target_location"] == df["cue_location"],
            cue_size=lambda df: df["cue_size"].map(et.CueSizeTypeEnum) if "cue_size" in df.columns else et.CueSizeTypeEnum.UNKNOWN,
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
            is_target_repeated=lambda df: df["is_target_repeated"].map({
                "oldloc": True, "same": True, "newloc": False, "diff": False,
            }),
            is_target_repeated2=lambda df: df["is_target_repeated"].map({
                "oldloc": True, "same": True, "newloc": False, "diff": False,
            }),
            is_cue_at_prev_target=lambda df: df["is_cue_at_prev_target"].map({
                1: True, "congruent": True, 0: False, "incongurent": False,
            }),
        )
        .loc[:, list(dict.fromkeys(_COLUMNS.values()))]
        .sort_values(by=["subject", "block", "trial_in_block"])
        .reset_index(drop=True)
    )
    return data
