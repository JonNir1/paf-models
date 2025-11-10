import os

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

import pylater
import pyddm as ddm

import enum_types as et
from load_data import load_and_prepare_experiments


data = load_and_prepare_experiments(min_condition_size=0, allow_target_repeats=False, verbose=True)

