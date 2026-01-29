import os

import numpy as np
import pandas as pd
import hssm
import matplotlib.pyplot as plt

import pylater
import pyddm as ddm

import enum_types as et
from load_data import load_as_hssm_design_matrix, load_as_emc2_design_matrix_long
from load_data import load_and_prepare_experiments


generic = load_and_prepare_experiments(verbose=False)
# hssm_design = load_as_hssm_design_matrix(min_condition_size=0, allow_target_repeats=True, verbose=True)

emc2_design = load_as_emc2_design_matrix_long(verbose=False)
emc2_design.to_csv(os.path.join(os.getcwd(), "data", "emc2_design_matrix.csv"), index=False)
