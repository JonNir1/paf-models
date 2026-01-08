import os

import numpy as np
import pandas as pd
import hssm
import matplotlib.pyplot as plt

import pylater
import pyddm as ddm

import enum_types as et
from load_data import load_as_design_matrix


data = load_as_design_matrix(min_condition_size=0, allow_target_repeats=True, verbose=True)

