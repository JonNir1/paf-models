from typing import Type

import pytensor
import pytensor.tensor as pt
from numpy import ndarray, inf
from pymc import Distribution

import hssm.likelihoods.analytical as hll


def logp_lba4(
        rt: ndarray,
        response: ndarray,
        A: float,
        b: float,
        v0: float,
        v1: float,
        v2: float,
        v3: float,
) -> ndarray:
    """
    Compute the analytical log-likelihood for the 4-choice LBA model.
    For the LBA 3-choice variation, see:
    https://github.com/lnccbrown/HSSM/blob/main/src/hssm/likelihoods/analytical.py#L513
    """
    rt = pt.abs(rt.copy().astype(pytensor.config.floatX))
    response = response.copy().astype(pytensor.config.floatX)
    response_int = pt.cast(response, "int32")
    logp = _pt_lba4_ll(rt, response_int, A, b, v0, v1, v2, v3).squeeze()
    checked_logp = hll.check_parameters(logp, b > A, msg="b > A")
    return checked_logp


def logp_simple_later4(
        rt: ndarray,
        response: ndarray,
        S0: float,
        v0: float,
        v1: float,
        v2: float,
        v3: float,
) -> ndarray:
    """
    Compute the analytical log-likelihood for the 4-choice LATER model.
    We use the LBA's log-likelihood with a fixed `A=0` argument and `b=S0`.

    :param rt: subject's reaction times (sec)
    :param response: subject's choices; one of [0, 1, 2, 3]
    :param S0: model's boundary, shared across accumulators within a trial
    :param v0: first accumulator's drift rates
    :param v1: second accumulator's drift rates
    :param v2: third accumulator's drift rates
    :param v3: fourth accumulator's drift rates
    """
    return logp_lba4(rt, response, A=0, b=S0, v0=v0, v1=v1, v2=v2, v3=v3)


def _pt_lba4_ll(t, ch, A, b, v0, v1, v2, v3):
    s = 0.1
    __min = pt.exp(hll.LOGP_LB)
    __max = pt.exp(-hll.LOGP_LB)
    running_idx = pt.arange(t.shape[0])

    like_0 = (
        hll._pt_tpdf(t, A, b, v0, s)
        * (1 - hll._pt_tcdf(t, A, b, v1, s))
        * (1 - hll._pt_tcdf(t, A, b, v2, s))
        * (1 - hll._pt_tcdf(t, A, b, v3, s))
    )
    like_1 = (
        (1 - hll._pt_tcdf(t, A, b, v0, s))
        * hll._pt_tpdf(t, A, b, v1, s)
        * (1 - hll._pt_tcdf(t, A, b, v2, s))
        * (1 - hll._pt_tcdf(t, A, b, v3, s))
    )
    like_2 = (
        (1 - hll._pt_tcdf(t, A, b, v0, s))
        * (1 - hll._pt_tcdf(t, A, b, v1, s))
        * hll._pt_tpdf(t, A, b, v2, s)
        * (1 - hll._pt_tcdf(t, A, b, v3, s))
    )
    like_3 = (
            (1 - hll._pt_tcdf(t, A, b, v0, s))
            * (1 - hll._pt_tcdf(t, A, b, v1, s))
            * (1 - hll._pt_tcdf(t, A, b, v2, s))
            * hll._pt_tpdf(t, A, b, v3, s)
    )
    like = pt.stack([like_0, like_1, like_2, like_3], axis=-1)

    # One should RETURN this because otherwise it will be pruned from graph
    # like_printed = pytensor.printing.Print('like')(like)
    prob_neg = (
            hll._pt_normcdf(-v0 / s) *
            hll._pt_normcdf(-v1 / s) *
            hll._pt_normcdf(-v2 / s) *
            hll._pt_normcdf(-v3 / s)
    )
    return pt.log(pt.clip(like[running_idx, ch] / (1 - prob_neg), __min, __max))


lba4_params = ["A", "b", "v0", "v1", "v2", "v3"]
simple_later4_params = ["S0", "v0", "v1", "v2", "v3"]

lba4_bounds = {
    "A": (0.0, inf),
    "b": (0.2, inf),
    "v0": (0.0, inf), "v1": (0.0, inf), "v2": (0.0, inf), "v3": (0.0, inf),
}
simple_later4_bounds = {
    "S0": (0.2, inf),
    "v0": (0.0, inf), "v1": (0.0, inf), "v2": (0.0, inf), "v3": (0.0, inf),
}


LBA4: Type[Distribution] = hll.make_distribution(
    rv="lba3",
    loglik=logp_lba4,
    list_params=lba4_params,
    bounds=lba4_bounds,
)

SimpleLATER4: Type[Distribution] = hll.make_distribution(
    rv="simple_later4",
    loglik=logp_simple_later4,
    list_params=simple_later4_params,
    bounds=simple_later4_bounds,
)
