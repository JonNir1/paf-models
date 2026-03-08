import os
from typing import Literal

import numpy as np
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
    "saccade_cue": "saccade_cue",

    "RespRT": "response_time",
    "RespAC": "is_correct",

    # previous trial information
    "prev_tar_loc": "prev_target_location",
    "reploc": "is_target_repeated",  # True if the target was in the same location in this and 1-back trial
    # "reploc_2": "is_target_repeated2",   # True if the target was in the same location in this and 2-back trial
    # "cueatprev": "is_cue_at_prev_target",   # is cue in the same location as previous target (exp1 only)
    "ReplocCue": "is_cue_at_prev_target",  # is cue in the same location as previous target (exp1 & exp2)
}


def load_as_emc2_design_matrix(data_dir=DATA_DIR, verbose: bool = False,) -> pd.DataFrame:
    data = load_and_prepare_experiments(data_dir, 0, True, verbose)
    data = data.rename(columns={"subject": "subjects", "trial": "trials"})
    data['rt'] = data['saccade_onset'].astype(float) / 1000.0  # EMC2 expects seconds
    data['R'] = data['saccade_location']                # use numeric locations
    data['S'] = data["location_distractor_map"].map(    # map distractors to a string like "D,T,E,E"
        lambda d: ",".join([et.DistractorTypeEnum(v).name[0] for _, v in sorted(d.items())])
    )
    data["search_difficulty"] = data["search_difficulty"].map(lambda diff: diff.name.upper())
    data["cue_size"] = data["cue_size"].map(lambda size: et.CueSizeTypeEnum(int(size)).name.upper())
    data = data[[
        'experiment', 'subjects', 'block', 'trial_in_block', 'trials',
        'rt', 'R', 'S', 'search_difficulty', 'target_location', 'cue_location', 'cue_size',
        'is_target_repeated', 'is_cue_at_prev_target', 'prev_target_location',
    ]].sort_values(['experiment', 'subjects', 'trials']).reset_index(drop=True)
    return data


def load_as_hssm_design_matrix(
        data_dir=DATA_DIR, min_condition_size: int = 0, allow_target_repeats: bool = True, verbose: bool = False,
):
    """
    Loads the data from both experiments and prepares it as a design matrix for modeling with HSSM, where factors are
    represented as integer columns.

    :param data_dir: Directory where the experiment data is stored.
    :param min_condition_size: Minimum number of trials per condition (experiment x subject x is_early_saccade) to be
        included in the dataset.
    :param allow_target_repeats: If False, removes trials where the target location is the same as in the previous trial.
    :param verbose: If True, prints information about the loading and filtering process.

    :return: A pandas DataFrame representing the design matrix suitable for HSSM modeling:
        column `rt`: saccade latency in seconds
        column `response`: 0-indexed saccade target location (1=top-right, 2=top-left, 3=bottom-left, 4=bottom-right)
        columns `loc0_distractor`, `loc1_distractor`, ... - distractor type at each location (1=target, 2=hard, 3=easy)
        columns `loc0_cue`, `loc1_cue`, ... - cue size at each location (0=no cue, 1=small, 2=large)
    """
    data = load_and_prepare_experiments(
        data_dir, min_condition_size, allow_target_repeats, verbose,
    )
    # distractor location map
    location_distractors = (
        pd.DataFrame(data["location_distractor_map"].tolist())
        .rename(columns=lambda l: f"loc{l-1}_distractor")
    )
    # cue location map
    location_cue = np.zeros_like(location_distractors, dtype=int)
    location_cue[data["cue_location"].index.values, data["cue_location"].values - 1] = 1
    location_cue = np.maximum(location_cue, location_cue * data["cue_size"].values[:, np.newaxis])
    location_cue = pd.DataFrame(location_cue).rename(columns=lambda l: f"loc{l}_cue")
    # previous target location map
    location_prev_target = np.zeros_like(location_distractors, dtype=int)
    location_prev_target[data["prev_target_location"].index.values, data["prev_target_location"].values - 1] = 1
    location_prev_target = pd.DataFrame(location_prev_target).rename(columns=lambda l: f"loc{l}_prev_target")
    # TODO: use cue & prev-target to compute `attention_gain` map
    # additional columns
    rt = (data["saccade_onset"].astype(float) / 1000).rename("rt")              # convert to seconds for HSSM
    response = (data["saccade_location"].astype(int) - 1).rename("response")    # HSSM requires 0-indexed responses
    search_difficulty = data["search_difficulty"].map({
        et.SearchDifficultyTypeEnum.EASY: 0,
        et.SearchDifficultyTypeEnum.MIXED: 1,
        et.SearchDifficultyTypeEnum.DIFFICULT: 2,
    }).astype(int)
    # combine all
    identifiers = data[["experiment", "subject", "block", "trial_in_block", "trial"]]
    design_matrix = pd.concat(
        [identifiers, rt, response, search_difficulty, location_distractors, location_cue, location_prev_target],
        axis=1
    )
    return design_matrix


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

    def _parse_cue_size(experiment_id, df: pd.DataFrame) -> pd.Series:
        has_col = "cue_size" in df.columns
        if experiment_id == 1:
            if has_col:
                raise ValueError("Unexpected 'cue_size' column in Experiment 1 data.")
            return pd.Series(et.CueSizeTypeEnum.MEDIUM, index=df.index)
        if experiment_id == 2:
            if not has_col:
                raise ValueError("Missing 'cue_size' column in Experiment 2 data.")
            return df["cue_size"].map({1: et.CueSizeTypeEnum.SMALL, 2: et.CueSizeTypeEnum.LARGE})
        raise AssertionError(f"Invalid experiment ID: {experiment_id}")

    data = (
        pd.read_csv(path)
        .rename(columns=_COLUMNS)
        .assign(
            search_difficulty=lambda df: df["search_difficulty"].map(et.SearchDifficultyTypeEnum),
            target_location=lambda df: df["target_location"].map(et.LocationTypeEnum),
            cue_location=lambda df: df["cue_location"].map(et.LocationTypeEnum),
            is_valid_cue=lambda df: df["target_location"] == df["cue_location"],
            cue_size=lambda df: _parse_cue_size(exp_id, df),
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
                lambda val: et.DistractorTypeEnum(int(val)).name if not pd.isna(val) else et.DistractorTypeEnum.UNKNOWN.name
            ),
            # saccade cue is 0 if the saccade location wasn't cued, otherwise it is the cue size
            saccade_cue=lambda df: df["cue_size"].where(df["cue_location"] == df["saccade_location"], 0),
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
