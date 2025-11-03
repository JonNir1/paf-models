import os
from typing import Optional, Literal

import pandas as pd

import enum_types as et

_COLUMNS = {
    "Trial" : "trial",
    "Subject": "subject",
    "block_number": "block",
    "trial_number": "trial_in_block",

    # first saccade parameters
    "fixation_offset_fix1": "saccade_onset",
    "fixation_onset_fix2": "saccade_offset",
    "saccade_duration": "saccade_duration",
    "fixation_location_fix2": "saccade_location",
    "distractor_type_fix2": "saccade_distractor_type",
    "num_saccades": "num_saccades",

    "cue_validity": "is_valid_cue",
    "cue_size": "cue_size",
    "search_difficulty": "search_difficulty",
    "reploc": "is_repeated_location",

    "response_time": "response_time",
    "response_result": "is_correct",
}
_SUBJ_EXCLUSION_COEF = 3                # subjects are excluded if they are over this many times away from general mean
_SUBJ_CALIB_THRESHOLD = 0.3             # subjects with more than 30% calibration issues are excluded from analysis
_IMMEDIATE_SACCADE_THRESHOLD_MS = 80    # ms
_MAX_ALLOWED_SACCADES = 4               # maximum number of saccades allowed per trial (inclusive)


def load_and_clean(
        experiment: Literal["exp1", "exp2"], data_dir: Optional[str] = None, verbose: bool = False,
) -> pd.DataFrame:
    data_dir = data_dir or os.path.join(os.getcwd(), "data")
    if verbose:
        print(f"Loading {experiment} data from directory: {data_dir}")
    data = from_csv(os.path.join(data_dir, experiment, f"Data_exp_{experiment[-1]}.csv"))
    data = drop_subjects(data, verbose)
    data = clean_trials(data, verbose)
    data = (
        data
        .loc[:, _COLUMNS.values()]
        .sort_values(by=["subject", "block", "trial_in_block"])
        .reset_index(drop=True)
    )
    return data


def from_csv(file_path: str) -> pd.DataFrame:
    df = (
        pd.read_csv(file_path)
        .rename(columns=_COLUMNS)
        .assign(
            num_saccades=lambda data: _calc_num_saccades(data),
            saccade_duration=lambda data: data["saccade_offset"] - data["saccade_onset"],
            saccade_location=lambda data: data["saccade_location"].map(
                lambda val: et.LocationTypeEnum(int(val)) if not pd.isna(val) else et.LocationTypeEnum.UNKNOWN
            ),
            saccade_distractor_type=lambda data: data["saccade_distractor_type"].map(
                lambda val: et.DistractorTypeEnum(int(val)) if not pd.isna(val) else et.DistractorTypeEnum.UNKNOWN
            ),
            is_correct=lambda data: data["is_correct"] == 1,
            is_valid_cue=lambda data: data["is_valid_cue"] == "valid",
            is_repeated_location=lambda data: data["is_repeated_location"] == "newloc",
            cue_size=lambda data: _parse_cue_size(data),
            search_difficulty=lambda data: _parse_search_difficulty(data),
            bad_calibration=lambda data: data.apply(
                # based on data's ReadMe file
                lambda row: row["fixation_onset_fix1"] != 1 or not pd.isna(row["distractor_type_fix1"]),
                axis=1,
            )
        )
    )
    return df


def drop_subjects(dataframe: pd.DataFrame, verbose: bool = True) -> pd.DataFrame:
    subj_acc = dataframe.groupby("subject")["is_correct"].mean()
    has_bad_acc = abs(subj_acc - subj_acc.mean()) / subj_acc.std() > _SUBJ_EXCLUSION_COEF
    is_bad_calibration = _find_bad_calibration(dataframe)
    subj_calib = (
        pd.concat([dataframe["subject"], is_bad_calibration], axis=1)
        .groupby("subject")["is_bad_calibration"].mean()
    )
    has_bad_calib = subj_calib >= _SUBJ_CALIB_THRESHOLD
    to_drop = (has_bad_acc | has_bad_calib)
    to_drop = set(to_drop[to_drop].index)
    if verbose:
        print(f"Dropping subjects: {to_drop}.")
    return dataframe[~dataframe["subject"].isin(to_drop)]


def clean_trials(dataframe: pd.DataFrame, verbose: bool = True) -> pd.DataFrame:
    is_bad_calibration = _find_bad_calibration(dataframe)
    if verbose:
        num_bad_calib = is_bad_calibration.sum()
        print(f"Dropping {num_bad_calib} ({100 * num_bad_calib / len(dataframe) :.2f}%) trials with bad calibration.")
    is_invalid_saccade = (
            (dataframe["saccade_location"] == et.LocationTypeEnum.UNKNOWN) |
            pd.isna(dataframe["saccade_location"])
    )
    if verbose:
        num_invalid_saccade = is_invalid_saccade.sum()
        print(
            f"Dropping {num_invalid_saccade} ({100 * num_invalid_saccade / len(dataframe) :.2f}%) trials with first "
            "saccade to unknown location."
        )
    is_immediate_saccade = dataframe["saccade_onset"] <= _IMMEDIATE_SACCADE_THRESHOLD_MS
    if verbose:
        num_immediate_saccade = is_immediate_saccade.sum()
        print(
            f"Dropping {num_immediate_saccade} ({100 * num_immediate_saccade / len(dataframe) :.2f}%) trials with "
            f"saccades starting within {_IMMEDIATE_SACCADE_THRESHOLD_MS} ms."
        )
    too_many_saccades = dataframe["num_saccades"] > _MAX_ALLOWED_SACCADES
    if verbose:
        num_excess_saccades = too_many_saccades.sum()
        print(
            f"Dropping {num_excess_saccades} ({100 * num_excess_saccades / len(dataframe) :.2f}%) trials with "
            f"more than {_MAX_ALLOWED_SACCADES} saccades."
        )
    to_drop = is_bad_calibration | is_invalid_saccade | is_immediate_saccade | too_many_saccades
    if verbose:
        num_dropped = to_drop.sum()
        print(f"Total dropped trials:\t{num_dropped} ({100 * num_dropped / len(dataframe) :.2f}%)")
    return dataframe.loc[~to_drop]


def _parse_cue_size(dataframe: pd.DataFrame) -> pd.Series:
    if "cue_size" not in dataframe.columns:
        return pd.Series([et.CueSizeTypeEnum.UNKNOWN] * len(dataframe), index=dataframe.index, name="cue_size")
    return dataframe["cue_size"].map(
        lambda val: et.CueSizeTypeEnum(int(val)) if not pd.isna(val) else et.CueSizeTypeEnum.UNKNOWN
    )


def _parse_search_difficulty(dataframe: pd.DataFrame) -> pd.Series:
    if "search_difficulty" in dataframe.columns:
        return dataframe["search_difficulty"].map(
            lambda val: et.SearchDifficultyTypeEnum(str(val).lower().strip())
        )

    def extract_search_array_from_row(row: pd.Series) -> et.SearchDifficultyTypeEnum:
        shapes = set(row[[
            "shapes_types_vec_1", "shapes_types_vec_2", "shapes_types_vec_3", "shapes_types_vec_4",
        ]].values)
        if et.DistractorTypeEnum.TARGET not in shapes:
            raise RuntimeError(f"Missing target location for row {row.name}")
        if shapes == {et.DistractorTypeEnum.TARGET, et.DistractorTypeEnum.EASY, et.DistractorTypeEnum.DIFFICULT}:
            return et.SearchDifficultyTypeEnum.MIXED
        if shapes == {et.DistractorTypeEnum.TARGET, et.DistractorTypeEnum.DIFFICULT}:
            return et.SearchDifficultyTypeEnum.DIFFICULT
        if shapes == {et.DistractorTypeEnum.TARGET, et.DistractorTypeEnum.EASY}:
            return et.SearchDifficultyTypeEnum.EASY
        return et.SearchDifficultyTypeEnum.UNKNOWN

    return dataframe.apply(extract_search_array_from_row, axis=1)


def _calc_num_saccades(dataframe: pd.DataFrame) -> pd.Series:
    def is_fixation_before_response(x: float, y: float, onset: float, rt: float) -> bool:
        return not (pd.isna(x) or pd.isna(y)) and onset < rt

    def count_fixations_in_row(row: pd.Series) -> int:
        count = 0
        for i in range(1, 20):  # assuming a maximum of 20 fixations
            x_col = f"fixation_location_x_fix{i}"
            y_col = f"fixation_location_y_fix{i}"
            onset_col = f"fixation_onset_fix{i}"
            if x_col in row.index:
                assert y_col in row.index
                assert onset_col in row.index
                if is_fixation_before_response(row[x_col], row[y_col], row[onset_col], row["response_time"]):
                    count += 1
                else:
                    break
            else:
                break
        return count

    num_fixations = dataframe.apply(count_fixations_in_row, axis=1)
    return num_fixations - 1  # subtract 1 to get number of saccades


def _find_bad_calibration(dataframe: pd.DataFrame) -> pd.Series:
    res = dataframe.apply(
        lambda row: row["fixation_onset_fix1"] != 1 or not pd.isna(row["distractor_type_fix1"]), axis=1,
    )
    res.name = "is_bad_calibration"
    return res
