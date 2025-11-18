from typing import Type

import pytensor
import pytensor.tensor as pt
from numpy import ndarray, inf
from pymc import Distribution

import hssm.likelihoods.analytical as hll


def logp_simple_later4(
        rt: ndarray,
        response: ndarray,
        Terr: float,
        S0: float,
        sv: float,
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
    :param Terr: subject's non-decision time (sec; subject-level trait)
    :param S0: decision boundary, shared across accumulators within a trial (subject-level trait)
    :param sv: between-trial rate variability (subject-level trait)
    :param v0: first accumulator's drift rates
    :param v1: second accumulator's drift rates
    :param v2: third accumulator's drift rates
    :param v3: fourth accumulator's drift rates
    """
    return logp_lba4(rt, response, Terr=Terr, b=S0, sv=sv, v0=v0, v1=v1, v2=v2, v3=v3, A=0)


def logp_lba4(
        rt: ndarray,
        response: ndarray,
        Terr: float,
        A: float,
        b: float,
        sv: float,
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
    logp = _pt_lba4_ll(rt, response_int, Terr, A, b, sv, v0, v1, v2, v3).squeeze()
    checked_logp = hll.check_parameters(logp, b > A, msg="b > A")
    return checked_logp


def _pt_lba4_ll(t, ch, Terr, A, b, sv, v0, v1, v2, v3):
    __min = pt.exp(hll.LOGP_LB)
    __max = pt.exp(-hll.LOGP_LB)
    running_idx = pt.arange(t.shape[0])
    t_sac = t - Terr
    t_sac = pt.clip(t_sac, 1e-6, inf)

    like_0 = (
        hll._pt_tpdf(t_sac, A, b, v0, sv)
        * (1 - hll._pt_tcdf(t_sac, A, b, v1, sv))
        * (1 - hll._pt_tcdf(t_sac, A, b, v2, sv))
        * (1 - hll._pt_tcdf(t_sac, A, b, v3, sv))
    )
    like_1 = (
        (1 - hll._pt_tcdf(t_sac, A, b, v0, sv))
        * hll._pt_tpdf(t_sac, A, b, v1, sv)
        * (1 - hll._pt_tcdf(t_sac, A, b, v2, sv))
        * (1 - hll._pt_tcdf(t_sac, A, b, v3, sv))
    )
    like_2 = (
        (1 - hll._pt_tcdf(t_sac, A, b, v0, sv))
        * (1 - hll._pt_tcdf(t_sac, A, b, v1, sv))
        * hll._pt_tpdf(t_sac, A, b, v2, sv)
        * (1 - hll._pt_tcdf(t_sac, A, b, v3, sv))
    )
    like_3 = (
            (1 - hll._pt_tcdf(t_sac, A, b, v0, sv))
            * (1 - hll._pt_tcdf(t_sac, A, b, v1, sv))
            * (1 - hll._pt_tcdf(t_sac, A, b, v2, sv))
            * hll._pt_tpdf(t_sac, A, b, v3, sv)
    )
    like = pt.stack([like_0, like_1, like_2, like_3], axis=-1)

    # One should RETURN this because otherwise it will be pruned from graph
    # like_printed = pytensor.printing.Print('like')(like)
    prob_neg = (
            hll._pt_normcdf(-v0 / sv) *
            hll._pt_normcdf(-v1 / sv) *
            hll._pt_normcdf(-v2 / sv) *
            hll._pt_normcdf(-v3 / sv)
    )
    return pt.log(pt.clip(like[running_idx, ch] / (1 - prob_neg), __min, __max))


lba4_params = ["Terr", "A", "b", "sv", "v0", "v1", "v2", "v3"]
simple_later4_params = ["Terr", "S0", "sv", "v0", "v1", "v2", "v3"]

lba4_bounds = {
    "Terr": (0.0, inf), "A": (0.0, inf), "b": (0.2, inf), "sv": (0.0, inf),
    "v0": (0.0, inf), "v1": (0.0, inf), "v2": (0.0, inf), "v3": (0.0, inf),
}
simple_later4_bounds = {
    "Terr": (0.0, inf), "S0": (0.2, inf),
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
