from typing import Literal

import numpy as np
import pandas as pd
import hssm

import enum_types as et
import model.likelihood as ll


def create_lba4(data: pd.DataFrame) -> hssm.HSSM:
    required_columns = (
            ["subject", "rt", "response", "search_difficulty"] +
            [f"loc{i}_distractor" for i in range(4)] +
            [f"loc{i}_cue" for i in range(4)] +
            [f"loc{i}_prev_target" for i in range(4)]
    )
    missing_columns = [col for col in required_columns if col not in data.columns]
    if missing_columns:
        raise ValueError(f"data missing required columns: {missing_columns}")
    responses = list(data["response"].unique())
    num_responses = len(responses)
    if num_responses != 4:
        raise ValueError(f"expected 4 response types, got {num_responses}")
    if sorted(responses) != list(range(4)):
        raise ValueError(f"expected response as {list(range(4))}, got {sorted(responses)}")

    v_params = [hssm.Param(
        name=f"v{i}",
        formula=f"v{i} ~ 1 + C(loc{i}_distractor) * C(loc{i}_cue) * C(loc{i}_prev_target) + (1 | subject)",
        bounds=(1e-5, 20.0),
        link="log",
    ) for i in range(4)]
    A = hssm.Param(
        name="A",
        formula="A ~ 1 + (1 | subject)",
        bounds=(1e-5, 5.0),
        link="log",
        prior=dict(name="Uniform", lower=0.1, upper=2.5)
    )
    b = hssm.Param(
        name="b",
        formula="b ~ 1 + C(search_difficulty) + (1 | subject)",
        bounds=(0.2, 10.0),
        link="log",
        prior=dict(name="Uniform", lower=0.5, upper=5.0),
    )
    sv = hssm.Param(
        name="sv",
        formula="sv ~ 1 + (1 | subject)",
        bounds=(1e-5, 5.0),
        link="identity",
        prior=dict(name="HalfNormal", sigma=2.0),
    )
    Terr = hssm.Param(
        name="Terr",
        formula="Terr ~ 1 + (1 | subject)",
        bounds=(0.001, 2.0),
        link="identity",
        prior=dict(name="Uniform", lower=0.001, upper=0.5),
    )

    config = hssm.ModelConfig(
        response=['rt', 'response'],
        choices=[0, 1, 2, 3],
        list_params=ll.lba4_bounds,
        bounds=ll.lba4_bounds
    )
    model = hssm.HSSM(
        model="lba4",
        model_config=config,
        loglik_kind="analytical",
        loglik=ll.logp_lba4,
        include=v_params + [sv, A, b, Terr],
        data=data,
    )
    return model
